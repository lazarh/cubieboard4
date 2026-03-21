#!/bin/bash
# install-to-emmc.sh — Install the running SD card OS to the internal eMMC
#                      with a RAUC A/B dual-slot partition layout.
#
# Run this from the booted SD card image as root.
# The internal eMMC appears as /dev/mmcblk2 on CubieBoard4.
#
# Partition layout written to eMMC:
#   raw @ 8KB        : U-Boot SPL + u-boot.img (no partition)
#   raw @ 4MiB       : U-Boot env (128KB, for fw_printenv / RAUC)
#   /dev/mmcblk2p1   : 80MiB FAT  — /boot (kernel, DTB, boot.scr, shared)
#   /dev/mmcblk2p2   : ~3.3GiB ext4 — rootfsA (RAUC slot A, initial rootfs)
#   /dev/mmcblk2p3   : ~3.3GiB ext4 — rootfsB (RAUC slot B, empty until first update)

set -euo pipefail

EMMC=/dev/mmcblk2
BOOT_PART="${EMMC}p1"
SLOT_A_PART="${EMMC}p2"
SLOT_B_PART="${EMMC}p3"
UBOOT_BIN=/boot/u-boot-sunxi-with-spl.bin

# U-Boot raw env location (must match configs/uboot/rauc.config)
UBOOT_ENV_OFFSET=$((4 * 1024 * 1024))   # 4MiB in bytes
UBOOT_ENV_SIZE=$((128 * 1024))           # 128KB

WORK_DIR=$(mktemp -d)

# ── Helpers ────────────────────────────────────────────────────────────────

cleanup() {
    umount "${WORK_DIR}/boot"   2>/dev/null || true
    umount "${WORK_DIR}/slot_a" 2>/dev/null || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Preflight checks ────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -b "${EMMC}" ]] || die "${EMMC} not found — is the eMMC recognised by the kernel?"
[[ -f "${UBOOT_BIN}" ]] || die "${UBOOT_BIN} not found"

command -v mkenvimage >/dev/null || \
    die "mkenvimage not found — install u-boot-tools (apk add uboot-tools)"

# Refuse to overwrite if eMMC already has a rootfs
if blkid "${SLOT_A_PART}" 2>/dev/null | grep -q 'TYPE="ext4"'; then
    read -rp "eMMC already has a rootfs on slot A. Overwrite? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

echo "==> Installing RAUC A/B layout to ${EMMC}. All data on it will be lost."
echo "    Partition layout:"
echo "      p1  80MiB FAT   /boot     (shared boot partition)"
echo "      p2  ~3.3GiB ext4  rootfsA (RAUC slot A — active after install)"
echo "      p3  ~3.3GiB ext4  rootfsB (RAUC slot B — empty, for first OTA)"
echo ""
echo "    Press Ctrl-C within 5 seconds to abort."
sleep 5

# ── Partition eMMC ─────────────────────────────────────────────────────────

echo "==> Partitioning ${EMMC}..."
wipefs -a "${EMMC}"
sfdisk "${EMMC}" <<'SFDISK_EOF'
label: dos
# p1: /boot FAT, 40MiB–120MiB  (leaves first 40MiB for raw U-Boot + env)
start=40MiB,  size=80MiB,  type=b
# p2: rootfsA, 120MiB–3700MiB
start=120MiB, size=3580MiB, type=83
# p3: rootfsB, 3700MiB–end
start=3700MiB, size=+, type=83
SFDISK_EOF
partprobe "${EMMC}"
sleep 2

mkfs.vfat -n BOOT    "${BOOT_PART}"
mkfs.ext4 -L rootfsA "${SLOT_A_PART}"
mkfs.ext4 -L rootfsB "${SLOT_B_PART}"

# ── Flash U-Boot ────────────────────────────────────────────────────────────

echo "==> Flashing U-Boot to ${EMMC} at 8KiB offset..."
dd if="${UBOOT_BIN}" of="${EMMC}" bs=1k seek=8 conv=fsync 2>/dev/null

# ── Initialise RAUC U-Boot env ─────────────────────────────────────────────
#
# Write the initial RAUC boot variables into the raw env area at 4MiB so
# U-Boot picks them up on first boot (before any RAUC update has run).
# BOOT_ORDER="A B"  — prefer slot A
# BOOT_A_LEFT=3     — 3 attempts before falling back
# BOOT_B_LEFT=3     — slot B also starts with 3 (unused until first update)

