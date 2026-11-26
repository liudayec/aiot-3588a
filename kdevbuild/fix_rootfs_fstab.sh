#!/bin/bash
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
# WAN 自动选路（2026-11-26 改：兼容 NetworkManager 和 systemd-networkd）
#
# 三网口同时在线，自动选真正能访问外网的那条。
# 某个口有 IP 但上不了外网时自动让位。
#
# 两种网络栈：
#   NetworkManager    → nmcli con mod route-metric + con up 重新激活
#   systemd-networkd  → ip route replace metric
#   都没有          → 直接 ip route
#
# 轮询间隔 5 秒（trim-wan-failover.service 里控制）

TEST_HOSTS="223.5.5.5 8.8.8.8"
CAND_IFS=("wlan0" "usb0" "eth0")
CAND_NAMES=("Xiaomi_8D9F_5G-wlan0" "4G-USB0" "Wired connection 1")
GOOD_METRIC=50
BAD_METRIC=600

# 检测网络栈
HAS_NM=0
HAS_NETWORKD=0
command -v nmcli >/dev/null 2>&1 && HAS_NM=1
systemctl is-active --quiet systemd-networkd 2>/dev/null && HAS_NETWORKD=1

net_ok() {
    local ifc="$1" h
    [ -d "/sys/class/net/$ifc" ] || return 1
    ip -4 addr show "$ifc" 2>/dev/null | grep -q "inet " || return 1
    for h in $TEST_HOSTS; do
        ping -c 1 -W 2 -I "$ifc" "$h" >/dev/null 2>&1 && return 0
    done
    return 1
}

WINNER=""
for i in 0 1 2; do
    if net_ok "${CAND_IFS[$i]}"; then
        WINNER="${CAND_IFS[$i]}"
        break
    fi
done

# 设置某个网口的 metric
set_metric() {
    local ifc="$1" name="$2" m="$3"
    local cur=""

    if [ "$HAS_NM" = "1" ]; then
        cur=$(nmcli -g ipv4.route-metric con show "$name" 2>/dev/null)
        if [ "$cur" != "$m" ]; then
            nmcli con mod "$name" ipv4.route-metric "$m" 2>/dev/null
            if nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep -q "^${ifc}:connected"; then
                nmcli con down "$name" >/dev/null 2>&1
                sleep 1
                nmcli con up "$name" >/dev/null 2>&1
                echo "[wan-failover] ${ifc} metric ${cur} -> ${m} (nmcli 重新激活)"
            else
                echo "[wan-failover] ${ifc} metric ${cur} -> ${m} (nmcli 仅改配置)"
            fi
        fi
    else
        # systemd-networkd 或无 NM：直接改路由表
        local gw
        gw=$(ip route show default dev "$ifc" 2>/dev/null | awk '{print $3}' | head -1)
        if [ -n "$gw" ]; then
            local have
            have=$(ip route show default dev "$ifc" 2>/dev/null | grep -oP 'metric \K\d+' | head -1)
            if [ "$have" != "$m" ]; then
                ip route replace default via "$gw" dev "$ifc" metric "$m" 2>/dev/null
                echo "[wan-failover] ${ifc} 路由 metric ${have:-无} -> ${m} (ip route)"
            fi
        fi
    fi
}

for i in 0 1 2; do
    ifc="${CAND_IFS[$i]}"
    name="${CAND_NAMES[$i]}"
    if [ "$ifc" = "$WINNER" ]; then
        set_metric "$ifc" "$name" "$GOOD_METRIC"
    else
        set_metric "$ifc" "$name" "$BAD_METRIC"
    fi
done

