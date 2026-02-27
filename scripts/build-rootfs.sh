#!/bin/bash
# build-rootfs.sh — Bootstrap a Debian 13 (trixie) armhf rootfs for CubieBoard4.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   1. scripts/install-deps.sh    (installs debootstrap, qemu-user-static, etc.)
#   2. scripts/build-kernel.sh    (produces build/kernel/modules/ and zImage)
#
# Environment variables:
#   INSTALL_DOCKER=true   — also install Docker CE (default: false)
#   WIFI_SSID=MyNetwork   — pre-configure WiFi (requires WIFI_PASSWORD)
#   WIFI_PASSWORD=secret  — WPA2 passphrase for WIFI_SSID
#
# Produces: debian-rootfs/
# Consumed by: scripts/assemble-sd-image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"
KERNEL_BUILD="${REPO_ROOT}/build/kernel"
MODULES_DIR="${KERNEL_BUILD}/modules"
INSTALL_DOCKER="${INSTALL_DOCKER:-false}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
ARCH=armhf
SUITE=trixie
MIRROR=http://deb.debian.org/debian

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (debootstrap requires chroot)"

[[ -d "${KERNEL_BUILD}" ]] || die "build/kernel/ not found — run scripts/build-kernel.sh first"
[[ -f "${KERNEL_BUILD}/zImage" ]] || die "build/kernel/zImage not found — run scripts/build-kernel.sh first"

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

command -v debootstrap     >/dev/null || die "debootstrap not found — run scripts/install-deps.sh"
command -v qemu-arm-static >/dev/null || die "qemu-user-static not found — run scripts/install-deps.sh"

# ── First stage debootstrap ─────────────────────────────────────────────────

echo "==> Stage 1: debootstrap ${SUITE} ${ARCH} into ${SYSROOT}"
if [[ -d "${SYSROOT}/debootstrap" ]]; then
    echo "    Stage 1 already done, skipping."
else
    rm -rf "${SYSROOT}"
    debootstrap \
        --arch="${ARCH}" \
        --foreign \
        --components=main,contrib,non-free,non-free-firmware \
        --include=ca-certificates,curl,gnupg,locales,apt-transport-https \
        "${SUITE}" "${SYSROOT}" "${MIRROR}"
fi

# Copy QEMU binary so the chroot can execute ARM binaries on x86
cp /usr/bin/qemu-arm-static "${SYSROOT}/usr/bin/"

# ── Second stage (inside chroot) ────────────────────────────────────────────

echo "==> Stage 2: debootstrap second stage inside chroot"
chroot "${SYSROOT}" /debootstrap/debootstrap --second-stage

mount_chroot

# ── Configure the system ────────────────────────────────────────────────────

echo "==> Configuring Debian system..."

cat > "${SYSROOT}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

echo "cubieboard4" > "${SYSROOT}/etc/hostname"
cat > "${SYSROOT}/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  cubieboard4
::1        localhost ip6-localhost ip6-loopback
EOF

echo "en_US.UTF-8 UTF-8" >> "${SYSROOT}/etc/locale.gen"
chroot "${SYSROOT}" locale-gen

echo "UTC" > "${SYSROOT}/etc/timezone"
chroot "${SYSROOT}" dpkg-reconfigure -f noninteractive tzdata

# /etc/fstab — SD card layout; overwritten by install-to-emmc.sh on eMMC
cat > "${SYSROOT}/etc/fstab" <<EOF
/dev/mmcblk0p2  /      ext4  defaults,noatime  0  1
/dev/mmcblk0p1  /boot  vfat  defaults          0  2
tmpfs           /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

# Enable serial console (ttyS0)
chroot "${SYSROOT}" systemctl enable serial-getty@ttyS0.service || true

# ── Install base packages ───────────────────────────────────────────────────

echo "==> Installing packages..."
chroot "${SYSROOT}" apt-get update -q
chroot "${SYSROOT}" apt-get install -y --no-install-recommends \
    systemd-sysv dbus \
    iproute2 iputils-ping iw wpasupplicant network-manager \
    openssh-server \
    firmware-brcm80211 \
    usbutils pciutils \
    vim-tiny less \
    util-linux e2fsprogs dosfstools parted \
    rsync wget curl \
    mtd-utils \
    kmod

# ── Docker CE (optional) ────────────────────────────────────────────────────

if [[ "${INSTALL_DOCKER}" == "true" ]]; then
    echo "==> Setting up Docker CE (INSTALL_DOCKER=true)..."
    install -m 0755 -d "${SYSROOT}/etc/apt/keyrings"
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o "${SYSROOT}/etc/apt/keyrings/docker.gpg"
    chmod a+r "${SYSROOT}/etc/apt/keyrings/docker.gpg"
    cat > "${SYSROOT}/etc/apt/sources.list.d/docker.list" <<EOF
