#!/bin/bash
#!/bin/bash
# 预建 fnOS 存储挂载点目录 —— 关键！绝不挂载
#
# 2026-11-27 找到真正根因（板子实测 + LD_PRELOAD 钩子 + 反汇编）：
#
#   fnOS 的 is_mountpoint() 真实实现（/usr/trim/lib/libnfile.so）：
#       bool is_mountpoint(const char *p, int flags) {
#           return faccessat(AT_FDCWD, p, F_OK, flags) != 0;
#       }
#   语义是反的：路径"不存在"时返回 true。
#
#   storage.hdl 的 stor_create() 里：
#       sprintf(buf, "/vol%u", vol_id);
#       if (is_mountpoint(buf, 0)) {     // 路径不存在 → true
#           errno = 0x30008;             // E_MOUNTPOINT_EXISTS
#           return -1;                   // → "挂载点已存在"
#       }
#
#   所以：/vol1 目录必须先存在，飞牛才会继续 mount。
#
#   而本该创建它的 triminit 的 create_storage_mountpoint()
#   因为 trimafs（飞牛自研文件系统，内核没这个模块）挂载失败
#   提前退出了，压根没走到。
#
# 结论：开机预建 /vol1 目录（空目录，不挂载）。
#   飞牛创建存储时会自己 mount 上去。
#
# LD_PRELOAD 钩子实测：
#   faccessat(-21581, /vol1, 0, 0) = -1   （目录不存在）
#   → is_mountpoint 返回 true → 报"挂载点已存在"
#   建好目录后：
#   faccessat(-21581, /vol1, 0, 0) = 0    （目录存在）
#   → is_mountpoint 返回 false → 正常创建
#
# 板子验证：建好 /vol1 后创建存储一次成功。


# ==========================================================================
# fix_rootfs_fstab.sh —— 刷机时修正 rootfs 的 fstab 并安装板子侧修复服务
#
# 用法（在 kdevbuild/*_image.sh 里，mount rootfs.img /mnt 之后调用）：
#     bash "$(cd "$(dirname "$0")" && pwd)/fix_rootfs_fstab.sh" /mnt || true
#
# 修这些：
#   ① 去掉 btrfs 不认的 errors=remount-ro
#   ② /boot 统一改 LABEL=kdevboot（boot.img 是 mkfs.ext2 -L kdevboot）
#   ③ 根分区加 x-systemd.growfs，另装 btrfs-growroot.service 兜底
#   ④ 删掉 /boot/efi 等不存在的挂载行
#   ⑤ 预建 /vol1（fnOS 存储池挂载点）
#   ⑦ trim-4g-power.service —— 4G 模块电源/复位时序（PCA9555）
#   ⑧ WiFi 固件 → /lib/firmware/（bcmdhd 用 request_firmware 加载）
# ==========================================================================
set -u

MNT="${1:-/mnt}"
F="$MNT/etc/fstab"

if [ ! -f "$F" ]; then
  echo "[fix_fstab] 没有 $F，跳过"
  exit 0
fi

echo "==================== fix_rootfs_fstab ===================="
echo "--- 修改前 ---"
cat "$F"

cp -f "$F" "$F.orig"

# ① btrfs 不支持 errors=remount-ro
sed -i 's/,errors=remount-ro//g' "$F"

# ④ 删掉不存在的 /boot/efi 挂载
sed -i '\#[[:space:]]/boot/efi[[:space:]]#d' "$F"

# ②③ 用 awk 精确改 / 和 /boot
awk 'BEGIN { OFS="\t" }
{
  if ($2 == "/") {
      gsub(/,?errors=remount-ro/, "", $4)
      if ($4 !~ /x-systemd\.growfs/) {
          $4 = $4 ",x-systemd.growfs"
      }
      gsub(/^,/, "", $4)
      print
  } else if ($2 == "/boot") {
      print "LABEL=kdevboot", "/boot", "ext4", "defaults,noatime", "0", "2"
  } else {
      print
  }
}' "$F" > "$F.new" && mv "$F.new" "$F"

echo "--- 修改后 ---"
cat "$F"
echo "（原文件备份在 ${F}.orig）"

# ==========================================================================
# ⑤ 预建 /vol1
# ==========================================================================

# ==========================================================================
# ⑥ btrfs-growroot.service —— 替代失效的 systemd-growfs@-.service
# ==========================================================================
mkdir -p "$MNT/etc/systemd/system/sysinit.target.wants" 2>/dev/null || true
cat > "$MNT/etc/systemd/system/btrfs-growroot.service" <<'GROWEOF'
[Unit]
Description=Grow btrfs root filesystem to fill partition
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'btrfs filesystem resize max / || true'

[Install]
WantedBy=sysinit.target
GROWEOF
ln -sf ../btrfs-growroot.service \
  "$MNT/etc/systemd/system/sysinit.target.wants/btrfs-growroot.service" 2>/dev/null || true
echo "[fix_rootfs] 已安装 btrfs-growroot.service"

# ==========================================================================
#    时序：After=trim_main（在 fnOS 启动之后再执行，否则 /vol1 会被它清掉）
# ==========================================================================
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" 2>/dev/null || true

