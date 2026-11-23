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
# 追加：预建 /vol1 + 安装 btrfs 根分区自动扩容服务
# ============================================================
# 5) 预建 /vol1：fnOS 存储池挂载点
#    不建的话，创建存储空间会在 mount 阶段失败，
#    并在 fnOS 的 mount 表里留下残留记录，导致之后每次重试都撞主键冲突
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
ExecStart=/bin/bash -c 'exec 1>/dev/console 2>&1; btrfs filesystem resize max / || true'

[Install]
WantedBy=sysinit.target
SVCEOF
ln -sf ../btrfs-growroot.service "$MNT/etc/systemd/system/sysinit.target.wants/btrfs-growroot.service" 2>/dev/null || true
echo "[fix_rootfs] 已安装 btrfs-growroot.service"

exit 0
