#!/bin/bash
# build-rootfs-config.sh — Configure system settings in the Alpine rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   build-rootfs-alpine.sh must have been run
#
# Environment variables:
#   BOARD_HOSTNAME=myboard — set board hostname (default: cubieboard4)
#   WIFI_SSID=MyNetwork   — pre-configure WiFi (requires WIFI_PASSWORD)
#   WIFI_PASSWORD=secret  — WPA2 passphrase for WIFI_SSID
#
# Produces: alpine-rootfs/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/alpine-rootfs"
KERNEL_BUILD="${REPO_ROOT}/build/kernel"
MODULES_DIR="${KERNEL_BUILD}/modules"

BOARD_HOSTNAME="${BOARD_HOSTNAME:-cubieboard4}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -d "${SYSROOT}" ]] || die "Rootfs not found — run scripts/build-rootfs-alpine.sh first"

# Ensure QEMU is present
if [[ ! -f "${SYSROOT}/usr/bin/qemu-arm-static" ]]; then
    cp /usr/bin/qemu-arm-static "${SYSROOT}/usr/bin/"
fi

mount_chroot() {
    mount -t proc  proc     "${SYSROOT}/proc"
    mount -t sysfs sysfs    "${SYSROOT}/sys"
    mount --bind   /dev     "${SYSROOT}/dev"
    mount --bind   /dev/pts "${SYSROOT}/dev/pts"
    mount -t tmpfs tmpfs    "${SYSROOT}/run"
}

umount_chroot() {
    umount "${SYSROOT}/run"     2>/dev/null || true
    umount "${SYSROOT}/dev/pts" 2>/dev/null || true
    umount "${SYSROOT}/dev"     2>/dev/null || true
    umount "${SYSROOT}/sys"     2>/dev/null || true
    umount "${SYSROOT}/proc"    2>/dev/null || true
}

trap umount_chroot EXIT

mount_chroot

# ── Hostname ─────────────────────────────────────────────────────────────

echo "==> Setting hostname to ${BOARD_HOSTNAME}..."
echo "${BOARD_HOSTNAME}" > "${SYSROOT}/etc/hostname"
# Remove machine-id so systemd regenerates it (prevents hostname conflicts)
rm -f "${SYSROOT}/etc/machine-id"
touch "${SYSROOT}/etc/machine-id"

# ── /etc/hosts ───────────────────────────────────────────────────────────

cat > "${SYSROOT}/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  ${BOARD_HOSTNAME}
::1        localhost ip6-localhost ip6-loopback
EOF

# ── Locale ───────────────────────────────────────────────────────────────

echo "    Skipping locale config (Alpine uses musl)"

# ── Timezone ─────────────────────────────────────────────────────────────

echo "    Skipping timezone config (Alpine)"

# ── /etc/fstab ──────────────────────────────────────────────────────────

cat > "${SYSROOT}/etc/fstab" <<EOF
/dev/mmcblk0p2  /      ext4  defaults,noatime  0  1
/dev/mmcblk0p1  /boot  vfat  defaults          0  2
tmpfs           /tmp   tmpfs defaults,nosuid,nodev  0 0
EOF
mkdir -p "${SYSROOT}/boot"

# ── Serial console ──────────────────────────────────────────────────────

echo "    Skipping serial console enable (already configured by build-rootfs-alpine.sh)"

# ── SSH ──────────────────────────────────────────────────────────────────

if ! grep -q "^PermitRootLogin yes" "${SYSROOT}/etc/ssh/sshd_config" 2>/dev/null; then
    echo "==> Configuring sshd..."
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${SYSROOT}/etc/ssh/sshd_config"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${SYSROOT}/etc/ssh/sshd_config"
else
    echo "    SSH already configured."
fi

# ── NTP ───────────────────────────────────────────────────────────────────

echo "    Skipping NTP enable (chrony managed by OpenRC via build-rootfs-alpine.sh)"

# ── sysctl tweaks ───────────────────────────────────────────────────────

if [[ ! -f "${SYSROOT}/etc/sysctl.d/90-docker.conf" ]]; then
    echo "==> Configuring sysctl for Docker..."
    mkdir -p "${SYSROOT}/etc/sysctl.d"
    cat > "${SYSROOT}/etc/sysctl.d/90-docker.conf" <<'EOF'
vm.memfd_noexec=0
EOF
else
    echo "    sysctl already configured."
fi

# ── Load brcmfmac module ─────────────────────────────────────────────────

if ! grep -q "^brcmfmac$" "${SYSROOT}/etc/modules" 2>/dev/null; then
    echo "==> Adding brcmfmac and cfg80211 to /etc/modules..."
    echo "cfg80211" >> "${SYSROOT}/etc/modules"
    echo "brcmfmac" >> "${SYSROOT}/etc/modules"
else
    echo "    brcmfmac already in /etc/modules."
fi

# ── wpa_supplicant config ────────────────────────────────────────────────

