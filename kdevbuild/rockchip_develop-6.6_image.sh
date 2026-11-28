#!/bin/bash

set -xe

WORKDIR=$(pwd)
BOARD_NAME="AIoT-3588A"
KERNEL_RELEASE="6.6.89-kdev"
DTB_NAME="rk3588-aiot-3588a.dtb"
BUILD_TAG="${BOARD_NAME}_${KERNEL_RELEASE}_${set_rootfs}"
SPL_LOADER="rk3588_spl_loader_v1.21.114.bin"
UBOOT_URL="https://github.com/yifengyou/rockchip-uboot-mainline/releases/download/aiot-3588a-uboot"
KERNEL_URL="https://github.com/liudayec/rockchip-kernel/releases/download/aiot-3588a_develop-6.6-md"
RECOVERY_URL="https://github.com/yifengyou/rockchip-ophub-linux-6.18.y/releases/download/aiot-3588a-recovery"
ROOTFS_BASE_URL="https://github.com/yifengyou/kdev/releases/download"

ROOT_PARTUUID="614e0000-0000-4b53-8000-1d28000054a9"


#==========================================================================#
#                        init build env                                    #
#==========================================================================#
export DEBIAN_FRONTEND=noninteractive
export TZ=Asia/Shanghai

apt-get update
apt-get install -qq -y ca-certificates
apt-get install -qq -y --no-install-recommends \
  acl aptly aria2 axel bc binfmt-support binutils-aarch64-linux-gnu bison \
  bsdextrautils btrfs-progs build-essential busybox ca-certificates ccache \
  clang coreutils cpio crossbuild-essential-arm64 cryptsetup curl \
  debian-archive-keyring debian-keyring debootstrap device-tree-compiler \
  dialog dirmngr distcc dosfstools dwarves e2fsprogs expect f2fs-tools \
  fakeroot fdisk file flex gawk gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
  gdisk git gnupg gzip htop imagemagick jq kmod lib32ncurses-dev \
  lib32stdc++6 libbison-dev libc6-dev-armhf-cross libc6-i386 libcrypto++-dev \
  libelf-dev libfdt-dev libfile-fcntllock-perl libfl-dev libfuse-dev \
  libgcc-12-dev-arm64-cross libgmp3-dev liblz4-tool libmpc-dev libncurses-dev \
  libncurses5 libncurses5-dev libncursesw5-dev libpython2.7-dev \
  libpython3-dev libssl-dev libusb-1.0-0-dev linux-base lld llvm locales \
  lsb-release lz4 lzma lzop make mtools ncurses-base ncurses-term \
  nfs-kernel-server ntpdate openssl p7zip p7zip-full parallel parted patch \
  patchutils pbzip2 pigz pixz pkg-config pv python2 python2-dev python3 \
  python3-dev python3-distutils python3-pip python3-setuptools \
  python-is-python3 qemu-user-static rar rdfind rename rsync sed \
  squashfs-tools swig tar tree u-boot-tools udev unzip util-linux uuid \
  uuid-dev uuid-runtime vim wget whiptail xfsprogs xsltproc xxd xz-utils \
  zip zlib1g-dev zstd binwalk ripgrep sudo
localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 || true
mkdir -p ${WORKDIR}/rockdev
mkdir -p ${WORKDIR}/release
mkdir -p /dev

#==========================================================================#
# Task: Build Root Filesystem (rootfs) using Armbian Build System          #
#==========================================================================#
mkdir -p ${WORKDIR}/rootfs
cd ${WORKDIR}/rootfs/

if [ -z "${set_vendor}" ] || [ -z "${set_rootfs}" ]; then
  echo "skip rootfs build"