echo "[wan-failover] winner=${WINNER:-none} nm=$HAS_NM networkd=$HAS_NETWORKD"

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
# ⑯ 修复 fnOS 建表时序（存储池创建卡最后一步的根因）
#
# 问题实证（板子 journalctl）：
#   trim_init.service 的 After 只有 rc-local.service，没等 PostgreSQL：
#     21:53:37 triminit: Open database error: No such file or directory
#     21:53:38 triminit: Open database error: ...
#     21:53:41 triminit: ERROR: relation "mount" does not exist
#     21:53:43 trim_sac: ERROR: relation "common_config" does not exist
#
# 后果：
#   - trim.mount / trim.storage 等表缺失或为空
#   - appcenter.common_config 表不存在
#   - fnOS 网页"创建存储空间"填完参数后写库失败 → 卡在最后一步
#   - 应用中心"文件夹存储位置"永远空
#
# 修复：等 PostgreSQL 真正可连接后重跑 triminit（它会补建缺失的表）
# ==========================================================================
cat > "$MNT/etc/systemd/system/trim-db-init.service" <<'DBINITEOF'
[Unit]
Description=Re-run triminit after PostgreSQL is ready (creates missing fnOS tables)
After=postgresql.service postgresql@15-main.service trim_init.service
Wants=postgresql.service
ConditionPathExists=/usr/trim/bin/triminit

[Service]
Type=oneshot
RemainAfterExit=yes
# 2026-11-25 修复：上一版把 psql 的 SQL 用 $$ 括起来，systemd 会把它当变量展开，
# 导致 /bin/bash: syntax error near unexpected token `('
# 改成用独立脚本，避开 systemd 的引号解析
ExecStart=/usr/local/sbin/trim-db-init.sh
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
DBINITEOF
ln -sf ../trim-db-init.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-db-init.service" 2>/dev/null || true

cat > "$MNT/usr/local/sbin/trim-db-init.sh" <<'DBINITSH'
#!/bin/bash
# 等 PostgreSQL 就绪后重跑 triminit，补建 fnOS 缺失的表
i=0
while [ $i -lt 60 ]; do
  if pg_isready -q -h /var/run/postgresql 2>/dev/null; then
    break
  fi
  sleep 2
  i=$((i+1))
done

sleep 5

# 检查 common_config 表是否存在，不存在就重跑 triminit
EXIST=$(su - postgres -c "psql -d appcenter -tAc \"SELECT count(*) FROM information_schema.tables WHERE table_name='common_config'\"" 2>/dev/null | tr -d ' \n')

if [ "$EXIST" != "1" ]; then
  echo "[trim-db-init] common_config missing, re-running triminit"
  /usr/trim/bin/triminit 2>&1
  sleep 3
  EXIST=$(su - postgres -c "psql -d appcenter -tAc \"SELECT count(*) FROM information_schema.tables WHERE table_name='common_config'\"" 2>/dev/null | tr -d ' \n')
fi

echo "[trim-db-init] common_config exists: ${EXIST:-0}"
exit 0
DBINITSH
chmod 755 "$MNT/usr/local/sbin/trim-db-init.sh" 2>/dev/null || true
echo "[fix_rootfs] trim-db-init 已改成独立脚本（避免 systemd 引号问题）"

ln -sf ../trim-db-init.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-db-init.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-db-init（等 PostgreSQL 就绪后补建 fnOS 表）"



# ==========================================================================
# ⑰ 存储操作辅助：fnOS 创建/删除存储空间时自动释放 /vol1 占用
#
# 问题实证（板子 journalctl）：
#   删除存储空间时失败：
#     umount -A -R --force /dev/dm-0  →  EXITSTATUS=32（device busy）
#     lvremove --force --force -y     →  EXITSTATUS=5
#   原因：
#     trim_file_monitor (PID 1477) 持有 /vol1 目录句柄（lsof 可见 FD 20r DIR）
#     → umount 失败 → 后续 lvremove/vgremove 全部失败
#     → 网页显示"删除失败"
#
#   手动测试：先 systemctl stop trim_file_monitor finder_service dlcenter
#             再 umount /vol1 → 成功，lvremove 也成功
#
# 本服务做两件事：
#   1. 提供一个脚本 /usr/local/sbin/storage-release.sh，手动调用可释放占用
#   2. 开机时给 fnOS 的服务加 After 依赖，让 trim_file_monitor 不要过早打开 /vol1
#
# 用法（SSH 里删除存储空间失败时）：
#   sudo /usr/local/sbin/storage-release.sh
#   然后网页上重新点删除
# ==========================================================================
cat > "$MNT/usr/local/sbin/storage-release.sh" <<'RELEASEEOF'
#!/bin/bash
# 释放 /vol1 上的所有占用，让 fnOS 能正常 umount / 删除存储空间
# 用法：sudo storage-release.sh [--restore]
#   --restore  操作完恢复服务