# ==========================================================================
# ⑧ trim-4g-power.service —— 4G 模块电源/复位时序
#
# 板子 EC200A-CN（Mini-PCIe 版，EC200DACNDA-N06-MN0CA）走 USB。
# 电源/复位/使能挂在 PCA9555（i2c-6 @0x20）：
#   pin 0 = usb0_power   高 = 供电
#   pin 1 = usb2_power   高 = 供电
#   pin 7 = usb1_power   高 = 供电
#   pin 5 = 4g_power     高 = 模块上电
#   pin 3 = 4g_reset     GPIO_ACTIVE_LOW → 逻辑高=物理低=不复位
#   pin 8 = 4g_disable   高 = 不禁用
#
# Android 用 smdt,smdtio 内核驱动初始化这些 GPIO，Linux 侧没有该驱动，
# 故用本服务复刻。必须走"断电 → 上电 → 释放复位"完整时序，
# 单纯设电平模块不会重新枚举。
# ==========================================================================
cat > "$MNT/etc/systemd/system/trim-4g-power.service" <<'G4EOF'
[Unit]
Description=4G module power cycle + reset sequence
DefaultDependencies=no
After=local-fs.target
Before=trim-4g-apn.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 4G 电源时序（板子实测必须完整脉冲，单纯设电平模块不枚举）
#   4g_power(517) = 0     断电
#   4g_reset(515) = 1     复位有效（逻辑高，ACTIVE_LOW → 物理高）
#   sleep 1.5
#   4g_power(517) = 1     上电
#   sleep 1.0
#   4g_reset(515) = 0     释放复位（物理低）
#
# ★ 绝对不要碰 513(pin1=4g灯) / 519(pin7=pwr灯) / 516(pin4=data灯)
#   这三个归 DTB 的 gpio-leds 管理，sysfs 再动就会和 LED 子系统打架
#   （之前碰了，导致红灯一直亮 / LED 状态错乱）
#
# 只碰：515(4g_reset) 517(4g_power) 520(4g_disable)
ExecStart=/bin/bash -c 'for g in 515 517 520; do if [ ! -d /sys/class/gpio/gpio$g ]; then echo $g > /sys/class/gpio/export 2>/dev/null; sleep 0.1; fi; if [ -d /sys/class/gpio/gpio$g ]; then echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null; fi; done; echo 1 > /sys/class/gpio/gpio520/value 2>/dev/null; echo 0 > /sys/class/gpio/gpio517/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio515/value 2>/dev/null; sleep 1.5; echo 1 > /sys/class/gpio/gpio517/value 2>/dev/null; sleep 1.0; echo 0 > /sys/class/gpio/gpio515/value 2>/dev/null; exit 0'

[Install]
WantedBy=multi-user.target
G4EOF
ln -sf ../trim-4g-power.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-4g-power.service" 2>/dev/null || true
echo "[fix_rootfs] 已安装 trim-4g-power.service"

# ==========================================================================
# ⑨ WiFi 固件 → /lib/firmware/
#
# bcmdhd 用 request_firmware()，路径相对 /lib/firmware/。
# 芯片实测 BCM4345/43455（AP6256），文件名要求 fw_bcm43456c5_ag.bin。
#   /lib/firmware/fw_bcm43456c5_ag.bin       ← 固件
#   /lib/firmware/fw_bcm43456c5_ag.clm_blob  ← CLM 数据
#   /lib/firmware/nvram_ap6256.txt           ← NVRAM
# 同时往 /vendor/etc/firmware/ 放一份（兼容旧路径）。
# ==========================================================================
FW_SRC="$(cd "$(dirname "$0")" && pwd)/firmware"
if [ -d "$FW_SRC" ]; then
  mkdir -p "$MNT/lib/firmware" 2>/dev/null || true
  # 驱动实际请求的文件名（dmesg 实测）：
  #   fw_bcm43456c5_ag.bin                 固件
  #   clm_bcm43456c5_ag.blob               CLM（注意：不是 fw_*_ag.clm_blob）
  #   nvram_ap6256.txt                     NVRAM
  #   config.txt
  for pair in \
      "fw_bcmdhd.bin:fw_bcm43456c5_ag.bin" \
      "clm_blob.bin:clm_bcm43456c5_ag.blob" \
      "clm_blob.bin:fw_bcm43456c5_ag.clm_blob" \
      "nvram.txt:nvram_ap6256.txt" \
      "config.txt:config.txt" \
      "fw_bcmdhd.bin:brcmfmac43456-sdio.bin" \
      "clm_blob.bin:brcmfmac43456-sdio.clm_blob" \
      "nvram.txt:brcmfmac43456-sdio.txt"
  do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if [ -f "$FW_SRC/$src" ]; then
      cp -f "$FW_SRC/$src" "$MNT/lib/firmware/$dst"
      echo "[fix_rootfs] 已安装 /lib/firmware/$dst ($(stat -c%s "$FW_SRC/$src" 2>/dev/null) 字节)"
    fi
  done
  # bcmdhd 有时直接读 /（相对 /lib/firmware/ 的绝对名），补一份到根
  [ -f "$FW_SRC/clm_blob.bin" ] && cp -f "$FW_SRC/clm_blob.bin" "$MNT/lib/firmware/clm_bcm43456c5_ag.blob"
  chmod 644 "$MNT/lib/firmware/"* 2>/dev/null || true

  # 兼容旧路径
  mkdir -p "$MNT/vendor/etc/firmware" 2>/dev/null || true
  [ -f "$FW_SRC/fw_bcmdhd.bin" ] && cp -f "$FW_SRC/fw_bcmdhd.bin" "$MNT/vendor/etc/firmware/fw_bcmdhd.bin"
  [ -f "$FW_SRC/nvram.txt" ]     && cp -f "$FW_SRC/nvram.txt"     "$MNT/vendor/etc/firmware/nvram.txt"
else
  echo "[fix_rootfs] 警告: 找不到 $FW_SRC，跳过 WiFi 固件"
fi

# ==========================================================================
# ⑩ 4G 拨号配置目录（预留）
# ==========================================================================
mkdir -p "$MNT/etc/mobile-broadband" 2>/dev/null || true


# ==========================================================================
# ⑪ trim-wifi-guard.service —— WiFi 兜底
#
# 问题：如果 WiFi 芯片打不开（WL_REG_ON 无效 / 固件不匹配），
#       bcmdhd 每次被探测都会卡 12 秒重试，导致 fnOS 网络设置转圈、
#       sshd 响应不过来。
#
# 兜底：开机 60 秒后检查 wlan0 是否真的 UP。
#       起不来就自动加黑名单 + 卸载模块，让系统不再等它。
#       WiFi 正常时这个服务不做任何事。
# ==========================================================================
cat > "$MNT/etc/systemd/system/trim-wifi-guard.service" <<'WGEOF'
[Unit]
Description=WiFi guard: retry bcmdhd load if wlan0 missing (NEVER blacklist)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 注意：绝对不能再写 /etc/modprobe.d/blacklist-bcmdhd.conf
# 之前那样做，一旦 WiFi 某次失败就永久屏蔽，之后再也不加载，
# 导致 nmcli radio 显示 "WIFI-HW missing"，用户只能刷机才能恢复。
# 现在只做一件事：清掉历史遗留的黑名单文件 + 尝试加载 bcmdhd。
ExecStart=/bin/bash -c 'rm -f /etc/modprobe.d/blacklist-bcmdhd.conf /etc/modprobe.d/*bcmdhd*.conf 2>/dev/null; sleep 20; if [ ! -d /sys/class/net/wlan0 ]; then echo "[wifi-guard] 无 wlan0，尝试加载 bcmdhd"; /sbin/modprobe bcmdhd 2>/dev/null; sleep 8; fi; if [ -d /sys/class/net/wlan0 ]; then echo "[wifi-guard] wlan0 存在，operstate=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"; /usr/bin/nmcli radio wifi on 2>/dev/null; else echo "[wifi-guard] bcmdhd 加载失败（硬件或固件问题，不写黑名单）"; fi; exit 0'

