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
#   ⑥ trim-vol1-heal.service —— /vol1 自愈（After=trim_main，否则被清掉）
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
mkdir -p "$MNT/vol1" 2>/dev/null || true
chmod 755 "$MNT/vol1" 2>/dev/null || true
echo "[fix_rootfs] 已预建 /vol1"

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
# ⑦ trim-vol1-heal.service —— /vol1 自愈
#    时序：After=trim_main（在 fnOS 启动之后再执行，否则 /vol1 会被它清掉）
# ==========================================================================
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" 2>/dev/null || true
cat > "$MNT/etc/systemd/system/trim-vol1-heal.service" <<'HEALEOF'
[Unit]
Description=Ensure /vol1 exists and storage pool is mounted
After=local-fs.target trim_main.service
Wants=trim_main.service
ConditionPathIsReadWrite=/

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'mkdir -p /vol1; chmod 755 /vol1; vgchange -ay >/dev/null 2>&1; if ! mountpoint -q /vol1; then for lv in /dev/mapper/trim_*-0; do if [ -e "$lv" ] && blkid "$lv" >/dev/null 2>&1; then mount "$lv" /vol1 2>/dev/null && break; fi; done; fi; exit 0'

[Install]
WantedBy=multi-user.target
HEALEOF
ln -sf ../trim-vol1-heal.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-vol1-heal.service" 2>/dev/null || true
echo "[fix_rootfs] 已安装 trim-vol1-heal.service"

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
Description=Power on 4G module (PCA9555, with power cycle)
After=local-fs.target
ConditionPathExists=/sys/class/gpio

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for g in 513 515 517 519 520; do if [ ! -d /sys/class/gpio/gpio$g ]; then echo $g > /sys/class/gpio/export 2>/dev/null; sleep 0.1; fi; if [ -d /sys/class/gpio/gpio$g ]; then echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null; fi; done; echo 1 > /sys/class/gpio/gpio513/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio519/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio520/value 2>/dev/null; echo 0 > /sys/class/gpio/gpio517/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio515/value 2>/dev/null; sleep 1.5; echo 1 > /sys/class/gpio/gpio517/value 2>/dev/null; sleep 1.0; echo 0 > /sys/class/gpio/gpio515/value 2>/dev/null; exit 0'

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
Description=WiFi guard: disable bcmdhd if wlan0 cannot come up
After=local-fs.target trim_main.service network_service.service
Wants=trim_main.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 给 WiFi 60 秒尝试时间
ExecStartPre=/bin/sleep 60
ExecStart=/bin/bash -c 'if [ -d /sys/class/net/wlan0 ]; then st=$(cat /sys/class/net/wlan0/operstate 2>/dev/null); if [ "$st" = "up" ]; then echo "[wifi-guard] wlan0 正常 (up)，不干预"; else echo "[wifi-guard] wlan0 状态=$st，判定 WiFi 不可用，自动屏蔽 bcmdhd"; printf "install bcmdhd /bin/false\nblacklist bcmdhd\n" > /etc/modprobe.d/blacklist-bcmdhd.conf; ip link set wlan0 down 2>/dev/null; /sbin/rmmod bcmdhd 2>/dev/null; fi; else echo "[wifi-guard] 无 wlan0 设备，不干预"; fi; exit 0'

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
Description=Configure 4G usb0 static IP (EC200A ECM has no DHCP server)
After=NetworkManager.service trim-4g-power.service
Wants=NetworkManager.service trim-4g-power.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for i in $(seq 1 30); do if [ -d /sys/class/net/usb0 ]; then /usr/bin/nmcli con up "4G-USB0" 2>/dev/null && exit 0; fi; sleep 2; done; if [ -d /sys/class/net/usb0 ]; then ip addr add 192.168.225.2/24 dev usb0 2>/dev/null; ip link set usb0 up; ip route replace default via 192.168.225.1 dev usb0 metric 700 2>/dev/null; fi; exit 0'

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

[ethernet]
cloned-mac-address=permanent

[ipv4]
method=manual
address1=192.168.225.2/24,192.168.225.1
dns=114.114.114.114;223.5.5.5;
dns-search=
may-fail=false

[ipv6]
method=ignore
G4CONEOF
chmod 600 "$MNT/etc/NetworkManager/system-connections/4G-USB0.nmconnection" 2>/dev/null || true
echo "[fix_rootfs] 已预置 4G-USB0 连接（静态 192.168.225.2/24）"

# --- ⑥ nca9555 全部 GPIO 兜底（DTB hog 之外的保险）---
cat > "$MNT/etc/systemd/system/trim-nca9555-all.service" <<'NCAEOF'
[Unit]
Description=Set all nca9555 GPIOs per Android smdtio defaults (fallback for DTB hog)
After=local-fs.target
ConditionPathExists=/sys/class/gpio

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for p in 0 1 4 5 6 7 8 9 10 11 12 14; do g=$((512+p)); if [ ! -d /sys/class/gpio/gpio$g ]; then echo $g > /sys/class/gpio/export 2>/dev/null; sleep 0.1; fi; if [ -d /sys/class/gpio/gpio$g ]; then echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null; echo 1 > /sys/class/gpio/gpio$g/value 2>/dev/null; fi; done; if [ -d /sys/class/gpio/gpio515 ]; then echo out > /sys/class/gpio/gpio515/direction 2>/dev/null; echo 0 > /sys/class/gpio/gpio515/value 2>/dev/null; fi; exit 0'

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
cat > "$MNT/etc/systemd/system/trim-network-route.service" <<'ROUTEEOF'
[Unit]
Description=Set route metrics: WiFi primary, eth0 secondary, 4G last
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'i=0; while [ $i -lt 20 ]; do if /usr/bin/nmcli -t -f NAME con show 2>/dev/null | grep -q .; then break; fi; sleep 2; i=$((i+1)); done; for n in $(/usr/bin/nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: "$2==\"802-11-wireless\"{print $1}"); do /usr/bin/nmcli con mod "$n" ipv4.route-metric 50 2>/dev/null; done; for n in $(/usr/bin/nmcli -t -f NAME,DEVICE con show 2>/dev/null | awk -F: "$2==\"eth0\"{print $1}"); do /usr/bin/nmcli con mod "$n" ipv4.route-metric 200 2>/dev/null; done; /usr/bin/nmcli con mod "4G-USB0" ipv4.route-metric 300 2>/dev/null; exit 0'

[Install]
WantedBy=multi-user.target
ROUTEEOF
ln -sf ../trim-network-route.service \
  "$MNT/etc/systemd/system/multi-user.target.wants/trim-network-route.service" 2>/dev/null || true
echo "[fix_rootfs] 已装 trim-network-route.service（WiFi 主路由）"

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


echo "[fix_rootfs] 全部完成"
exit 0
