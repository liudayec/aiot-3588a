#!/bin/bash
# ==========================================================================
# fix_rootfs_fstab.sh —— 在构建流程里修正 rootfs 的 /etc/fstab
#
# 用法（在 kdevbuild/*_image.sh 里，紧跟在 mount rootfs.img /mnt 之后调用）：
#     bash "$(cd "$(dirname "$0")" && pwd)/fix_rootfs_fstab.sh" /mnt || true
#
# 修四件事：
#   ① 去掉 btrfs 不认的 errors=remount-ro（否则内核/系统日志一直报错）
#   ② /boot 统一改成 LABEL=kdevboot（boot.img 由 mkfs.ext2 -L kdevboot 生成，最稳，
#      不用管 UUID 对不对——这正是 FNOS 版刷完卡 "Give root password for maintenance" 的根因）
#   ③ 根分区加 x-systemd.growfs → 首次开机自动把根扩到整块 eMMC（58GB）
#   ④ 删掉 /boot/efi 等指向 parameter.txt 里并不存在的分区的挂载行
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

# ④ 删掉不存在的 /boot/efi 挂载（parameter.txt 只有 uboot/recovery/boot/rootfs 四个分区）
sed -i '\#[[:space:]]/boot/efi[[:space:]]#d' "$F"

# ②③ 用 awk 精确改 / 和 /boot 两行（保留其它行原样）
awk 'BEGIN { OFS="\t" }
{
  if ($2 == "/") {
      # 根：确保有 x-systemd.growfs，去掉 btrfs 不认的选项
      gsub(/,?errors=remount-ro/, "", $4)
      if ($4 !~ /x-systemd\.growfs/) {
          if ($4 == "" || $4 == "defaults") { $4 = $4 ",x-systemd.growfs" }
          else { $4 = $4 ",x-systemd.growfs" }
      }
      gsub(/^,/, "", $4)
      print
  } else if ($2 == "/boot") {
      # /boot：改用 LABEL，与 boot.img 的 mkfs -L kdevboot 对齐
      print "LABEL=kdevboot", "/boot", "ext4", "defaults,noatime", "0", "2"
  } else {
      print
  }
}' "$F" > "$F.new" && mv "$F.new" "$F"

echo "--- 修改后 ---"
cat "$F"
echo "（原文件备份在 ${F}.orig）"
echo "=========================================================="

# ============================================================

# ============================================================
# 追加：预建 /vol1 + 安装 btrfs 根分区自动扩容服务
# ============================================================

# 5) 预建 /vol1 —— fnOS 存储池的挂载点
#    不建的话，fnOS 创建存储空间会在 mount 阶段失败，
#    并在数据库 mount 表里留下残留记录，导致之后每次重试都撞主键冲突
mkdir -p "$MNT/vol1" 2>/dev/null || true
chmod 755 "$MNT/vol1" 2>/dev/null || true
echo "[fix_rootfs] 已预建 /vol1"

# 6) 安装 btrfs 根分区自动扩容服务
#    systemd-growfs@-.service 在 root=PARTUUID 启动时会报 pseudo-device /dev/root 失败
mkdir -p "$MNT/etc/systemd/system/sysinit.target.wants" 2>/dev/null || true
cat > "$MNT/etc/systemd/system/btrfs-growroot.service" <<'SVCEOF'
[Unit]
Description=Grow btrfs root filesystem to fill its partition
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target shutdown.target
ConditionPathIsMountPoint=/

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for g in 513 515 517 519 520; do if [ ! -d /sys/class/gpio/gpio$g ]; then echo $g > /sys/class/gpio/export 2>/dev/null; sleep 0.1; fi; if [ -d /sys/class/gpio/gpio$g ]; then echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null; fi; done; echo 0 > /sys/class/gpio/gpio517/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio515/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio520/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio513/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio519/value 2>/dev/null; sleep 1.5; echo 1 > /sys/class/gpio/gpio517/value 2>/dev/null; sleep 1.0; echo 0 > /sys/class/gpio/gpio515/value 2>/dev/null; exit 0'

[Install]
WantedBy=multi-user.target
HEALEOF
mkdir -p "$MNT/etc/systemd/system/local-fs.target.wants" 2>/dev/null || true
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" 2>/dev/null || true
ln -sf ../trim-vol1-heal.service "$MNT/etc/systemd/system/multi-user.target.wants/trim-vol1-heal.service" 2>/dev/null || true
echo "[fix_rootfs] 已安装 trim-vol1-heal.service"



# 8) 安装 WiFi 固件（bcmdhd 驱动从 /vendor/etc/firmware/ 读，缺了 WiFi 就起不来）
FW_SRC="$(cd "$(dirname "$0")" && pwd)/firmware"
if [ -d "$FW_SRC" ]; then
  mkdir -p "$MNT/vendor/etc/firmware"
  for f in fw_bcmdhd.bin nvram.txt; do
    if [ -f "$FW_SRC/$f" ]; then
      cp -f "$FW_SRC/$f" "$MNT/vendor/etc/firmware/$f"
      echo "[fix_rootfs] 已安装 $f"
    fi
  done
  chmod 644 "$MNT/vendor/etc/firmware/"* 2>/dev/null || true
else
  echo "[fix_rootfs] 警告: 找不到 $FW_SRC，跳过 WiFi 固件"
fi



# 9) 安装 4G 模块电源服务
#    板子 EC200A-CN（Mini-PCIe）的电源/复位/使能挂在 NCA9555(pca9555) 上：
#      pin 5 = 4g_power    (高 = 上电)
#      pin 3 = 4g_reset    (GPIO_ACTIVE_LOW！逻辑高=物理低，物理低=不复位)
#      pin 8 = 4g_disable  (高 = 不禁用)
#      pin 1 = usb2_power  (高 = USB2 供电)
#    Android 用 smdt,smdtio 驱动初始化这些脚，Linux 侧没有，必须自己设。
cat > "$MNT/etc/systemd/system/trim-4g-power.service" <<'G4EOF'
[Unit]
Description=Power on 4G module (NCA9555 pins 1/3/5/8)
After=local-fs.target
ConditionPathExists=/sys/class/gpio

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '# 1) 导出并设为输出
for g in 513 515 517 519 520; do if [ ! -d /sys/class/gpio/gpio$g ]; then echo $g > /sys/class/gpio/export 2>/dev/null; sleep 0.1; fi; if [ -d /sys/class/gpio/gpio$g ]; then echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null; fi; done; # 2) 4G 断电：power=0, reset 有效(物理高, ACTIVE_LOW), disable=高
echo 0 > /sys/class/gpio/gpio517/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio515/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio520/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio513/value 2>/dev/null; echo 1 > /sys/class/gpio/gpio519/value 2>/dev/null; sleep 1.5; # 3) 4G 上电
echo 1 > /sys/class/gpio/gpio517/value 2>/dev/null; sleep 1.0; # 4) 释放复位（ACTIVE_LOW → 物理低）
echo 0 > /sys/class/gpio/gpio515/value 2>/dev/null; exit 0'

[Install]
WantedBy=multi-user.target
G4EOF
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" 2>/dev/null || true
ln -sf ../trim-4g-power.service "$MNT/etc/systemd/system/multi-user.target.wants/trim-4g-power.service" 2>/dev/null || true
echo "[fix_rootfs] 已安装 trim-4g-power.service"


exit 0