[Install]
WantedBy=multi-user.target
WGEOF
ln -sf ../trim-wifi-guard.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-wifi-guard.service" 2>/dev/null || true
echo "[fix_rootfs] 已安装 trim-wifi-guard.service（WiFi 兜底）"



# ==========================================================================
# ⑫ 4G 显示与联网修复（EC200A / nca9555，2026-11-25 板子实测）
#
# 问题1：ModemManager 把 usb0 当作 modem 的附属网口独占，
#        NetworkManager 会把它标记为 unmanaged (reason 'removed')，
#        fnOS 网络设置里完全看不到 4G。
#    → mask ModemManager，让 usb0 归 NetworkManager 管（普通 ethernet）
#
# 问题2：EC200A 的 ECM 模式没有 DHCP 服务器，usb0 拿不到 IPv4。
#    → 静态配 192.168.225.2/24，网关 192.168.225.1
#
# 问题3：NetworkManager 的 MAC 随机化让 WiFi 连接失败（bcmdhd 不支持运行中改 MAC）
#    → 关掉 wifi.scan-rand-mac-address + wifi.cloned-mac-address
#
# 问题4：nca9555 的 16 个 GPIO 必须全部按 Android 原厂 smdtio 默认值配置，
#        特别是 phone_en(pin14)，少了它 4G 拨号正常但 usb0 拿不到 IP。
#    → DTB 里已加 13 个 gpio-hog，这里再补一个 systemd 服务兜底
# ==========================================================================

# --- ① 关闭 NetworkManager 的 MAC 随机化（WiFi 连接必需）---
mkdir -p "$MNT/etc/NetworkManager/conf.d" 2>/dev/null || true
cat > "$MNT/etc/NetworkManager/conf.d/00-wifi-no-randmac.conf" <<'NMRANDEOF'
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=permanent
wifi.mac-address-randomization=never
ethernet.cloned-mac-address=permanent
NMRANDEOF
echo "[fix_rootfs] 已装 00-wifi-no-randmac.conf（关闭 MAC 随机化）"

# --- ② 让 NetworkManager 管理 usb0 ---
cat > "$MNT/etc/NetworkManager/conf.d/10-usb0-nm.conf" <<'NMUSBEOF'
# 让 NetworkManager 把 usb0 当普通以太网管（4G）
[device-usb0]
match-device=interface-name:usb0
managed=true

[keyfile]
unmanaged-devices=none
NMUSBEOF
echo "[fix_rootfs] 已装 10-usb0-nm.conf（usb0 归 NM 管）"

# --- ③ mask ModemManager（否则它独占 usb0，fnOS 看不到 4G）---
mkdir -p "$MNT/etc/systemd/system" 2>/dev/null || true
ln -sf /dev/null "$MNT/etc/systemd/system/ModemManager.service" 2>/dev/null || true
echo "[fix_rootfs] 已 mask ModemManager（让 usb0 归 NetworkManager）"

# --- ④ 4G usb0 静态 IP 服务（EC200A ECM 模式没有 DHCP）---
cat > "$MNT/usr/local/sbin/trim-4g-ip.sh" <<'G4IPSH'
#!/bin/bash
# 给 usb0 拿运营商 IP（适配 NetworkManager / dhclient / udhcpc / dhcpcd）
set +e

has_ip() {
    ip -4 addr show usb0 2>/dev/null | grep -q "inet "
}

# 已经有了就退出
has_ip && exit 0

i=0
while [ $i -lt 40 ]; do
    [ -d /sys/class/net/usb0 ] || { sleep 3; i=$((i+1)); continue; }

    # ① NetworkManager（fnOS / 桌面发行版）
    if command -v nmcli >/dev/null 2>&1; then
        nmcli con up "4G-USB0" >/dev/null 2>&1
        sleep 5
        has_ip && { echo "[trim-4g-ip] nmcli 成功"; exit 0; }
    fi

    # ② dhclient（Debian / Ubuntu / CentOS 常见）
    if command -v dhclient >/dev/null 2>&1; then
        ip link set usb0 up 2>/dev/null
        dhclient -1 -v usb0 >/dev/null 2>&1
        sleep 2
        has_ip && { echo "[trim-4g-ip] dhclient 成功"; exit 0; }
    fi

    # ③ udhcpc（busybox，openwrt 等）
    if command -v udhcpc >/dev/null 2>&1; then
        ip link set usb0 up 2>/dev/null
        udhcpc -i usb0 -q -n -t 5 >/dev/null 2>&1
        sleep 2
        has_ip && { echo "[trim-4g-ip] udhcpc 成功"; exit 0; }
    fi

    # ④ dhcpcd（Arch / 树莓派 OS）
    if command -v dhcpcd >/dev/null 2>&1; then
        ip link set usb0 up 2>/dev/null
        dhcpcd -1 -t 10 usb0 >/dev/null 2>&1
        sleep 2
        has_ip && { echo "[trim-4g-ip] dhcpcd 成功"; exit 0; }
    fi

    sleep 4
    i=$((i+1))
done

if has_ip; then
    echo "[trim-4g-ip] usb0 已拿到 IP: $(ip -4 addr show usb0 | grep inet | awk '{print $2}')"
else
    echo "[trim-4g-ip] 超时，usb0 未拿到 IP"
fi
exit 0
G4IPSH
chmod 755 "$MNT/usr/local/sbin/trim-4g-ip.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-4g-ip.service" <<'G4IPEOF'
[Unit]
Description=Bring up 4G usb0 via DHCP after QNETDEVCTL binding
After=trim-4g-apn.service
Wants=trim-4g-apn.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 顺序：trim-4g-apn 先跑完 AT+QNETDEVCTL=1,1,1（把 PDP 绑到 usb0）
#       然后这里去要运营商 IP
#
# 2026-11-26 改：不再硬依赖 nmcli。
#   fnOS / 桌面发行版  → NetworkManager（nmcli）
#   Ubuntu Server 24.04 → systemd-networkd（不装 NM，nmcli 不存在）
#   Debian / CentOS 等  → dhclient 或 dhcpcd
#   所以依次尝试：nmcli → dhclient → udhcpc → dhcpcd
ExecStart=/usr/local/sbin/trim-4g-ip.sh