RESTORE=0
[ "$1" = "--restore" ] && RESTORE=1

echo "[storage-release] 停止占用 /vol1 的服务..."
for s in trim_file_monitor finder_service auto_thumbnailer_service \
         dlcenter trim_app_center cloud_storage_dav avahi; do
    if systemctl is-active "$s" >/dev/null 2>&1; then
        systemctl stop "$s" 2>/dev/null && echo "  停 $s"
    fi
done

sleep 2

# 处理所有 /vol 开头的挂载点
for mp in $(mount | grep -oP 'on \K/vol[0-9]+' | sort -u); do
    echo "[storage-release] 卸载 $mp"
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
done

# 也处理 fnOS 内部的 /fs
if mountpoint -q /fs 2>/dev/null; then
    echo "[storage-release] 卸载 /fs"
    umount /fs 2>/dev/null || umount -l /fs 2>/dev/null || true
fi

echo "[storage-release] 释放完成"
echo "  现在可以去网页上操作存储空间了"

if [ "$RESTORE" = "1" ]; then
    echo "[storage-release] 恢复服务..."
    systemctl start trim_file_monitor finder_service trim_app_center 2>/dev/null
    echo "  已恢复"
fi

exit 0
RELEASEEOF
chmod 755 "$MNT/usr/local/sbin/storage-release.sh" 2>/dev/null || true

# 给 trim_file_monitor 加 After，确保它不会在 fnOS 挂载之前打开 /vol1
mkdir -p "$MNT/etc/systemd/system/trim_file_monitor.service.d" 2>/dev/null || true
cat > "$MNT/etc/systemd/system/trim_file_monitor.service.d/10-wait-vol1.conf" <<'DROPEOF'
[Unit]
# 2026-11-25：把启动顺序调到 trim_main 之后，
# 避免 fnOS 还在创建/挂载存储空间时 trim_file_monitor 就打开 /vol1，
# 导致后续 umount 报 device busy（网页上"删除存储空间"失败）
After=trim_main.service postgresql.service
Wants=trim_main.service
DROPEOF
echo "[fix_rootfs] 已装 storage-release.sh + trim_file_monitor 启动顺序修正"



# ==========================================================================
# ⑱ /vol1 自愈（2026-11-26 v3，独立脚本版）
#
# 背景：
#   fnOS 创建存储空间时 mdadm/LVM/mkfs.btrfs 全部成功（日志已证实），
#   但挂载到 /vol1 这一步有时没做成，导致网页显示创建失败。
#
# 历史问题（已修）：
#   v1: 开机 00:47:02 跑，存储 00:47:56 才建好 → 跑太早找不到 LV
#   v2: 写 bash -c '... n=$((n+1)) ...'，systemd 会展开 $((...)) → 循环失效，
#       服务 16 毫秒就"成功"退出但 /vol1 没挂上
#   v3: 改成独立脚本 /usr/local/sbin/trim-vol1-heal.sh，service 只调用它，
#       避开 systemd 对 $ 变量和引号的解析；每 3 秒重试，最多 60 秒。
#
# 绝不做：mdadm create / pvcreate / vgcreate / lvcreate / mkfs
# ==========================================================================
cat > "$MNT/usr/local/sbin/trim-vol1-heal.sh" <<'HEALSH_EOF'
#!/bin/bash
# 确保 /vol1 挂载好（激活 LVM + 挂现有 btrfs LV）
#
# 绝不做：mdadm create / pvcreate / vgcreate / lvcreate / mkfs
# 只做：vgchange -ay + mount
#
# 2026-11-26 实证（飞牛首次创建存储空间）：
#   trim-vol1-heal 在 23:02:03 启动
#   用户的 LV 在 23:06:26 才创建（晚了 4 分钟）
#   原来的 20 次 × 3s = 60 秒等不够 → 报 not mounted after 60s
#
# 现在改成两级：
#   ① 快等：20 次 × 3s = 60 秒（覆盖正常重启场景）
#   ② 慢等：再 180 次 × 20s = 60 分钟（覆盖用户手动创建存储空间场景）
#      一旦挂上就退出，不占 CPU（每次只 sleep）
mkdir -p /vol1
chmod 755 /vol1 2>/dev/null

