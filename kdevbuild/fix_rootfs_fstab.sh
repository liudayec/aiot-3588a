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
      "nvram.txt:nvram_ap6256.txt"
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

echo "[fix_rootfs] 全部完成"
exit 0