[Install]
WantedBy=multi-user.target
G4IPEOF
ln -sf ../trim-4g-ip.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-4g-ip.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-4g-ip.service"

# --- ⑤ 预置 4G-USB0 的 NM 连接（静态 IP）---
mkdir -p "$MNT/etc/NetworkManager/system-connections" 2>/dev/null || true
cat > "$MNT/etc/NetworkManager/system-connections/4G-USB0.nmconnection" <<'G4CONEOF'
[connection]
id=4G-USB0
uuid=ec4cdc4a-e367-413d-af35-798701cc1ead
type=ethernet
interface-name=usb0
autoconnect=true
autoconnect-priority=10
# 每次连上都要等 QNETDEVCTL 绑定完成后再 DHCP
autoconnect-retries=0

[ethernet]
cloned-mac-address=permanent

[ipv4]
# ★ 关键：必须是 auto（DHCP）
# 板子实测：AT+QNETDEVCTL=1,1,1 绑定成功后，模块会通过 DHCP 直接下发
# 运营商 IP（例如 10.20.79.77/8，网关 10.20.79.178），3 秒内拿到。
# 写成 manual 反而会盖掉运营商 IP，只能拿 192.168.225.2 这个内网地址，
# 虽然能 ping 通但出口 IP 不对，且重启后 QNETDEVCTL 丢失就没网了。
method=auto
may-fail=true
dhcp-timeout=90

[ipv6]
method=ignore
G4CONEOF
chmod 600 "$MNT/etc/NetworkManager/system-connections/4G-USB0.nmconnection" 2>/dev/null || true
echo "[fix_rootfs] 已预置 4G-USB0 连接（静态 192.168.225.2/24）"

# --- ⑥ nca9555 全部 GPIO 兜底（DTB hog 之外的保险）---
cat > "$MNT/etc/systemd/system/trim-nca9555-all.service" <<'NCAEOF'
[Unit]
Description=Set nca9555 GPIOs for 4G only (LEDs belong to gpio-leds, do NOT touch)
After=local-fs.target
ConditionPathExists=/sys/class/gpio

[Service]
Type=oneshot
RemainAfterExit=yes
# ★ 绝对不要碰这几个脚，它们归 DTB 的 gpio-leds 节点管：
#   pin 1 = 4g   (led-3, default-state=on)
#   pin 4 = data (led-2, linux,default-trigger=mmc0)  ← 红灯，启动亮/eMMC空闲灭
#   pin 7 = pwr  (led-1, default-state=on)
# 之前把 1/4/7 也一并拉高，导致：
#   - 红灯（data, pin4）被强拉高 → 一直亮，mmc0 触发器失效
#   - leds 和 sysfs 抢同一个脚，状态打架
# 现在只配 4G 需要的那几个：
#   pin 0  usb0_power  high
#   pin 3  4g_reset    LOW (ACTIVE_LOW)
#   pin 5  4g_power    high
#   pin 8  4g_disable  high
#   pin 9  io1         high
#   pin 10 io2         high
#   pin 11 io3         high
#   pin 12 io4         high
#   pin 14 phone_en    high
ExecStart=/bin/bash -c 'for p in 0 3 5 8 9 10 11 12 14; do g=$((512+p)); if [ ! -d /sys/class/gpio/gpio$g ]; then echo $g > /sys/class/gpio/export 2>/dev/null; sleep 0.1; fi; if [ -d /sys/class/gpio/gpio$g ]; then echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null; echo 1 > /sys/class/gpio/gpio$g/value 2>/dev/null; fi; done; if [ -d /sys/class/gpio/gpio515 ]; then echo out > /sys/class/gpio/gpio515/direction 2>/dev/null; echo 0 > /sys/class/gpio/gpio515/value 2>/dev/null; fi; exit 0'

[Install]
WantedBy=multi-user.target
NCAEOF
ln -sf ../trim-nca9555-all.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-nca9555-all.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-nca9555-all.service（16 脚兜底）"



# ==========================================================================
# ⑬ 三网卡路由优先级（2026-11-25 板子实测）
#
# 问题：板子直连电脑时，eth0 的默认路由 metric 100 会抢占默认路由，
#       所有外网流量发给电脑（电脑没做 NAT）→ 应用中心打不开、上不了网。
#
# 修复：WiFi 做主路由（metric 50），eth0 降级（200），4G 最后（300）
# ==========================================================================
cat > "$MNT/usr/local/sbin/wan-failover.sh" <<'WANEOF'
#!/bin/bash
# WAN 自动选路：选真正能访问外网的接口
#
# 2026-11-27 重写：
#   原版 CAND_NAMES 硬编码 "Xiaomi_8D9F_5G-wlan0"，实际连接名是
#   "Xiaomi_8D9F-wlan0"，导致 nmcli 静默失败，
#   每 5 秒 nmcli con down/up 一次，反而把网络搞坏。
#
#   新版：按设备名反查真实连接名，拿不到就跳过，绝不空转。
#
# 2026-11-27 优先级：eth0 > wlan0 > usb0
#   有线最稳、不耗流量、带宽大

TEST_HOSTS="223.5.5.5 8.8.8.8"
CAND_IFS=("eth0" "wlan0" "usb0")
GOOD_METRIC=50
BAD_METRIC=600

HAS_NM=0
command -v nmcli >/dev/null 2>&1 && HAS_NM=1

net_ok() {
    local ifc="$1" h
    [ -d "/sys/class/net/$ifc" ] || return 1
    ip -4 addr show "$ifc" 2>/dev/null | grep -q "inet " || return 1
    for h in $TEST_HOSTS; do
        ping -c 1 -W 2 -I "$ifc" "$h" >/dev/null 2>&1 && return 0
    done
    return 1
}

# 按设备名反查 NetworkManager 连接名
nm_name() {
    nmcli -t -f NAME,DEVICE con show 2>/dev/null \
        | awk -F: -v d="$1" '$2==d{print $1; exit}'
}