echo "==> Writing initial RAUC U-Boot env at offset ${UBOOT_ENV_OFFSET} (4MiB)..."
ENV_TMP=$(mktemp)
cat > "${ENV_TMP}.txt" <<'EOF'
BOOT_ORDER=A B
BOOT_A_LEFT=3
BOOT_B_LEFT=3
bootdelay=2
kernel_addr_r=0x80080000
fdt_addr_r=0x8FA00000
scriptaddr=0x8FC00000
bootcmd=if mmc dev 1; then load mmc 1:1 ${scriptaddr} boot.scr && source ${scriptaddr}; fi; run distro_bootcmd
EOF
mkenvimage -s "${UBOOT_ENV_SIZE}" -o "${ENV_TMP}" "${ENV_TMP}.txt"
dd if="${ENV_TMP}" of="${EMMC}" \
    bs=512 seek=$(( UBOOT_ENV_OFFSET / 512 )) conv=fsync 2>/dev/null
rm -f "${ENV_TMP}" "${ENV_TMP}.txt"
echo "    RAUC env written (BOOT_ORDER='A B', bootcmd set, bootdelay=2)"

# ── Mount target partitions ─────────────────────────────────────────────────

mkdir -p "${WORK_DIR}/boot" "${WORK_DIR}/slot_a"
mount "${BOOT_PART}"   "${WORK_DIR}/boot"
mount "${SLOT_A_PART}" "${WORK_DIR}/slot_a"

# ── Copy boot partition ─────────────────────────────────────────────────────

echo "==> Copying boot files..."
cp -a /boot/. "${WORK_DIR}/boot/"
# U-Boot lives in raw sectors; remove it from the FAT partition
rm -f "${WORK_DIR}/boot/u-boot-sunxi-with-spl.bin"
# Ensure the RAUC boot.scr (not the SD single-slot one) is in /boot
# The SD image puts boot.scr from boot-sd.scr; replace with RAUC version if present
if [[ -f /boot/boot-rauc.scr ]]; then
    cp /boot/boot-rauc.scr "${WORK_DIR}/boot/boot.scr"
fi

# ── Copy rootfs to slot A ───────────────────────────────────────────────────

echo "==> Copying rootfs to slot A (this takes a few minutes)..."
rsync -aAX --exclude=/proc --exclude=/sys --exclude=/dev \
           --exclude=/run  --exclude=/tmp --exclude=/boot \
           / "${WORK_DIR}/slot_a/"

# Recreate essential empty dirs
mkdir -p "${WORK_DIR}/slot_a"/{proc,sys,dev,run,tmp,boot}
chmod 1777 "${WORK_DIR}/slot_a/tmp"

# ── Update /etc/fstab on slot A ─────────────────────────────────────────────

echo "==> Writing /etc/fstab for slot A..."
BOOT_UUID=$(blkid -s UUID -o value "${BOOT_PART}")
SLOT_A_UUID=$(blkid -s UUID -o value "${SLOT_A_PART}")
cat > "${WORK_DIR}/slot_a/etc/fstab" <<EOF
UUID=${SLOT_A_UUID}  /      ext4  defaults,noatime  0  1
UUID=${BOOT_UUID}    /boot  vfat  defaults          0  2
tmpfs                /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

# ── Write fw_env.config (for fw_printenv / RAUC uboot backend) ─────────────

echo "==> Writing /etc/fw_env.config..."
cat > "${WORK_DIR}/slot_a/etc/fw_env.config" <<EOF
# Device        Offset      Env-size
# Must match CONFIG_ENV_OFFSET and CONFIG_ENV_SIZE in configs/uboot/rauc.config
${EMMC}         0x400000    0x20000
EOF

# ── Done ────────────────────────────────────────────────────────────────────

sync
echo ""
echo "==> eMMC install complete!"
echo ""
echo "    Slot A (active): ${SLOT_A_PART}"
echo "    Slot B (empty):  ${SLOT_B_PART} — will be populated by first 'rauc install'"
echo ""
echo "    RAUC env initialised: BOOT_ORDER='A B', attempts=3"
echo ""
echo "    Power off, remove the SD card, and reboot from eMMC."
echo "    After first eMMC boot, verify RAUC with: rauc status"