deb [arch=armhf signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian ${SUITE} stable
EOF
    chroot "${SYSROOT}" apt-get update -q
    chroot "${SYSROOT}" apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    chroot "${SYSROOT}" systemctl enable docker.service || true
    chroot "${SYSROOT}" systemctl enable containerd.service || true
else
    echo "==> Skipping Docker CE (set INSTALL_DOCKER=true to include it)"
fi

# ── Kernel modules ──────────────────────────────────────────────────────────

echo "==> Installing kernel modules from ${MODULES_DIR}..."
if [[ -d "${MODULES_DIR}/lib/modules" ]]; then
    # Debian trixie uses usrmerge (/lib -> usr/lib symlink).
    # Copy into usr/ so modules land at usr/lib/modules without breaking the symlink.
    cp -a "${MODULES_DIR}/lib/modules" "${SYSROOT}/usr/lib/"
    KVER=$(ls "${SYSROOT}/usr/lib/modules/" | head -1)
    chroot "${SYSROOT}" depmod -a "${KVER}" || true
    echo "    Installed modules for kernel ${KVER}"
else
    echo "    WARNING: No modules found in ${MODULES_DIR}/lib/modules"
fi

# ── BCM4330 WiFi firmware NVRAM ─────────────────────────────────────────────
# firmware-brcm80211 ships brcmfmac4330-sdio.Prowise-PT301.txt (same AMPAK AP6330
# module as on CubieBoard4). A generic brcmfmac4330-sdio.txt does not exist in
# linux-firmware; add a board-specific symlink so brcmfmac finds it automatically.

echo "==> Installing BCM4330 NVRAM symlink..."
BRCM_DIR="${SYSROOT}/usr/lib/firmware/brcm"
mkdir -p "${BRCM_DIR}"
if [[ -f "${BRCM_DIR}/brcmfmac4330-sdio.Prowise-PT301.txt" ]]; then
    # Driver looks up <board-compatible>.txt first; fall through to Prowise NVRAM.
    ln -sf brcmfmac4330-sdio.Prowise-PT301.txt \
        "${BRCM_DIR}/brcmfmac4330-sdio.cubietech,a80-cubieboard4.txt"
    echo "    BCM4330 NVRAM symlink installed (Prowise-PT301 → cubietech,a80-cubieboard4)."
else
    echo "    WARNING: brcmfmac4330-sdio.Prowise-PT301.txt not found — firmware-brcm80211 not installed?"
fi

# ── Kernel modules to load at boot ─────────────────────────────────────────
# Ensure brcmfmac loads at boot regardless of udev modalias matching.

echo "brcmfmac" >> "${SYSROOT}/etc/modules"

# ── Embed install-to-emmc.sh ────────────────────────────────────────────────

echo "==> Embedding install-to-emmc.sh..."
install -m 0755 "${SCRIPT_DIR}/install-to-emmc.sh" \
    "${SYSROOT}/usr/local/sbin/install-to-emmc.sh"

# ── Copy U-Boot binary to /boot ─────────────────────────────────────────────

echo "==> Copying U-Boot to /boot..."
UBOOT_BIN="${REPO_ROOT}/build/uboot/u-boot-sunxi-with-spl.bin"
if [[ -f "${UBOOT_BIN}" ]]; then
    install -m 0644 "${UBOOT_BIN}" "${SYSROOT}/boot/u-boot-sunxi-with-spl.bin"
else
    echo "    WARNING: ${UBOOT_BIN} not found — run scripts/build-uboot.sh first"
fi

# ── root password ───────────────────────────────────────────────────────────

echo "==> Setting root password to 'root' (change after first boot!)"
echo "root:root" | chroot "${SYSROOT}" chpasswd

# ── WiFi pre-configuration ──────────────────────────────────────────────────
# Write a NetworkManager connection profile so the board connects on first boot.
# Activate with: WIFI_SSID=MyNet WIFI_PASSWORD=secret sudo scripts/build-rootfs.sh

if [[ -n "${WIFI_SSID}" && -n "${WIFI_PASSWORD}" ]]; then
    echo "==> Pre-configuring WiFi for SSID: ${WIFI_SSID}"
    NM_DIR="${SYSROOT}/etc/NetworkManager/system-connections"
    mkdir -p "${NM_DIR}"
    cat > "${NM_DIR}/wifi-preconfigured.nmconnection" <<EOF
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
ssid=${WIFI_SSID}
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASSWORD}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
EOF
    chmod 600 "${NM_DIR}/wifi-preconfigured.nmconnection"
    echo "    WiFi profile written (SSID: ${WIFI_SSID})."
elif [[ -n "${WIFI_SSID}" || -n "${WIFI_PASSWORD}" ]]; then
    echo "    WARNING: Both WIFI_SSID and WIFI_PASSWORD must be set to pre-configure WiFi. Skipping."
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────

rm -f "${SYSROOT}/usr/bin/qemu-arm-static"
chroot "${SYSROOT}" apt-get clean
rm -rf "${SYSROOT}/var/lib/apt/lists/"*

echo ""
echo "==> Debian 13 rootfs ready at: ${SYSROOT}"
echo "    INSTALL_DOCKER was: ${INSTALL_DOCKER}"
echo "    WIFI_SSID     was: ${WIFI_SSID:-<not set>}"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