set_metric() {
    local ifc="$1" m="$2"
    local cur have gw realname

    if [ "$HAS_NM" = "1" ]; then
        realname=$(nm_name "$ifc")
        [ -z "$realname" ] && return 0

        cur=$(nmcli -g ipv4.route-metric con show "$realname" 2>/dev/null)
        [ "$cur" = "$m" ] && return 0

        nmcli con mod "$realname" ipv4.route-metric "$m" 2>/dev/null || return 0

        if nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep -q "^${ifc}:connected"; then
            nmcli con down "$realname" >/dev/null 2>&1
            sleep 1
            nmcli con up "$realname" >/dev/null 2>&1
            echo "[wan-failover] ${ifc}(${realname}) metric ${cur:-无} -> ${m} (重新激活)"
        else
            echo "[wan-failover] ${ifc}(${realname}) metric ${cur:-无} -> ${m} (仅改配置)"
        fi
    else
        gw=$(ip route show default dev "$ifc" 2>/dev/null | awk '{print $3}' | head -1)
        [ -z "$gw" ] && return 0
        have=$(ip route show default dev "$ifc" 2>/dev/null | sed -n 's/.*metric \([0-9]*\).*/\1/p' | head -1)
        [ "$have" = "$m" ] && return 0
        ip route replace default via "$gw" dev "$ifc" metric "$m" 2>/dev/null || return 0
        echo "[wan-failover] ${ifc} 路由 metric ${have:-无} -> ${m}"
    fi
}

WINNER=""
for ifc in "${CAND_IFS[@]}"; do
    if net_ok "$ifc"; then
        WINNER="$ifc"
        break
    fi
done

for ifc in "${CAND_IFS[@]}"; do
    if [ "$ifc" = "$WINNER" ]; then
        set_metric "$ifc" "$GOOD_METRIC"
    else
        set_metric "$ifc" "$BAD_METRIC"
    fi
done

echo "[wan-failover] winner=${WINNER:-none} nm=$HAS_NM"

WANEOF
chmod 755 "$MNT/usr/local/sbin/wan-failover.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-wan-failover.service" <<'WANSVCEOF'
[Unit]
Description=WAN auto failover by real internet reachability
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
# 2026-11-26：轮询间隔 15s -> 5s，断网后更快切换
# 开机先等 20 秒让网络起来，之后每 5 秒测一次
ExecStart=/bin/bash -c 'sleep 20; while true; do /usr/local/sbin/wan-failover.sh; sleep 5; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
WANSVCEOF
ln -sf ../trim-wan-failover.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-wan-failover.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-wan-failover（按实际外网连通性自动选路）"

# ==========================================================================
# ⑭ 4G APN 配置（中国电信 ctlte）
#
# 实测结论：
#   APN=ctlte  → AT+QPING 返回 0,5,0,5,0,0,0（通！）
#   APN=ctnet  → AT+QPING 返回 559（不通）
# 所以必须用 ctlte。
# ==========================================================================
cat > "$MNT/etc/systemd/system/trim-4g-apn.service" <<'APNEOF'
[Unit]
Description=Configure 4G data call (APN=ctnet + QIACT + QNETDEVCTL bind to usb0)
After=local-fs.target trim-4g-power.service
Wants=trim-4g-power.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 2026-11-25 板子实测：Android 的 libreference-ril-quectel.so 用这套流程
#   AT+QICSGP   设 APN（ctnet + 电信认证 ctnet@mycdma.cn）
#   AT+QIDEACT  去激活
#   AT+QIACT    激活 PDP（拿到运营商 IP，如 10.143.40.45）
#   AT+QNETDEVCTL=1,1,1   ★★★ 把 PDP 绑定到 usb0 网卡
#                         —— 少了这一步，usb0 有 IP 但完全不通！
ExecStart=/bin/bash -c 'D=/dev/ttyUSB2; i=0; while [ ! -e $D ] && [ $i -lt 40 ]; do sleep 2; i=$((i+1)); done; [ -e $D ] || exit 0; sleep 12; printf "AT+QICSGP=1,1,\"ctnet\",\"ctnet@mycdma.cn\",\"ctnet@mycdma.cn\",0\r" > $D; sleep 2; printf "AT+QIDEACT=1\r" > $D; sleep 3; printf "AT+QIACT=1\r" > $D; sleep 6; printf "AT+QNETDEVCTL=1,1,1\r" > $D; sleep 3; exit 0'

[Install]
WantedBy=multi-user.target
APNEOF
ln -sf ../trim-4g-apn.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-4g-apn.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-4g-apn.service（APN=ctlte）"


# ==========================================================================
# ⑲ reboot-loader：一键进入 Loader（USB 烧写模式）
#
# 背景（Android 固件分析结论）：
#   parameter.txt 里 bootdelay=0、preboot= 为空，
#   所以开机时 u-boot 根本不检查按键，物理按键进不了 Loader。
#   uboot.img-unpack/fdt.dts 里 adc-keys 虽然定义了 volumeup-key，
#   但 preboot 为空，这个驱动不会被调用来作为启动模式判断。
#
#   唯一可靠方式：写 reboot-mode 寄存器（syscon-reboot-mode）
#     syscon@fd588000, offset 0x80 → 0xfd588080
#     mode-loader = 0x5242c301
#   板子实测有效，重启后进入 LOADER 等待 USB 烧写。
# ==========================================================================
cat > "$MNT/usr/local/sbin/reboot-loader.sh" <<'REBOOTEOF'
#!/bin/bash
# 进入 Loader（USB 烧写）模式
# 用法：sudo reboot-loader
set -e

if [ "$(id -u)" != "0" ]; then
    echo "需要 root 权限：sudo reboot-loader"
    exit 1
fi

echo "写入 reboot-mode = loader ..."
python3 - <<'PYEOF'
import os, mmap, struct
ADDR = 0xfd588000
OFF  = 0x80
VAL  = 0x5242c301   # mode-loader

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
try:
    m = mmap.mmap(fd, 4096, offset=ADDR)
    before = struct.unpack('<I', m[OFF:OFF+4])[0]
    m[OFF:OFF+4] = struct.pack('<I', VAL)
    after = struct.unpack('<I', m[OFF:OFF+4])[0]
    print('  0x%08x: 0x%08x -> 0x%08x' % (ADDR + OFF, before, after))
finally:
    os.close(fd)