_do_mount() {
    /sbin/vgchange -ay >/dev/null 2>&1
    for lv in /dev/mapper/trim_*-0; do
        [ -e "$lv" ] || continue
        if mount "$lv" /vol1 2>/dev/null; then
            echo "[trim-vol1-heal] mounted $lv"
            return 0
        fi
    done
    return 1
}

# ① 快等 60 秒
i=0
while [ "$i" -lt 20 ]; do
    mountpoint -q /vol1 && break
    _do_mount && break
    i=$((i + 1))
    sleep 3
done

# ② 慢等 60 分钟（用户手动创建存储空间时，LV 可能几分钟后才出现）
if ! mountpoint -q /vol1; then
    echo "[trim-vol1-heal] 快等结束未挂载，转入慢等（最多 60 分钟）"
    j=0
    while [ "$j" -lt 180 ]; do
        mountpoint -q /vol1 && break
        _do_mount && break
        j=$((j + 1))
        sleep 20
    done
fi

if mountpoint -q /vol1; then
    for d in @appcenter @appconf @appdata @apphome @appmeta @appshare @apptemp; do
        mkdir -p "/vol1/$d" 2>/dev/null
    done
    echo "[trim-vol1-heal] /vol1 ready"
else
    echo "[trim-vol1-heal] 仍未挂载（LV 可能还不存在，等待用户创建存储空间）"
fi

exit 0
HEALSH_EOF
chmod 755 "$MNT/usr/local/sbin/trim-vol1-heal.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-vol1-heal.service" <<'HEALSVC_EOF'
[Unit]
Description=Ensure /vol1 is mounted (activate LVM + mount existing btrfs LV)
After=local-fs.target trim_main.service
Wants=trim_main.service
ConditionPathIsReadWrite=/

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/trim-vol1-heal.sh
# 慢等 180 次 x 20s = 3600 秒，加上快等 60 秒，必须给足 3700 秒，
# 否则 systemd 会在 120 秒时强杀脚本，慢等根本跑不到。
TimeoutStartSec=3700

[Install]
WantedBy=multi-user.target
HEALSVC_EOF
ln -sf ../trim-vol1-heal.service "$MNT/etc/systemd/system/multi-user.target.wants/trim-vol1-heal.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-vol1-heal（独立脚本版）"

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
ln -sf /usr/local/sbin/reboot-loader.sh "$MNT/usr/local/sbin/reboot-loader" 2>/dev/null || true
echo "[fix_rootfs] 已装 reboot-loader（一键进 Loader）"


# ==========================================================================
# ⑳ p5 分区自愈（2026-11-26）
#
# 问题实测：
#   每次用 RKDevTool 刷机，整盘写入后 /dev/mmcblk0p5 会消失。
#   刷机镜像只含 p1(uboot) / p2(recovery) / p3(boot) / p4(rootfs)，
#   后面 27.9GB 变成未分区空间。
#   结果：网页上"创建存储空间"卡在最后一步（因为没有 p5 可选）。
#
# 本服务只做一件事：p5 不存在时，从 p4 末尾到磁盘末尾重建分区，
# 并设置 raid 标记（fnOS 要求）。
#
# 绝不格式化，绝不建 mdadm/LVM，绝不碰已有数据。
# ==========================================================================
cat > "$MNT/usr/local/sbin/trim-p5-heal.sh" <<'P5EOF'
#!/bin/bash
# p5 分区自愈：不存在时重建（保留已有分区和数据）
DEV=/dev/mmcblk0
PART=5