if [[ ! -f "${SYSROOT}/etc/wpa_supplicant/wpa_supplicant.conf" ]]; then
    echo "==> Configuring wpa_supplicant..."
    mkdir -p "${SYSROOT}/etc/wpa_supplicant"
    cat > "${SYSROOT}/etc/wpa_supplicant/wpa_supplicant.conf" <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
p2p_disabled=1
EOF
else
    echo "    wpa_supplicant already configured."
fi

# ── BCM4330 WiFi firmware symlinks ──────────────────────────────────────
# Alpine stores firmware in /lib/firmware (not /usr/lib/firmware)

BRCM_DIR="${SYSROOT}/lib/firmware/brcm"
mkdir -p "${BRCM_DIR}"
if [[ -f "${BRCM_DIR}/brcmfmac4330-sdio.Prowise-PT301.txt" ]]; then
    echo "==> Creating BCM4330 firmware symlinks..."
    # Generic NVRAM name — tried by driver after board-specific names fail
    ln -sf brcmfmac4330-sdio.Prowise-PT301.txt \
        "${BRCM_DIR}/brcmfmac4330-sdio.txt"
    # Board-specific name based on DTB compatible string
    ln -sf brcmfmac4330-sdio.Prowise-PT301.txt \
        "${BRCM_DIR}/brcmfmac4330-sdio.cubietech,a80-cubieboard4.txt"
    for ext in bin clm_blob txcap_blob; do
        if [[ -f "${BRCM_DIR}/brcmfmac4330-sdio.${ext}" ]]; then
            ln -sf "brcmfmac4330-sdio.${ext}" \
                "${BRCM_DIR}/brcmfmac4330-sdio.cubietech,a80-cubieboard4.${ext}"
        fi
    done
    echo "    BCM4330 firmware symlinks created."
else
    echo "    WARNING: brcmfmac4330-sdio.Prowise-PT301.txt not found in ${BRCM_DIR}"
fi

# ── Fix regulatory.db - replace symlinks with actual files ───────────────────

echo "==> Fixing regulatory.db and signature..."
# Remove symlinks and broken files
rm -f "${SYSROOT}/lib/firmware/regulatory.db" "${SYSROOT}/lib/firmware/regulatory.db.p7s"
# Copy actual files
if [[ -f "${SYSROOT}/lib/firmware/regulatory.db-upstream" ]]; then
    cp "${SYSROOT}/lib/firmware/regulatory.db-upstream" "${SYSROOT}/lib/firmware/regulatory.db"
fi
if [[ -f "${SYSROOT}/lib/firmware/regulatory.db.p7s-upstream" ]]; then
    cp "${SYSROOT}/lib/firmware/regulatory.db.p7s-upstream" "${SYSROOT}/lib/firmware/regulatory.db.p7s"
fi

# ── Embed install-to-emmc.sh ──────────────────────────────────────────────

echo "==> Refreshing install-to-emmc.sh..."
mkdir -p "${SYSROOT}/usr/local/sbin"
install -m 0755 "${SCRIPT_DIR}/install-to-emmc.sh" \
    "${SYSROOT}/usr/local/sbin/install-to-emmc.sh"

# ── Embed U-Boot binary for install-to-emmc.sh ──────────────────────────

UBOOT_BIN="${REPO_ROOT}/build/uboot/u-boot-sunxi-with-spl.bin"
if [[ -f "${UBOOT_BIN}" ]]; then
    echo "==> Refreshing embedded U-Boot binary..."
    mkdir -p "${SYSROOT}/usr/local/share/cubieboard4"
    install -m 0644 "${UBOOT_BIN}" \
        "${SYSROOT}/usr/local/share/cubieboard4/u-boot-sunxi-with-spl.bin"
else
    echo "    WARNING: ${UBOOT_BIN} not found."
fi

# ── Root password ────────────────────────────────────────────────────────

echo "==> Setting root password to 'root' (change after first boot!)"
chroot "${SYSROOT}" bash -c 'echo "root:root" | chpasswd'

# ── WiFi pre-configuration ──────────────────────────────────────────────

if [[ -n "${WIFI_SSID}" && -n "${WIFI_PASSWORD}" ]]; then
    echo "    Skipping WiFi pre-configuration (already handled by build-rootfs-alpine.sh)"
elif [[ -n "${WIFI_SSID}" || -n "${WIFI_PASSWORD}" ]]; then
    echo "    WARNING: Both WIFI_SSID and WIFI_PASSWORD must be set to pre-configure WiFi."
fi

# ── Cleanup ──────────────────────────────────────────────────────────────

rm -f "${SYSROOT}/usr/bin/qemu-arm-static"

echo ""
echo "==> Rootfs configuration complete."
echo "    HOSTNAME was: ${BOARD_HOSTNAME}"
echo "    WIFI_SSID  was: ${WIFI_SSID:-<not set>}"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