PYEOF

sync
echo "重启进入 Loader 模式..."
echo "重启后请用 USB Type-C 连接电脑，打开 RKDevTool 烧写"
sleep 1
reboot -f
REBOOTEOF
chmod 755 "$MNT/usr/local/sbin/reboot-loader.sh" 2>/dev/null || true






# ==========================================================================
# ㉖ netplan 配置（Ubuntu / Debian 的 systemd-networkd 需要）
#
# 问题实证（Ubuntu 24.04 刷机后）：
#   [FAILED] systemd-networkd-wait-online - Wait for Network to be Configured
#   网口灯不亮，拿不到 IP
#
# 根因：
#   Ubuntu Server 用 netplan 管理网络，只配置 netplan 里列出的接口。
#   原厂镜像的 /etc/netplan/*.yaml 只有它自己板的接口名，
#   我们的 eth0 / wlan0 / usb0 不在里面，networkd 就不管它们。
#
# 只对 Ubuntu / Debian 系生效（有 netplan 才写），其他系统自动跳过。
# ==========================================================================
if [ -d "$MNT/etc/netplan" ]; then
cat > "$MNT/etc/netplan/99-kdev-network.yaml" <<'NETPLANEOF'
# kdev: 确保板子的三个网口都被 systemd-networkd 管理
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 50
      optional: true
    usb0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 600
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
      optional: true
      access-points: {}
NETPLANEOF
chmod 600 "$MNT/etc/netplan/99-kdev-network.yaml"
echo "[fix_rootfs] 已装 99-kdev-network.yaml（netplan 配置 eth0/usb0/wlan0）"