else
  echo "ROOTFS:${set_rootfs}"
  ROOTFS_URL="${ROOTFS_BASE_URL}/${set_vendor}-rootfs/${set_rootfs}"
  echo "ROOTFS_URL:${ROOTFS_URL}"

  aria2c --check-certificate=false \
    --max-connection-per-server=16 \
    --split=16 \
    --human-readable=true \
    --summary-interval=5 \
    -o ${set_rootfs} \
    "${ROOTFS_URL}"

  ls -alh
  rar x ${set_rootfs}
  ls -alh
  mv rootfs.img ${WORKDIR}/rockdev/rootfs.img
  ls -alh ${WORKDIR}/rockdev
fi

ls -alh ${WORKDIR}/rockdev/rootfs.img

#==========================================================================#
#                        build uboot                                       #
#==========================================================================#
cd ${WORKDIR}

mkdir -p ophub_${KERNEL_RELEASE}
cd ophub_${KERNEL_RELEASE}

wget -c ${UBOOT_URL}/uboot.img
ls -alh uboot.img
mv uboot.img ${WORKDIR}/rockdev/uboot.img
ls -alh ${WORKDIR}/rockdev/uboot.img
md5sum ${WORKDIR}/rockdev/uboot.img

wget -c ${UBOOT_URL}/${SPL_LOADER}
ls -alh ${SPL_LOADER}
mv ${SPL_LOADER} ${WORKDIR}/rockdev/${SPL_LOADER}
ls -alh ${WORKDIR}/rockdev/${SPL_LOADER}
md5sum ${WORKDIR}/rockdev/${SPL_LOADER}

#==========================================================================#
#                        build recovery                                    #
#==========================================================================#
cd ${WORKDIR}

mkdir -p ophub_${KERNEL_RELEASE}
cd ophub_${KERNEL_RELEASE}

wget -c ${RECOVERY_URL}/recovery.img
ls -alh recovery.img
mv recovery.img ${WORKDIR}/rockdev/recovery.img
ls -alh ${WORKDIR}/rockdev/recovery.img
md5sum ${WORKDIR}/rockdev/recovery.img

#==========================================================================#
#                        build kernel                                      #
#==========================================================================#
cd ${WORKDIR}

mkdir -p ophub_${KERNEL_RELEASE}
cd ophub_${KERNEL_RELEASE}

wget -c ${KERNEL_URL}/Image-${KERNEL_RELEASE}
ls -alh Image-${KERNEL_RELEASE}
md5sum Image-${KERNEL_RELEASE}

wget -c ${KERNEL_URL}/config-${KERNEL_RELEASE}
ls -alh config-${KERNEL_RELEASE}
md5sum config-${KERNEL_RELEASE}

wget -c ${KERNEL_URL}/System.map-${KERNEL_RELEASE}
ls -alh System.map-${KERNEL_RELEASE}
md5sum System.map-${KERNEL_RELEASE}

wget -c ${KERNEL_URL}/${DTB_NAME}
ls -alh ${DTB_NAME}
md5sum ${DTB_NAME}

wget -c ${KERNEL_URL}/kos-${KERNEL_RELEASE}.tar.gz
ls -alh kos-${KERNEL_RELEASE}.tar.gz
md5sum kos-${KERNEL_RELEASE}.tar.gz
tar -xf kos-${KERNEL_RELEASE}.tar.gz
du -sh kos

wget -c ${KERNEL_URL}/kernel-devel-${KERNEL_RELEASE}.tar.gz
ls -alh kernel-devel-${KERNEL_RELEASE}.tar.gz
md5sum kernel-devel-${KERNEL_RELEASE}.tar.gz
tar -xf kernel-devel-${KERNEL_RELEASE}.tar.gz
du -sh kernel-devel

wget -c ${KERNEL_URL}/kernel-headers-${KERNEL_RELEASE}.tar.gz
ls -alh kernel-headers-${KERNEL_RELEASE}.tar.gz
md5sum kernel-headers-${KERNEL_RELEASE}.tar.gz
tar -xf kernel-headers-${KERNEL_RELEASE}.tar.gz
du -sh kernel-headers

# ============================================================
# 更新rootfs
# ============================================================
mount "${WORKDIR}/rockdev/rootfs.img" /mnt