# 已有 p5 就退出
if [ -b "${DEV}p${PART}" ]; then
    echo "[trim-p5-heal] ${DEV}p${PART} exists, nothing to do"
    exit 0
fi

# 检查磁盘和 parted
[ -b "$DEV" ] || { echo "[trim-p5-heal] $DEV not found"; exit 0; }
command -v parted >/dev/null 2>&1 || { echo "[trim-p5-heal] parted not found"; exit 0; }

# p4 必须存在
if [ ! -b "${DEV}p4" ]; then
    echo "[trim-p5-heal] ${DEV}p4 missing, skip"
    exit 0
fi

# 取 p4 结束位置（MiB）
P4_END=$(parted "$DEV" unit MiB print 2>/dev/null | awk '$1=="4"{gsub("MiB","",$3); print $3}')
if [ -z "$P4_END" ]; then
    echo "[trim-p5-heal] cannot read p4 end"
    exit 0
fi

# 磁盘总大小（MiB）
DISK_MB=$(parted "$DEV" unit MiB print 2>/dev/null | awk '/^Disk \/dev/{gsub("MiB","",$3); print $3}')
if [ -z "$DISK_MB" ]; then
    DISK_MB=59640
fi

# 剩余空间小于 1GB 就不建
REMAIN=$((DISK_MB - P4_END))
if [ "$REMAIN" -lt 1024 ]; then
    echo "[trim-p5-heal] only ${REMAIN}MiB left after p4, skip"
    exit 0
fi

echo "[trim-p5-heal] p4 ends at ${P4_END}MiB, disk ${DISK_MB}MiB, creating p${PART}"

# 消除可能存在的分区表备份（刷机后常有 GPT backup 在磁盘末尾）
sgdisk --move-second-header "$DEV" >/dev/null 2>&1 || true

parted -s "$DEV" unit MiB mkpart primary "${P4_END}" 100% 2>&1
sleep 2
partprobe "$DEV" 2>/dev/null
sleep 2

# 设置 raid 标记（fnOS 建存储池需要）
parted -s "$DEV" set "$PART" raid on 2>&1

sleep 1
if [ -b "${DEV}p${PART}" ]; then
    echo "[trim-p5-heal] ${DEV}p${PART} created: $(blockdev --getsize64 ${DEV}p${PART} 2>/dev/null) bytes"
else
    echo "[trim-p5-heal] FAILED to create ${DEV}p${PART}"
fi

exit 0
P5EOF
chmod 755 "$MNT/usr/local/sbin/trim-p5-heal.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-p5-heal.service" <<'P5SVCEOF'
[Unit]
Description=Re-create missing p5 partition (survives full-disk flash)
After=local-fs.target
Before=trim_main.service trim-vol1-heal.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/trim-p5-heal.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
P5SVCEOF
ln -sf ../trim-p5-heal.service "$MNT/etc/systemd/system/multi-user.target.wants/trim-p5-heal.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-p5-heal（p5 分区丢失时自动重建）"