# 同时把原来的 netplan 配置备份并清空（防止它把接口设成静态/禁用）
for f in "$MNT"/etc/netplan/*.yaml; do
    case "$f" in
        *99-kdev-network.yaml) continue;;
    esac
    [ -f "$f" ] || continue
    if grep -qE 'dhcp4:\s*false|addresses:' "$f" 2>/dev/null; then
        mv "$f" "$f.kdevbak" 2>/dev/null || true
        echo "[fix_rootfs] 已禁用原 netplan 配置: $(basename $f)"
    fi
done
fi


# ==========================================================================
# ㉗ 其它网络栈适配（ifupdown / UCI）
#
# 已覆盖：
#   NetworkManager  → fnOS / CentOS / Fedora / Rocky / armbian / Kali 等
#   netplan         → Ubuntu（见 ㉖）
#
# 本段补：
#   ifupdown        → Debian（/etc/network/interfaces.d/）
#   UCI             → OpenWrt / iStoreOS（/etc/config/network）
#
# 判断方式：看系统用什么工具，不会互相干扰。
# ==========================================================================

# ① ifupdown（Debian 系非 netplan 模式）
if [ -d "$MNT/etc/network" ] && [ ! -d "$MNT/etc/netplan" ]; then
    mkdir -p "$MNT/etc/network/interfaces.d"
    cat > "$MNT/etc/network/interfaces.d/kdev-ifupdown" <<'IFEOF'
# kdev: 确保板子网口自动 DHCP
auto lo
iface lo inet loopback

allow-hotplug eth0
auto eth0
iface eth0 inet dhcp
    metric 600

allow-hotplug usb0
auto usb0
iface usb0 inet dhcp
    metric 100

allow-hotplug wlan0
auto wlan0
iface wlan0 inet dhcp
    metric 50
IFEOF
    chmod 644 "$MNT/etc/network/interfaces.d/kdev-ifupdown"
    # 确保主配置文件会读 interfaces.d
    if [ -f "$MNT/etc/network/interfaces" ]; then
        if ! grep -q 'interfaces.d' "$MNT/etc/network/interfaces" 2>/dev/null; then
            echo 'source /etc/network/interfaces.d/*' >> "$MNT/etc/network/interfaces"
            echo "[fix_rootfs] 已在 /etc/network/interfaces 加 source 行"
        fi
    fi
    echo "[fix_rootfs] 已装 ifupdown 配置（Debian）"
fi

# ② UCI（OpenWrt / iStoreOS）
if [ -f "$MNT/etc/config/network" ]; then
    # 检查是否已有 eth0 配置
    if ! grep -qE "option +ifname +'eth0'" "$MNT/etc/config/network" 2>/dev/null \
       && ! grep -qE 'option +device +.eth0.' "$MNT/etc/config/network" 2>/dev/null; then
        cat >> "$MNT/etc/config/network" <<'UCIEOF'

# kdev: 板子网口（追加）
config interface 'kdeth0'
	option proto 'dhcp'
	option device 'eth0'
	option metric '50'

config interface 'kdusb0'
	option proto 'dhcp'
	option device 'usb0'
	option metric '600'
UCIEOF
        echo "[fix_rootfs] 已追加 OpenWrt UCI 配置"
    else
        echo "[fix_rootfs] OpenWrt 已有 eth0 配置，跳过"
    fi
fi


# ==========================================================================
# ㉘ eth0 重试（关键：GMAC DMA 第一次初始化会失败）
#
# 问题实证（board 串口日志，所有系统都一样）：
#   [15.78] rk_gmac-dwmac fe1c0000.ethernet: Failed to reset the dma
#   [15.78] rk_gmac-dwmac fe1c0000.ethernet eth0: stmmac_hw_setup: DMA engine initialization failed
#   [15.78] rk_gmac-dwmac fe1c0000.ethernet eth0: __stmmac_open: Hw setup failed
#
#   但 fnOS 上能看到后续日志：
#   [19.20] rk_gmac-dwmac fe1c0000.ethernet: configuring for phy/rgmii-rxid link mode
#   [19.83] rk_gmac-dwmac fe1c0000.ethernet eth0: Link is Up - 1Gbps/Full
#
#   原因：第一次 open 时 PHY/DMA 时序没就绪，失败；
#        NetworkManager 自动重试，第二次就成功。
#        Ubuntu 的 systemd-networkd 不重试，所以永远 DOWN。
#
# 方案：开机后自动把 eth0 down/up 若干次，直到 Link is Up。
#       对所有系统生效（纯 ip 命令，不依赖网络栈）。chmod 755 "$MNT/usr/local/sbin/trim-eth-retry.sh" 2>/dev/null || true

echo "[fix_rootfs] 已装（eth0 自动重试，修复 GMAC DMA 首次失败）"


# ==========================================================================
# ㉙ 无线工具探测（只读，不改 rootfs）
#
# 目的：确认各发行版 rootfs 里到底有没有 wpa_supplicant / iw / nmcli，
#       决定下一步要不要在固件里补装。
#
# 检查内容：
#   ① 二进制是否存在（多个常见路径）
#   ② 包管理器类型（dpkg / rpm / opkg）
#   ③ 网络管理栈（NetworkManager / netplan / ifupdown / UCI）
# ==========================================================================
echo "[probe-wifi] ================ 无线工具探测 ================"
echo "[probe-wifi] vendor=${set_vendor} rootfs=${set_rootfs}"

_wifi_probe() {
    local name="$1"; shift
    local found=""
    for p in "$@"; do
        if [ -e "$MNT$p" ]; then
            found="$found $p"
        fi
    done
    if [ -n "$found" ]; then
        echo "[probe-wifi]   HAVE  ${name}:${found}"
    else
        echo "[probe-wifi]   MISS  ${name}"
    fi
}

_wifi_probe wpa_supplicant /usr/sbin/wpa_supplicant /sbin/wpa_supplicant /usr/bin/wpa_supplicant
_wifi_probe wpa_cli        /usr/sbin/wpa_cli /sbin/wpa_cli /usr/bin/wpa_cli
_wifi_probe iw             /usr/sbin/iw /sbin/iw /usr/bin/iw
_wifi_probe iwlist         /usr/sbin/iwlist /sbin/iwlist /usr/bin/iwlist
_wifi_probe nmcli          /usr/bin/nmcli /usr/sbin/nmcli
_wifi_probe hostapd        /usr/sbin/hostapd /usr/bin/hostapd
_wifi_probe dnsmasq        /usr/sbin/dnsmasq /usr/bin/dnsmasq
_wifi_probe udhcpc         /usr/sbin/udhcpc /sbin/udhcpc /usr/bin/udhcpc
_wifi_probe dhclient       /usr/sbin/dhclient /sbin/dhclient /usr/bin/dhclient
_wifi_probe busybox        /bin/busybox /usr/bin/busybox

# 包管理器
if [ -x "$MNT/usr/bin/dpkg" ] || [ -x "$MNT/bin/dpkg" ]; then
    echo "[probe-wifi]   PKGMGR dpkg-deb"
fi
if [ -x "$MNT/usr/bin/rpm" ] || [ -x "$MNT/bin/rpm" ]; then
    echo "[probe-wifi]   PKGMGR rpm"
fi
if [ -x "$MNT/bin/opkg" ] || [ -x "$MNT/usr/bin/opkg" ]; then
    echo "[probe-wifi]   PKGMGR opkg"
fi

# 网络管理栈
[ -d "$MNT/etc/NetworkManager" ]   && echo "[probe-wifi]   NETMGR NetworkManager"
[ -d "$MNT/etc/netplan" ]          && echo "[probe-wifi]   NETMGR netplan"
[ -f "$MNT/etc/network/interfaces" ] && echo "[probe-wifi]   NETMGR ifupdown"
[ -f "$MNT/etc/config/network" ]   && echo "[probe-wifi]   NETMGR UCI(openwrt)"
[ -d "$MNT/etc/systemd" ]          && echo "[probe-wifi]   NETMGR systemd"

# bcmdhd 驱动
if [ -d "$MNT/lib/modules" ]; then
    _drv=$(find "$MNT/lib/modules" -maxdepth 3 -name 'bcmdhd.ko*' 2>/dev/null | head -1)
    if [ -n "$_drv" ]; then
        echo "[probe-wifi]   HAVE  bcmdhd.ko: ${_drv#$MNT}"
    else
        echo "[probe-wifi]   MISS  bcmdhd.ko（内核模块，非 http 目录）"
    fi
fi

echo "[probe-wifi] ================ 探测结束 ================"


# 同时处理 /usr/bin 下的软链（openzfs 通常 /usr/bin/zpool -> ../sbin/zpool）
if [ -L "$MNT/usr/bin/zpool" ] || [ -f "$MNT/usr/bin/zpool" ]; then
    :
fi



# ==========================================================================
# ⑳ 修正 data 分区（mmcblk0p5）的 GPT 标志
#
# 问题实证（板子实测）：
#   fnOS 创建存储空间时反复失败：
#     mdadm: Couldn't open /dev/mmcblk0p5 for write - not zeroing
#     wipefs: /dev/mmcblk0p5: probing initialization failed: Device or resource busy
#     [ERROR] erase superblock: /dev/mmcblk0p5
#
#   根因：mmcblk0p5 的 GPT 属性位带了 "raid" 标记，
#   内核把它当成 RAID 成员（linux_raid_member），
#   开机时 mdadm 自动组装成 md0/md1 抢占设备，
#   飞牛再想 --create / --zero-superblock 就拿不到独占写权限。
#
#   手动 parted /dev/mmcblk0 --script set 5 raid off 之后，
#   网页"创建存储空间"一次成功。
#
# 本服务：开机时把 p5 的 raid 标志去掉（只动标志位，不碰数据）。
#   若 md 已经把 p5 抢走，先 stop 掉再改标志，之后不重启它。
# ==========================================================================
cat > "$MNT/usr/local/sbin/trim-fix-p5-flag.sh" <<'P5FLAGEOF'
#!/bin/bash
# 去掉 data 分区（mmcblk0p5）的 GPT raid 标志
# 只动 GPT 属性位，不动分区内容
set -u

DEV=/dev/mmcblk0
PART=5

[ -b "${DEV}p${PART}" ] || exit 0

# 当前标志
cur=$(parted "$DEV" --script print 2>/dev/null | awk -v p="$PART" '$1==p {print $NF}')
case "$cur" in
    raid) ;;
    *) exit 0 ;;   # 已经没有 raid 标志，什么都不做
esac

# 先把可能被 md 抢走的设备放开
for m in /dev/md*; do
    [ -b "$m" ] || continue
    if mdadm --detail "$m" 2>/dev/null | grep -q "${DEV}p${PART}"; then
        mdadm --stop "$m" 2>/dev/null || true
    fi
done

# 去标志
parted "$DEV" --script set "$PART" raid off 2>/dev/null || true
echo "[trim-fix-p5-flag] 已去掉 ${DEV}p${PART} 的 raid 标志"
exit 0
P5FLAGEOF
chmod 755 "$MNT/usr/local/sbin/trim-fix-p5-flag.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-fix-p5-flag.service" <<'P5SVCEOF'
[Unit]
Description=Clear raid GPT flag on data partition (mmcblk0p5)
DefaultDependencies=no
Before=local-fs.target trim_init.service
After=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/trim-fix-p5-flag.sh

[Install]
WantedBy=sysinit.target
P5SVCEOF
ln -sf ../trim-fix-p5-flag.service \
  "$MNT/etc/systemd/system/sysinit.target.wants/trim-fix-p5-flag.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-fix-p5-flag（去掉 data 分区的 raid GPT 标志）"



# ==========================================================================
# ㉑ /volN 挂载点管理 + 兜底挂载
#
# 板子实测完整结论（2026-11-27，两轮反汇编 + LD_PRELOAD 钩子）：
#
# ① fnOS 的 is_mountpoint(p) 实现（/usr/trim/lib/libnfile.so:0x3690）：
#       return faccessat(AT_FDCWD, p, F_OK, flags) != 0;
#    语义反了：路径"不存在"时返回 true。
#
# ② storage.hdl 的 stor_create()：
#       sprintf(buf, "/vol%u", vol_id);
#       if (is_mountpoint(buf, 0)) {        // 目录不存在 → true
#           errno = 0x30008;                // E_MOUNTPOINT_EXISTS
#           return -1;                      // 前端"挂载点已存在"
#       }
#       ... mount(...)                      ← 但这步飞牛实际不执行
#   所以 /volN 目录必须先存在，飞牛才肯创建。
#
# ③ 但飞牛 mkfs + INSERT INTO mount 之后，就不再 mount /volN 了
#    （因为 triminit 的 mount_storage() 在
#      `mount -t trimafs trimafs /fs` 失败后提前退出了，
#      而 trimafs 是飞牛自研文件系统，内核里没有这个模块）。
#
# ④ 手动 mount /volN 之后，飞牛会自己继续完成后续：
#    建子卷 1000、建 @appcenter 等、建 thumb。界面显示正常。
#
# 所以本服务做两件事：
#   A. 开机预建 /vol1 - /vol9 目录（绝不挂载）
#   B. 循环检测：数据库 mount 表里有 id=N 的记录 + 对应 LV 有 btrfs
#      + 飞牛没有存储操作进程 → mount /volN
#
# 绝不：mdadm / pvcreate / vgcreate / lvcreate / mkfs / umount
# ==========================================================================
cat > "$MNT/usr/local/sbin/trim-vol-heal.sh" <<'VOLHEALEOF'
#!/bin/bash
# /volN 目录预建 + 兜底挂载
set -u

_log() { echo "[trim-vol-heal] $*"; }

# ---------- A. 预建目录（只建目录，绝不挂载） ----------
for _i in 1 2 3 4 5 6 7 8 9; do
    [ -d "/vol$_i" ] || mkdir -p "/vol$_i" 2>/dev/null
done
_log "已预建 /vol1 - /vol9"

# ---------- 工具函数 ----------
_busy() {
    local n
    n=$(pgrep -af 'mdadm|vgcreate|lvcreate|mkfs\.btrfs|pvcreate|wipefs' 2>/dev/null \
        | grep -vE 'mdadm --monitor|pgrep|grep|trim-vol-heal' | wc -l)
    [ "$n" -gt 0 ] && return 0
    return 1
}

_has_btrfs() { blkid "$1" 2>/dev/null | grep -q 'TYPE="btrfs"'; }

# 数据库里该卷对应的 LV 设备路径（uuid 形如 trim_xxx-0）
_lv_of_vid() {
    local vid="$1" uuid base
    uuid=$(su - postgres -c "psql -d trim -tAc \"SELECT uuid FROM mount WHERE id=$vid\"" 2>/dev/null | tr -d ' \n')
    [ -z "$uuid" ] && return 1
    base="${uuid%-0}"
    [ -e "/dev/mapper/${base}" ] && { echo "/dev/mapper/${base}"; return 0; }
    [ -e "/dev/mapper/${uuid}" ] && { echo "/dev/mapper/${uuid}"; return 0; }
    return 1
}

_ensure_appdirs() {
    local mp="$1" d
    mountpoint -q "$mp" 2>/dev/null || return 0
    for d in @appcenter @appconf @appdata @apphome @appmeta @appshare @apptemp; do
        [ -d "$mp/$d" ] || mkdir -p "$mp/$d" 2>/dev/null
    done
}

_try_mount() {
    local vid="$1"
    local mp="/vol$vid"
    local lv
    mountpoint -q "$mp" 2>/dev/null && return 0
    lv=$(_lv_of_vid "$vid") || return 1
    [ -e "$lv" ] || return 1
    _has_btrfs "$lv" || return 1
    if mount "$lv" "$mp" 2>/dev/null; then
        _log "mounted $lv -> $mp"
        return 0
    fi
    return 1
}

# ---------- B. 主循环 ----------
# 开机先等 triminit / trim_main 起来
sleep 45
_log "开始循环（每 5 秒检查一次）"

_quiet=0
while true; do
    if _busy; then
        _quiet=0
    else
        _quiet=$((_quiet + 1))
        # 连续 3 轮（15 秒）飞牛没动作，才去挂
        if [ "$_quiet" -ge 3 ]; then
            for _v in 1 2 3 4 5 6 7 8 9; do
                if mountpoint -q "/vol$_v" 2>/dev/null; then
                    _ensure_appdirs "/vol$_v"
                else
                    _try_mount "$_v"
                fi
            done
            _quiet=0
        fi
    fi
    sleep 5
done
VOLHEALEOF
chmod 755 "$MNT/usr/local/sbin/trim-vol-heal.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-vol-heal.service" <<'VOLSVCEOF'
[Unit]
Description=Pre-create /volN mountpoints and mount them if fnOS did not
After=postgresql.service trim_main.service
Wants=postgresql.service
ConditionPathExists=/usr/trim/bin/trim

[Service]
Type=simple
ExecStart=/usr/local/sbin/trim-vol-heal.sh
Restart=always
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
VOLSVCEOF
ln -sf ../trim-vol-heal.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-vol-heal.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-vol-heal（预建 /volN + 兜底挂载）"


echo "[fix_rootfs] 全部完成"
exit 0
