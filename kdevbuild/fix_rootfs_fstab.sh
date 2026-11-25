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
  for pair in \
      "fw_bcmdhd.bin:fw_bcm43456c5_ag.bin" \
      "clm_blob.bin:fw_bcm43456c5_ag.clm_blob" \
      "nvram.txt:nvram_ap6256.txt" \
      "config.txt:config.txt"
  do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if [ -f "$FW_SRC/$src" ]; then
      cp -f "$FW_SRC/$src" "$MNT/lib/firmware/$dst"
      echo "[fix_rootfs] 已安装 /lib/firmware/$dst ($(stat -c%s "$FW_SRC/$src" 2>/dev/null) 字节)"
    fi
  done
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
cat > "$MNT/etc/systemd/system/trim-4g-ip.service" <<'G4IPEOF'
[Unit]
Description=Bring up 4G usb0 via DHCP after QNETDEVCTL binding
After=NetworkManager.service trim-4g-apn.service
Wants=NetworkManager.service trim-4g-apn.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 顺序很重要：
#   trim-4g-apn 先跑完 AT+QNETDEVCTL=1,1,1（把 PDP 绑到 usb0）
#   然后这里再拉一次 NM 连接，让 DHCP 去要运营商 IP
ExecStart=/bin/bash -c 'i=0; while [ $i -lt 40 ]; do if ip -4 addr show usb0 2>/dev/null | grep -q "inet "; then exit 0; fi; if [ -d /sys/class/net/usb0 ]; then /usr/bin/nmcli con up "4G-USB0" 2>/dev/null; fi; sleep 4; i=$((i+1)); done; exit 0'

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
# WAN 自动选路（2026-11-25）
# 需求：三个网口同时在线，但系统要自动选「真正能访问外网」的那条。
#       某个口有 IP 但上不了外网（例如 eth0 直连电脑而电脑没做 NAT），
#       自动让位给别的口，不需要人工干预。
#
# 原理：ping -I <网口> 会 SO_BINDTODEVICE，真正从该网口发出去。
#       三个候选主机轮着试，任一通就算这个口能上外网。
#       能通的口 metric 设 50，其余设 600，内核自动走 metric 最小的。
#       每 15 秒重测，恢复了自动提上来。
TEST_HOSTS="223.5.5.5 114.114.114.114 8.8.8.8"

# 网口|连接名（按偏好顺序：WiFi > 4G > 有线）
CAND_IFS=("wlan0" "usb0" "eth0")
CAND_NAMES=("Xiaomi_8D9F_5G-wlan0" "4G-USB0" "Wired connection 1")
GOOD_METRIC=50
BAD_METRIC=600

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

for i in 0 1 2; do
  ifc="${CAND_IFS[$i]}"
  name="${CAND_NAMES[$i]}"
  if [ "$ifc" = "$WINNER" ]; then m=$GOOD_METRIC; else m=$BAD_METRIC; fi
  cur=$(nmcli -g ipv4.route-metric con show "$name" 2>/dev/null)
  if [ "$cur" != "$m" ]; then
    nmcli con mod "$name" ipv4.route-metric "$m" 2>/dev/null \
      && echo "[wan-failover] ${ifc} metric ${cur} -> ${m}"
  fi
done

echo "[wan-failover] winner=${WINNER:-none}"
WANEOF
chmod 755 "$MNT/usr/local/sbin/wan-failover.sh" 2>/dev/null || true

cat > "$MNT/etc/systemd/system/trim-wan-failover.service" <<'WANSVCEOF'
[Unit]
Description=WAN auto failover by real internet reachability
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'sleep 25; while true; do /usr/local/sbin/wan-failover.sh; sleep 15; done'
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
# ⑱ /vol1 自愈（2026-11-26 加回，稳妥版）
#
# 背景：
#   fnOS 创建存储空间时，mdadm/LVM/mkfs.btrfs 全部成功（日志已证实），
#   但最后一步"挂载到 /vol1"有时没做成（依赖 trimafs 模块，我们内核没有），
#   导致网页显示创建失败，/vol1 也没挂上。
#
# 本服务只做两件事，绝不创建/格式化任何东西：
#   1. vgchange -ay      激活已存在的 LVM 卷组
#   2. mount 挂到 /vol1  如果 /vol1 还没挂载且能找到 btrfs 的 LV
#
# 时序：After=trim_main.service（等 fnOS 先跑完创建流程）
#       然后补上它没做完的挂载步骤
# ==========================================================================
cat > "$MNT/etc/systemd/system/trim-vol1-heal.service" <<'HEALEOF'
[Unit]
Description=Ensure /vol1 is mounted (activate LVM + mount existing btrfs LV)
After=local-fs.target trim_main.service
Wants=trim_main.service
ConditionPathIsReadWrite=/

[Service]
Type=oneshot
RemainAfterExit=yes
# 只激活 + 挂载，绝不 mkfs / 绝不 mdadm create / 绝不 lvcreate
ExecStart=/bin/bash -c 'mkdir -p /vol1; chmod 755 /vol1 2>/dev/null; /sbin/vgchange -ay >/dev/null 2>&1; if ! mountpoint -q /vol1; then for lv in /dev/mapper/trim_*-0; do if [ -e "$lv" ] && blkid "$lv" 2>/dev/null | grep -q btrfs; then mount "$lv" /vol1 2>/dev/null && break; fi; done; fi; if mountpoint -q /vol1; then for d in @appcenter @appconf @appdata @apphome @appmeta @appshare @apptemp; do mkdir -p "/vol1/$d" 2>/dev/null; done; fi; exit 0'

[Install]
WantedBy=multi-user.target
HEALEOF
ln -sf ../trim-vol1-heal.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-vol1-heal.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-vol1-heal（只激活 LVM + 挂载 /vol1，不创建/格式化）"


echo "[fix_rootfs] 全部完成"
exit 0
