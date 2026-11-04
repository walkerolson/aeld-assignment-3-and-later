#!/bin/bash
# Script to install and build the kernel and root filesystem.
# Author: Siddhant Jajoo.

set -euo pipefail

OUTDIR=/tmp/aeld
KERNEL_REPO=git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
KERNEL_VERSION=v5.15.163
BUSYBOX_REPO=git://busybox.net/busybox.git
BUSYBOX_VERSION=1_33_1
FINDER_APP_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ARCH=arm64
CROSS_COMPILE=aarch64-none-linux-gnu-

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [outdir]" >&2
    exit 1
elif [ "$#" -eq 1 ]; then
    OUTDIR=$1
    echo "Using passed directory ${OUTDIR} for output"
else
    echo "Using default directory ${OUTDIR} for output"
fi

if ! mkdir -p -- "$OUTDIR"; then
    echo "Error: Could not create output directory ${OUTDIR}" >&2
    exit 1
fi
OUTDIR=$(cd -- "$OUTDIR" && pwd)
ROOTFS="${OUTDIR}/rootfs"
READELF="${CROSS_COMPILE}readelf"
CC="${CROSS_COMPILE}gcc"

if ! command -v "$CC" >/dev/null 2>&1 || ! command -v "$READELF" >/dev/null 2>&1; then
    echo "Error: ${CC} and ${READELF} must be available in PATH" >&2
    exit 1
fi

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/linux-stable" ]; then
    echo "Cloning Linux stable ${KERNEL_VERSION} into ${OUTDIR}"
    git clone "$KERNEL_REPO" --depth 1 --single-branch --branch "$KERNEL_VERSION" linux-stable
fi

if [ ! -e "${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image" ]; then
    cd "${OUTDIR}/linux-stable"
    echo "Checking out version ${KERNEL_VERSION}"
    git checkout "$KERNEL_VERSION"
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig
    make -j"$(nproc)" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" Image
fi

echo "Adding the kernel Image to ${OUTDIR}"
cp "${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image" "${OUTDIR}/Image"

echo "Creating the staging directory for the root filesystem"
if [ -d "$ROOTFS" ]; then
    echo "Deleting rootfs directory at ${ROOTFS} and starting over"
    sudo rm -rf -- "$ROOTFS"
fi
mkdir -p "$ROOTFS"/{bin,dev,etc,home,lib,proc,sys,tmp,usr/bin,usr/sbin}
chmod 1777 "$ROOTFS/tmp"

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/busybox" ]; then
    git clone "$BUSYBOX_REPO" busybox
fi
cd "${OUTDIR}/busybox"
git checkout "$BUSYBOX_VERSION"
make distclean
make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig
make -j"$(nproc)" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE"
make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" CONFIG_PREFIX="$ROOTFS" install

copy_runtime_dependencies()
{
    local binary=$1
    local sysroot
    local interpreter
    local candidate
    local dependency
    local relative_path
    local staged_path
    local item
    local -a queue=()
    local -A processed=()

    sysroot=$("$CC" -print-sysroot)
    if [ -z "$sysroot" ] || [ ! -d "$sysroot" ]; then
        echo "Error: Could not locate the target sysroot using ${CC}" >&2
        return 1
    fi

    interpreter=$("$READELF" -l "$binary" |
        sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
    if [ -n "$interpreter" ]; then
        candidate="${sysroot}${interpreter}"
        if [ ! -e "$candidate" ]; then
            echo "Error: Could not find interpreter ${interpreter} in ${sysroot}" >&2
            return 1
        fi
        mkdir -p "${ROOTFS}$(dirname "$interpreter")"
        cp -L "$candidate" "${ROOTFS}${interpreter}"
        queue+=("${ROOTFS}${interpreter}")
    fi

    queue+=("$binary")
    while [ "${#queue[@]}" -gt 0 ]; do
        item=${queue[0]}
        queue=("${queue[@]:1}")
        [ -n "${processed[$item]+x}" ] && continue
        processed["$item"]=1

        while IFS= read -r dependency; do
            [ -n "$dependency" ] || continue
            candidate=$(find "$sysroot" \( -type f -o -type l \) \
                -name "$dependency" -print -quit)
            if [ -z "$candidate" ]; then
                echo "Error: Could not find shared library ${dependency} in ${sysroot}" >&2
                return 1
            fi

            relative_path=${candidate#"$sysroot"/}
            staged_path="${ROOTFS}/${relative_path}"
            mkdir -p "$(dirname "$staged_path")"
            cp -L "$candidate" "$staged_path"
            queue+=("$staged_path")
        done < <("$READELF" -d "$item" |
            sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
    done
}

echo "Adding BusyBox and writer runtime dependencies"
copy_runtime_dependencies "${ROOTFS}/bin/busybox"

echo "Building the writer utility for ${ARCH}"
make -C "$FINDER_APP_DIR" clean
make -C "$FINDER_APP_DIR" CROSS_COMPILE="$CROSS_COMPILE"
copy_runtime_dependencies "${FINDER_APP_DIR}/writer"

echo "Creating device nodes"
sudo mknod -m 600 "${ROOTFS}/dev/console" c 5 1
sudo mknod -m 666 "${ROOTFS}/dev/null" c 1 3

echo "Copying finder application files to the target root filesystem"
cp "${FINDER_APP_DIR}/finder.sh" "${ROOTFS}/home/finder.sh"
cp "${FINDER_APP_DIR}/finder-test.sh" "${ROOTFS}/home/finder-test.sh"
cp "${FINDER_APP_DIR}/autorun-qemu.sh" "${ROOTFS}/home/autorun-qemu.sh"
cp "${FINDER_APP_DIR}/writer" "${ROOTFS}/home/writer"
chmod +x "${ROOTFS}/home/"*.sh "${ROOTFS}/home/writer"
mkdir -p "${ROOTFS}/conf"
cp "${FINDER_APP_DIR}/../conf/username.txt" "${ROOTFS}/conf/username.txt"
cp "${FINDER_APP_DIR}/../conf/assignment.txt" "${ROOTFS}/conf/assignment.txt"
ln -s ../conf "${ROOTFS}/home/conf"

echo "Setting root filesystem ownership"
sudo chown -R root:root "$ROOTFS"

echo "Creating initramfs.cpio.gz"
(
    cd "$ROOTFS"
    sudo find . -print0 | sudo cpio --null -o -H newc
) | gzip -9 > "${OUTDIR}/initramfs.cpio.gz"

echo "Linux image and initramfs are ready in ${OUTDIR}"
