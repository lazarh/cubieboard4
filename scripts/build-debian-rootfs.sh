#!/bin/bash
# build-debian-rootfs.sh — Bootstrap a Debian 13 (trixie) armhf rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host with:
#   qemu-user-static binfmt-support debootstrap
# installed (see install-deps.sh).
#
# Produces: <REPO_ROOT>/debian-rootfs/
# The rootfs is consumed by assemble-sd-image.sh to build the final .img.gz.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"
YOCTO_DEPLOY="${REPO_ROOT}/build/tmp/deploy/images/cubieboard4"
ARCH=armhf
SUITE=trixie
MIRROR=http://deb.debian.org/debian

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (debootstrap requires chroot)"

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

command -v debootstrap   >/dev/null || die "debootstrap not found — run install-deps.sh"
command -v qemu-arm-static >/dev/null || die "qemu-user-static not found — run install-deps.sh"

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

# Copy QEMU binary so the chroot can run ARM binaries on x86
cp /usr/bin/qemu-arm-static "${SYSROOT}/usr/bin/"

# ── Second stage (inside chroot) ────────────────────────────────────────────

echo "==> Stage 2: debootstrap second stage inside chroot"
chroot "${SYSROOT}" /debootstrap/debootstrap --second-stage

# Mount virtual filesystems so chroot postinst scripts (ldconfig, systemd, etc.) work correctly
mount_chroot

# ── Configure the system inside chroot ─────────────────────────────────────

echo "==> Configuring Debian system..."

# Apt sources
cat > "${SYSROOT}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

# Hostname
echo "cubieboard4" > "${SYSROOT}/etc/hostname"
cat > "${SYSROOT}/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  cubieboard4
::1        localhost ip6-localhost ip6-loopback
EOF

# Locale
echo "en_US.UTF-8 UTF-8" >> "${SYSROOT}/etc/locale.gen"
chroot "${SYSROOT}" locale-gen

# Timezone
echo "UTC" > "${SYSROOT}/etc/timezone"
chroot "${SYSROOT}" dpkg-reconfigure -f noninteractive tzdata

# /etc/fstab (SD card layout; overwritten by install-to-emmc.sh on eMMC)
# mmcblk0 = SD card, mmcblk2 = eMMC
cat > "${SYSROOT}/etc/fstab" <<EOF
/dev/mmcblk0p2  /      ext4  defaults,noatime  0  1
/dev/mmcblk0p1  /boot  vfat  defaults          0  2
tmpfs           /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

# Serial console
mkdir -p "${SYSROOT}/etc/systemd/system/getty.target.wants"
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

# ── Docker CE (armhf) ───────────────────────────────────────────────────────

echo "==> Setting up Docker CE apt repo..."
install -m 0755 -d "${SYSROOT}/etc/apt/keyrings"
# Download the Docker GPG key from the internet (build-host needs network)
curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o "${SYSROOT}/etc/apt/keyrings/docker.gpg"
chmod a+r "${SYSROOT}/etc/apt/keyrings/docker.gpg"

cat > "${SYSROOT}/etc/apt/sources.list.d/docker.list" <<EOF
deb [arch=armhf signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian ${SUITE} stable
EOF

chroot "${SYSROOT}" apt-get update -q
chroot "${SYSROOT}" apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable Docker service
chroot "${SYSROOT}" systemctl enable docker.service || true
chroot "${SYSROOT}" systemctl enable containerd.service || true

# ── Kernel modules from Yocto ───────────────────────────────────────────────

echo "==> Installing kernel modules from Yocto..."
MODULES_TGZ=$(ls "${YOCTO_DEPLOY}"/modules-*.tgz 2>/dev/null | sort -V | tail -1)
if [[ -n "${MODULES_TGZ}" ]]; then
    echo "    Using ${MODULES_TGZ}"
    # Debian trixie uses usrmerge (/lib -> usr/lib symlink).  Extracting the
    # Yocto tarball (which has a top-level lib/ entry) directly into SYSROOT
    # would replace that symlink with a real directory, breaking all ARM
    # binary execution.  Extract into usr/ instead so lib/modules lands at
    # the correct usr/lib/modules path without touching the symlink.
    tar -xzf "${MODULES_TGZ}" -C "${SYSROOT}/usr" --strip-components=0
    KVER=$(ls "${SYSROOT}/usr/lib/modules/")
    chroot "${SYSROOT}" depmod -a "${KVER}" || true
else
    echo "    WARNING: No modules tarball found in ${YOCTO_DEPLOY}"
    echo "    Run 'kas build kas.yml' first, then re-run this script."
fi

# ── BCM4330 WiFi firmware NVRAM ─────────────────────────────────────────────
# Debian's firmware-brcm80211 only ships a Prowise tablet NVRAM, not the
# generic brcmfmac4330-sdio.txt that brcmfmac needs as a fallback.
# Download the generic NVRAM from linux-firmware and add a board-specific
# symlink so brcmfmac finds it automatically.

echo "==> Fetching BCM4330 NVRAM from linux-firmware..."
BRCM_DIR="${SYSROOT}/usr/lib/firmware/brcm"
curl -fsSL \
    "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/brcmfmac4330-sdio.txt" \
    -o "${BRCM_DIR}/brcmfmac4330-sdio.txt"
# Board-specific symlink: driver tries <board-compatible>.txt before the generic one
ln -sf brcmfmac4330-sdio.txt \
    "${BRCM_DIR}/brcmfmac4330-sdio.cubietech,a80-cubieboard4.txt"



echo "==> Embedding install-to-emmc.sh..."
install -m 0755 "${SCRIPT_DIR}/install-to-emmc.sh" \
    "${SYSROOT}/usr/local/sbin/install-to-emmc.sh"

# ── Copy U-Boot binary into /boot ───────────────────────────────────────────

echo "==> Copying U-Boot to /boot..."
UBOOT_BIN=$(ls "${YOCTO_DEPLOY}"/u-boot-sunxi-with-spl*.bin 2>/dev/null | sort -V | tail -1)
if [[ -n "${UBOOT_BIN}" ]]; then
    install -m 0644 "${UBOOT_BIN}" "${SYSROOT}/boot/u-boot-sunxi-with-spl.bin"
else
    echo "    WARNING: U-Boot binary not found in ${YOCTO_DEPLOY}"
fi

# ── root password ───────────────────────────────────────────────────────────

echo "==> Setting root password to 'root' (change after first boot!)"
echo "root:root" | chroot "${SYSROOT}" chpasswd

# ── Cleanup ─────────────────────────────────────────────────────────────────

# Remove the QEMU static binary — not needed at runtime on real ARM hardware
rm -f "${SYSROOT}/usr/bin/qemu-arm-static"
chroot "${SYSROOT}" apt-get clean
rm -rf "${SYSROOT}/var/lib/apt/lists/"*

echo ""
echo "==> Debian 13 rootfs ready at: ${SYSROOT}"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