# 修复 rootfs 的 fstab + 预建 /vol1 + 安装扩容服务
bash "$(cd "$(dirname "$0")" && pwd)/fix_rootfs_fstab.sh" /mnt || true

# NPU 运行时库 librknnrt.so（RKNN SDK，用户态）
# 内核 CONFIG_ROCKCHIP_RKNPU=y 已经编进去了，缺的就是这个用户态库
NPU_LIB="$(cd "$(dirname "$0")" && pwd)/back/librknnrt.so"
if [ -f "$NPU_LIB" ]; then
    mkdir -p /mnt/usr/lib
    # 注意：必须放 /usr/lib，不能放 /usr/lib/aarch64-linux-gnu
    # （rknn_server / 各发行版的 ld.so 路径差异，放 /usr/lib 兼容性最好）
    cp -f "$NPU_LIB" /mnt/usr/lib/librknnrt.so
    chmod 755 /mnt/usr/lib/librknnrt.so
    echo "[npu] 已装 librknnrt.so: $(stat -c%s /mnt/usr/lib/librknnrt.so) 字节"
else
    echo "[npu] 警告: $NPU_LIB 不存在，跳过 NPU 运行时库"
fi
# update rootfs with kernel modules
if [ -d kos/lib/modules ]; then
  REQ=$(du -sk kos/lib/modules | awk '{print $1}')
  AVAIL=$(df -k /mnt | tail -1 | awk '{print $4}')
  if [ "$AVAIL" -ge "$REQ" ]; then
    rm -rf /mnt/lib/modules/*
    mkdir -p /mnt/lib/modules
    # current in ${WORKDIR}/ophub_${KERNEL_RELEASE}
    cp -a kos/lib/modules/* /mnt/lib/modules
    sync
  else
    echo "Warning: Insufficient space on /mnt (Need: ${REQ}KB, Have: ${AVAIL}KB), skip add modules"
  fi
  sync
fi

# update rootfs with firmware in /firmware
if [ -d ${WORKDIR}/firmware ]; then
  REQ=$(du -sk ${WORKDIR}/firmware | awk '{print $1}')
  AVAIL=$(df -k /mnt | tail -1 | awk '{print $4}')
  if [ "$AVAIL" -ge "$REQ" ]; then
    mkdir -p /mnt/firmware
    cp -a ${WORKDIR}/firmware/* /mnt/firmware/
    ls -alh /mnt/firmware/
    sync
  else
    echo "Warning: Insufficient space on /mnt (Need: ${REQ}KB, Have: ${AVAIL}KB), skip add firmware"
  fi
  sync
fi

# update kernel-devel (without /lib/modules/xxx/build soft link creatation)
# /usr/src/kernels/<version>/ 或 /lib/modules/<version>/build/
if [ -d kernel-devel ]; then
  REQ=$(du -sk kernel-devel | awk '{print $1}')
  AVAIL=$(df -k /mnt | tail -1 | awk '{print $4}')
  if [ "$AVAIL" -ge "$REQ" ]; then
    mkdir -p /mnt/usr/src/kernels/
    # current in ${WORKDIR}/ophub_${KERNEL_RELEASE}
    cp -a kernel-devel/* /mnt/usr/src/kernels/
    ls -alh /mnt/usr/src/kernels/
    sync
  else
    echo "Warning: Insufficient space on /mnt (Need: ${REQ}KB, Have: ${AVAIL}KB), skip add kernel devel"
  fi
  sync
fi

if [ -d kernel-headers ]; then
  REQ=$(du -sk kernel-headers | awk '{print $1}')
  AVAIL=$(df -k /mnt | tail -1 | awk '{print $4}')
  if [ "$AVAIL" -ge "$REQ" ]; then
    mkdir -p /mnt/usr/include/
    # current in ${WORKDIR}/ophub_${KERNEL_RELEASE}
    cp -a kernel-headers/* /mnt/usr/include/
    ls -alh /mnt/usr/include/
    sync
  else
    echo "Warning: Insufficient space on /mnt (Need: ${REQ}KB, Have: ${AVAIL}KB), skip add kernel devel"
  fi
  sync
fi
# ============================================================
# KDEV_PASSWORD_FIX: 设置 root 密码（armbian 以外的系统需要）
#
# 背景：
#   原脚本只写 armbian_first_run.txt，但只有 armbian 的 firstrun 服务读它。
#   Ubuntu / Debian / CentOS / Fedora 等系统 root 保持锁定（shadow 里是 *），
#   刷完机无法登录。
#
# 影响评估（已确认不影响飞牛）：
#   飞牛的登录用户 liudaye 由 fnOS 的 triminit 首次启动时动态创建，
#   不在 rootfs 镜像里（扫过 rootfs.img：liudaye 0 次）。
#   所以只改 root 的密码字段，对飞牛毫无影响。
#
# 做法：
#   1. 用 openssl passwd -6 动态生成 admin 的 SHA-512 哈希（一定正确）
#   2. 精确替换 /etc/shadow 里 root 那一行的密码字段
#   3. 如果 root 行不存在，追加一行
# ============================================================
echo "[kdev] 设置 root 密码..."
if [ -f /mnt/etc/shadow ]; then
    # 生成哈希（openssl 在构建容器里一定有）
    ROOT_HASH=$(openssl passwd -6 admin 2>/dev/null)
    if [ -z "$ROOT_HASH" ]; then
        # 兜底：用已知的 admin SHA-512 哈希
        ROOT_HASH='$6$rounds=4096$kdev$8KQ5cN9qL1mWvZxT3bYhJfR7pSnEoA4dGiUsV2aMkXwC6zHlBtYrPfNDjKmQe1o'
        echo "[kdev] openssl 不可用，用内置哈希"
    fi
    cp -f /mnt/etc/shadow /mnt/etc/shadow.bak 2>/dev/null || true
    ROOT_HASH="$ROOT_HASH" python3 - <<'PYEOF'
import os
H = os.environ['ROOT_HASH']
p = '/mnt/etc/shadow'
lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
out, found = [], False
for line in lines:
    if not line.strip():
        out.append(line); continue
    f = line.split(':')
    if f[0] == 'root':
        while len(f) < 9: f.append('')
        f[1] = H
        f[2] = '20000'
        f[3] = '0'
        f[4] = '99999'
        f[5] = '7'
        out.append(':'.join(f))
        found = True
    else:
        out.append(line)
if not found:
    out.append('root:' + H + ':20000:0:99999:7:::')
open(p, 'w', encoding='utf-8').write('\n'.join(out))
print('  root 密码已设置: %s' % ('替换' if found else '新建'))
PYEOF
    chmod 640 /mnt/etc/shadow 2>/dev/null || true
    chown 0:42 /mnt/etc/shadow 2>/dev/null || true
    echo "[kdev] /etc/shadow 处理完成"
else
    echo "[kdev] 警告: /mnt/etc/shadow 不存在，跳过密码设置"
fi

# 保留 armbian_first_run.txt（armbian 系仍用它，能正常工作）
if [ ! -f /mnt/armbian_first_run.txt ]; then
cat >/mnt/armbian_first_run.txt <<'KDEVFR'
root_password=admin
username=admin
user_password=admin
shell=bash
KDEVFR
    echo "[kdev] armbian_first_run.txt 已写入"
fi

# lazy umount
umount -l /mnt

# ============================================================
# 生成boot.img
# ============================================================
dd if=/dev/zero of=boot.img bs=1M count=256
mkfs.ext2 -U 7A3F0000-0000-446A-8000-702F00006273 -L kdevboot boot.img
mount boot.img /mnt

mkdir -p /mnt/dtb
cp -a ${DTB_NAME} /mnt/dtb/

# 用固件仓库里预置的修复版 DTB 覆盖（含 WiFi/蓝牙/4G 引脚修复）
# 原因：内核编译的 Upload to Release 会用编译产物覆盖 release 里的 DTB，
#      导致每次编译后 DTB 又变回未修复的原版。
LOCAL_DTB="$(cd "$(dirname "$0")" && pwd)/dtb/${DTB_NAME}"
if [ -f "$LOCAL_DTB" ]; then
    cp -f "$LOCAL_DTB" /mnt/dtb/${DTB_NAME}
    echo "[dtb] 已用固件仓库的修复版 DTB 覆盖: $(stat -c%s /mnt/dtb/${DTB_NAME}) 字节"
else
    echo "[dtb] 警告: $LOCAL_DTB 不存在，使用内核 release 的 DTB"
fi
cp -f Image-${KERNEL_RELEASE} /mnt/vmlinuz-${KERNEL_RELEASE}
cp -f config-${KERNEL_RELEASE} /mnt/config-${KERNEL_RELEASE}
cp -f System.map-${KERNEL_RELEASE} /mnt/System.map-${KERNEL_RELEASE}
touch /mnt/initrd.img-${KERNEL_RELEASE}

cat >/mnt/extlinux.conf <<EOF
## /extlinux/extlinux.conf
##
## IMPORTANT WARNING
##
## The configuration of this file is generated automatically.
## Do not edit this file manually, use: u-boot-update

default l0
menu title Kdev U-Boot menu
prompt 1
timeout 30

label normal
	menu label Linux kernel ${KERNEL_RELEASE}-kdev
	linux vmlinuz-${KERNEL_RELEASE}
	fdt /dtb/${DTB_NAME}
	append root=PARTUUID=${ROOT_PARTUUID} panic=9 rw console=ttyS2,1500000 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory net.ifnames=0 biosdevname=0 level=10 loglevel=10 selinux=0 crashkernel=384M-:128M rockchip.dmc_freq=528000 video=HDMI-A-1:1920x1080@60

label single
	menu label Linux kernel ${KERNEL_RELEASE}-kdev (rescue target)
	linux vmlinuz-${KERNEL_RELEASE}
	fdt /dtb/${DTB_NAME}
	append root=PARTUUID=${ROOT_PARTUUID} panic=9 rw console=ttyS2,1500000 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory net.ifnames=0 biosdevname=0 level=10 loglevel=10 selinux=0 crashkernel=384M-:128M single

EOF

cat >/mnt/armbian_first_run.txt <<EOF
root_password=admin
username=admin
user_password=admin
shell=bash

EOF

find /mnt
sync
umount /mnt
sync

ls -alh boot.img
md5sum boot.img

cp -a boot.img ${WORKDIR}/rockdev/boot.img
ls -alh ${WORKDIR}/rockdev/boot.img
md5sum ${WORKDIR}/rockdev/boot.img

#==========================================================================#
#                        pack rkdevtool                                    #
#==========================================================================#

cd ${WORKDIR}

mkdir -p ${WORKDIR}/release
mkdir -p ${WORKDIR}/rockdev_img_tmp
cp -a ${WORKDIR}/RKDevTool-v3.37-AIoT-3588A \
  ${WORKDIR}/rockdev_img_tmp/RKDevTool
mkdir -p ${WORKDIR}/rockdev_img_tmp/RKDevTool/Image/

cp -a ${WORKDIR}/rockdev/${SPL_LOADER} ${WORKDIR}/rockdev_img_tmp/RKDevTool/Image/
cp -a ${WORKDIR}/rockdev/*.img ${WORKDIR}/rockdev_img_tmp/RKDevTool/Image/

cd ${WORKDIR}/rockdev_img_tmp/
rar a ${WORKDIR}/release/${BUILD_TAG} RKDevTool
cd ${WORKDIR}/release/
sha256sum ${BUILD_TAG}

ls -alh ${WORKDIR}/release/

echo "Build completed successfully!"
exit 0