# ==========================================================================
# ㉑ NPU 用户态运行时（librknnrt + rknn_server）
#
# 背景：
#   内核有 RKNPU 驱动（CONFIG_ROCKCHIP_RKNPU=y），但没有 librknnrt.so，
#   跑不了任何 RKNN 模型。
#   板子实测：
#     RKNPU fdab0000.npu: [drm] Initialized rknpu 0.9.8
#     devfreq 1GHz，8 档
#     但 find / -iname '*rknn*' 为空
#
# 影响评估（不影响飞牛）：
#   纯新增文件，飞牛不用 NPU 就不受影响。
#   /usr/lib/librknnrt.so 和 /usr/bin/rknn_server 都是新文件。
#
# 注意：
#   rknnlite 要求库在 /usr/lib/ 而不是 /usr/lib/aarch64-linux-gnu/
#   （板子实测：放错位置报 "Can not find dynamic library on RK3588!"）
# ==========================================================================
cat > "$MNT/usr/local/sbin/trim-npu-install.sh" <<'NPUEOF'
#!/bin/bash
# 安装 RKNN 用户态运行时（首次启动时联网下载，失败不阻塞）
set +e

MARK=/var/lib/trim-npu-installed
[ -f "$MARK" ] && exit 0

LIB=/usr/lib/librknnrt.so
SRV=/usr/bin/rknn_server

# 已经有就跳过
if [ -f "$LIB" ] && [ -f "$SRV" ]; then
    touch "$MARK"
    exit 0
fi

# 等网络就绪（最多 60 秒）
i=0
while [ $i -lt 30 ]; do
    if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then break; fi
    i=$((i+1))
    sleep 2
done

BASE="https://raw.githubusercontent.com/airockchip/rknn-toolkit2/master/rknpu2/runtime/Linux"

if [ ! -f "$LIB" ]; then
    # 只放到 /usr/lib/，rknnlite 只认这个路径
    wget -q -O /tmp/librknnrt.so.$$ "$BASE/librknn_api/aarch64/librknnrt.so" 2>/dev/null
    if [ -s /tmp/librknnrt.so.$$ ] && [ "$(stat -c%s /tmp/librknnrt.so.$$)" -gt 1000000 ]; then
        install -m755 /tmp/librknnrt.so.$$ "$LIB"
        echo "[trim-npu] librknnrt.so 已安装: $(stat -c%s $LIB) 字节"
    else
        echo "[trim-npu] librknnrt.so 下载失败"
    fi
    rm -f /tmp/librknnrt.so.$$
fi

if [ ! -f "$SRV" ]; then
    wget -q -O /tmp/rknn_server.$$ "$BASE/rknn_server/aarch64/usr/bin/rknn_server" 2>/dev/null
    if [ -s /tmp/rknn_server.$$ ] && [ "$(stat -c%s /tmp/rknn_server.$$)" -gt 100000 ]; then
        install -m755 /tmp/rknn_server.$$ "$SRV"
        echo "[trim-npu] rknn_server 已安装"
    else
        echo "[trim-npu] rknn_server 下载失败"
    fi
    rm -f /tmp/rknn_server.$$
fi

if [ -f "$LIB" ] && [ -f "$SRV" ]; then
    ldconfig 2>/dev/null
    touch "$MARK"
    echo "[trim-npu] 安装完成"
fi
exit 0
NPUEOF
chmod 755 "$MNT/usr/local/sbin/trim-npu-install.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-npu-runtime.service" <<'NPUSVCEOF'
[Unit]
Description=Install RKNN userspace runtime (librknnrt + rknn_server)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/trim-npu-installed

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/trim-npu-install.sh
TimeoutStartSec=180
StandardOutput=journal

[Install]
WantedBy=multi-user.target
NPUSVCEOF
ln -sf ../trim-npu-runtime.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-npu-runtime.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-npu-runtime（首次启动联网装 librknnrt + rknn_server）"

# rknn_server 自启服务（供 PC 上的 rknn-toolkit2 远程调试用）
# 板子上直接跑推理不需要它，但装上不影响，需要时直接可用
cat > "$MNT/etc/systemd/system/trim-rknn-server.service" <<'RKSRVEOF'
[Unit]
Description=Rockchip RKNN remote server (for rknn-toolkit2 debug from PC)
After=trim-npu-runtime.service
Wants=trim-npu-runtime.service
ConditionPathExists=/usr/bin/rknn_server

