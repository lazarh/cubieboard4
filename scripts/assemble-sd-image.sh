#!/bin/bash
# assemble-sd-image.sh — Build a bootable SD card image for CubieBoard4.
#
# Prerequisites:
#   1. kas build kas.yml           (produces kernel, DTB, U-Boot)
#   2. sudo scripts/build-debian-rootfs.sh  (produces debian-rootfs/)
#
# Must be run as root (loop device + mount require it).
#
# Output: cubieboard4-debian13.img.gz  (and matching .bmap for bmaptool)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"
DEPLOY="${REPO_ROOT}/build/tmp/deploy/images/cubieboard4"
OUTPUT="${REPO_ROOT}/cubieboard4-debian13.img"
BOOT_SIZE_MIB=80       # FAT boot partition size in MiB
IMAGE_SIZE_MIB=3200    # Total image size (~3 GiB, grows to fill eMMC after install)

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
LOOP_DEV=""

cleanup() {
    if [[ -n "${LOOP_DEV}" ]]; then
        umount "${LOOP_DEV}p1" 2>/dev/null || true
        umount "${LOOP_DEV}p2" 2>/dev/null || true
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
WORK_DIR=$(mktemp -d)
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -d "${SYSROOT}" ]] || die "debian-rootfs/ not found — run scripts/build-debian-rootfs.sh first"

# ── Locate Yocto artifacts ─────────────────────────────────────────────────

UBOOT_BIN=$(ls "${DEPLOY}"/u-boot-sunxi-with-spl*.bin 2>/dev/null | sort -V | tail -1)
KERNEL=$(ls "${DEPLOY}"/uImage* 2>/dev/null | grep -v 'dbg\|modules' | sort -V | tail -1)
DTB="${DEPLOY}/sun9i-a80-cubieboard4.dtb"
BOOT_SCR=$(ls "${DEPLOY}"/boot.scr* 2>/dev/null | sort -V | tail -1 || true)

[[ -f "${UBOOT_BIN}" ]] || die "U-Boot binary not found in ${DEPLOY} — run kas build kas.yml"
[[ -f "${KERNEL}"   ]] || die "Kernel uImage not found in ${DEPLOY}"
[[ -f "${DTB}"      ]] || die "DTB not found at ${DTB}"

echo "==> Artifacts:"
echo "    U-Boot : ${UBOOT_BIN}"
echo "    Kernel : ${KERNEL}"
echo "    DTB    : ${DTB}"
[[ -f "${BOOT_SCR}" ]] && echo "    boot.scr: ${BOOT_SCR}"

# ── Create blank image ─────────────────────────────────────────────────────

echo "==> Creating ${IMAGE_SIZE_MIB} MiB image file..."
rm -f "${OUTPUT}"
fallocate -l "${IMAGE_SIZE_MIB}MiB" "${OUTPUT}"

# ── Partition ──────────────────────────────────────────────────────────────

echo "==> Partitioning..."
parted -s "${OUTPUT}" mklabel msdos
# Leave first 40 MiB for U-Boot SPL (sits at 8 KiB offset, well within 40 MiB)
parted -s "${OUTPUT}" mkpart primary fat32  40MiB $((40 + BOOT_SIZE_MIB))MiB
parted -s "${OUTPUT}" mkpart primary ext4   $((40 + BOOT_SIZE_MIB))MiB 100%

# ── Attach loop device ─────────────────────────────────────────────────────

LOOP_DEV=$(losetup --find --partscan --show "${OUTPUT}")
echo "==> Loop device: ${LOOP_DEV}"
sleep 1

# ── Flash U-Boot ────────────────────────────────────────────────────────────

echo "==> Flashing U-Boot at 8 KiB offset..."
dd if="${UBOOT_BIN}" of="${OUTPUT}" bs=1k seek=8 conv=notrunc 2>/dev/null

# ── Format partitions ──────────────────────────────────────────────────────

echo "==> Formatting partitions..."
mkfs.vfat -n BOOT "${LOOP_DEV}p1"
mkfs.ext4 -L rootfs "${LOOP_DEV}p2"

# ── Populate boot partition ────────────────────────────────────────────────

echo "==> Populating boot partition..."
mkdir -p "${WORK_DIR}/boot"
mount "${LOOP_DEV}p1" "${WORK_DIR}/boot"

cp "${KERNEL}" "${WORK_DIR}/boot/uImage"
cp "${DTB}"    "${WORK_DIR}/boot/sun9i-a80-cubieboard4.dtb"
[[ -f "${BOOT_SCR}" ]] && cp "${BOOT_SCR}" "${WORK_DIR}/boot/boot.scr"

# U-Boot binary also goes to /boot so install-to-emmc.sh can find it at runtime
cp "${UBOOT_BIN}" "${WORK_DIR}/boot/u-boot-sunxi-with-spl.bin"

umount "${WORK_DIR}/boot"

# ── Populate rootfs partition ──────────────────────────────────────────────

echo "==> Populating rootfs partition (rsync from ${SYSROOT})..."
mkdir -p "${WORK_DIR}/root"
mount "${LOOP_DEV}p2" "${WORK_DIR}/root"

rsync -aAX "${SYSROOT}/" "${WORK_DIR}/root/"

# Recreate empty pseudo-fs mountpoints
mkdir -p "${WORK_DIR}/root"/{proc,sys,dev,run,tmp}
chmod 1777 "${WORK_DIR}/root/tmp"

# Update /etc/fstab with real UUIDs
BOOT_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p1")
ROOT_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p2")
cat > "${WORK_DIR}/root/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /      ext4  defaults,noatime  0  1
UUID=${BOOT_UUID}  /boot  vfat  defaults          0  2
tmpfs              /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

sync
umount "${WORK_DIR}/root"
losetup -d "${LOOP_DEV}"
LOOP_DEV=""

# ── Compress ───────────────────────────────────────────────────────────────

echo "==> Compressing to ${OUTPUT}.gz ..."
pigz -9 --keep "${OUTPUT}" 2>/dev/null || gzip -9 -k "${OUTPUT}"

# Generate bmap from the uncompressed image; name it after the .gz so
# bmaptool can find it automatically (it looks for <image>.bmap).
if command -v bmaptool >/dev/null 2>&1; then
    bmaptool create "${OUTPUT}" > "${OUTPUT}.gz.bmap"
    echo "==> bmap written to ${OUTPUT}.gz.bmap"
fi

echo ""
echo "==> Done!"
echo ""
echo "Flash to SD card:"
echo "  bmaptool copy ${OUTPUT}.gz /dev/sdX"
echo "  # or:"
echo "  zcat ${OUTPUT}.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
echo "After first boot, run as root on the board:"
echo "  install-to-emmc.sh"
