#!/bin/bash
# install-to-emmc.sh — Copy the running SD card OS to the internal eMMC.
#
# Run this from the booted SD card image as root.
# The internal eMMC appears as /dev/mmcblk2 on CubieBoard4.
#
# Partition layout written to eMMC:
#   raw offset 8KB : U-Boot SPL + proper
#   /dev/mmcblk2p1 : 40 MiB FAT  — /boot (kernel, DTB, boot.scr)
#   /dev/mmcblk2p2 : remaining   — ext4  / (rootfs)

set -euo pipefail

EMMC=/dev/mmcblk2
BOOT_PART="${EMMC}p1"
ROOT_PART="${EMMC}p2"
UBOOT_BIN=/boot/u-boot-sunxi-with-spl.bin
WORK_DIR=$(mktemp -d)

# ── Helpers ────────────────────────────────────────────────────────────────

cleanup() {
    umount "${WORK_DIR}/boot"  2>/dev/null || true
    umount "${WORK_DIR}/root"  2>/dev/null || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Preflight checks ────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -b "${EMMC}" ]] || die "${EMMC} not found — is the eMMC recognised by the kernel?"
[[ -f "${UBOOT_BIN}" ]] || die "${UBOOT_BIN} not found"

# Refuse to overwrite if eMMC already has a recognisable ext4 rootfs
if blkid "${ROOT_PART}" 2>/dev/null | grep -q 'TYPE="ext4"'; then
    read -rp "eMMC already has an ext4 rootfs. Overwrite? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

echo "==> Installing to ${EMMC}. All data on it will be lost."
echo "    Press Ctrl-C within 5 seconds to abort."
sleep 5

# ── Partition eMMC ─────────────────────────────────────────────────────────

echo "==> Partitioning ${EMMC}..."
wipefs -a "${EMMC}"
parted -s "${EMMC}" mklabel msdos
parted -s "${EMMC}" mkpart primary fat32 40MiB 80MiB
parted -s "${EMMC}" mkpart primary ext4  80MiB 100%
partprobe "${EMMC}"
sleep 2

mkfs.vfat -n BOOT "${BOOT_PART}"
mkfs.ext4 -L rootfs "${ROOT_PART}"

# ── Flash U-Boot ────────────────────────────────────────────────────────────

echo "==> Flashing U-Boot to ${EMMC} at 8 KiB offset..."
dd if="${UBOOT_BIN}" of="${EMMC}" bs=1k seek=8 conv=fsync 2>/dev/null

# ── Mount target partitions ─────────────────────────────────────────────────

mkdir -p "${WORK_DIR}/boot" "${WORK_DIR}/root"
mount "${BOOT_PART}" "${WORK_DIR}/boot"
mount "${ROOT_PART}" "${WORK_DIR}/root"

# ── Copy boot partition ─────────────────────────────────────────────────────

echo "==> Copying boot files..."
cp -a /boot/. "${WORK_DIR}/boot/"
# Remove U-Boot binary itself from the FAT partition (it lives in raw sectors)
rm -f "${WORK_DIR}/boot/u-boot-sunxi-with-spl.bin"

# ── Copy rootfs ─────────────────────────────────────────────────────────────

echo "==> Copying rootfs (this takes a few minutes)..."
rsync -aAX --exclude=/proc --exclude=/sys --exclude=/dev \
           --exclude=/run  --exclude=/tmp --exclude=/boot \
           / "${WORK_DIR}/root/"

# Recreate essential empty dirs
mkdir -p "${WORK_DIR}/root"/{proc,sys,dev,run,tmp,boot}
chmod 1777 "${WORK_DIR}/root/tmp"

# ── Update /etc/fstab on eMMC ───────────────────────────────────────────────

echo "==> Updating /etc/fstab on eMMC..."
BOOT_UUID=$(blkid -s UUID -o value "${BOOT_PART}")
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
cat > "${WORK_DIR}/root/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /      ext4  defaults,noatime  0  1
UUID=${BOOT_UUID}  /boot  vfat  defaults          0  2
tmpfs              /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

# ── Done ────────────────────────────────────────────────────────────────────

sync
echo ""
echo "==> Done! Power off, remove the SD card, and boot from eMMC."
echo "    (U-Boot will automatically prefer eMMC when no SD card is inserted)"