[Service]
Type=simple
ExecStart=/usr/bin/rknn_server
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
RKSRVEOF
ln -sf ../trim-rknn-server.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-rknn-server.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-rknn-server（rknn_server 自启，可选）"


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
        route-metric: 600
      optional: true
    usb0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 50
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
	option metric '600'

config interface 'kdusb0'
	option proto 'dhcp'
	option device 'usb0'
	option metric '100'
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
#       对所有系统生效（纯 ip 命令，不依赖网络栈）。
# ==========================================================================
cat > "$MNT/usr/local/sbin/trim-eth-retry.sh" <<'ETHRETRYEOF'
#!/bin/bash
# eth0 重试：只在确实没链路时才动，避免干扰飞牛
#
# 2026-11-26 改：
#   原版无条件 down/up，会影响飞牛创建存储空间（需要网络稳定）
#   现在：carrier=1 直接退出；只有 carrier=0 才尝试 up（不 down）

DEV=eth0

[ -d /sys/class/net/$DEV ] || exit 0

carrier=$(cat /sys/class/net/$DEV/carrier 2>/dev/null || echo 0)
state=$(cat /sys/class/net/$DEV/operstate 2>/dev/null || echo unknown)

if [ "$carrier" = "1" ]; then
    echo "[trim-eth-retry] $DEV 已连通 (state=$state carrier=$carrier)，无需操作"
    exit 0
fi

echo "[trim-eth-retry] $DEV 无链路 (state=$state carrier=$carrier)，尝试拉起"

ok=0
for i in 1 2 3; do
    carrier=$(cat /sys/class/net/$DEV/carrier 2>/dev/null || echo 0)
    if [ "$carrier" = "1" ]; then
        echo "[trim-eth-retry] 第 $i 次检查：已连通"
        ok=1
        break
    fi
    echo "[trim-eth-retry] 第 $i 次尝试：up $DEV（不 down，避免打断网络）"
    ip link set "$DEV" up 2>/dev/null
    sleep 8
done

if [ "$ok" = "0" ]; then
    carrier=$(cat /sys/class/net/$DEV/carrier 2>/dev/null || echo 0)
    state=$(cat /sys/class/net/$DEV/operstate 2>/dev/null || echo unknown)
    if [ "$carrier" = "1" ]; then
        echo "[trim-eth-retry] 最终已连通 (state=$state carrier=$carrier)"
    else
        echo "[trim-eth-retry] 重试 5 次仍未连通 (state=$state carrier=$carrier)"
    fi
fi

# 顺便检查其他网口
for d in usb0 wlan0; do
    [ -d /sys/class/net/$d ] || continue
    cs=$(cat /sys/class/net/$d/carrier 2>/dev/null || echo -)
    st=$(cat /sys/class/net/$d/operstate 2>/dev/null || echo -)
    echo "[trim-eth-retry] $d: state=$st carrier=$cs"
done

exit 0
ETHRETRYEOF
chmod 755 "$MNT/usr/local/sbin/trim-eth-retry.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-eth-retry.service" <<'ETHRETRYSVCEOF'
[Unit]
Description=Retry bringing up eth0 only if carrier is down
# 2026-11-26：不要用 After=network.target 抢在飞牛前面动网络。
# 飞牛 trim_main 创建存储空间时需要网络稳定，
# 这里改成最后才跑，且只在 carrier=0 时才动。
After=trim_main.service multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 等飞牛启动完（trim_main 会跑 30-60 秒）
ExecStartPre=/bin/sleep 90
ExecStart=/usr/local/sbin/trim-eth-retry.sh
TimeoutStartSec=200

[Install]
WantedBy=multi-user.target
ETHRETRYSVCEOF
ln -sf ../trim-eth-retry.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-eth-retry.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-eth-retry（eth0 自动重试，修复 GMAC DMA 首次失败）"


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

echo "[fix_rootfs] 全部完成"
exit 0
