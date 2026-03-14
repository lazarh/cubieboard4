#!/bin/bash
# build-rootfs-packages.sh — Install packages into Debian rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   scripts/build-rootfs-debootstrap.sh must have been run
#
# Environment variables:
#   REBUILD_PACKAGES=true — reinstall packages even if already done
#   INSTALL_DOCKER=true   — also install Docker CE (default: false)
#   SUITE=trixie          — Debian suite (default: trixie)
#   MIRROR=...            — apt mirror (default: http://deb.debian.org/debian)
#
# Produces: debian-rootfs/ with packages installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"

SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
INSTALL_DOCKER="${INSTALL_DOCKER:-false}"
REBUILD_PACKAGES="${REBUILD_PACKAGES:-false}"

PACKAGES_STAMP="${SYSROOT}/.packages_done"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -d "${SYSROOT}" ]] || die "Rootfs not found — run scripts/build-rootfs-debootstrap.sh first"
[[ -f "${SYSROOT}/.stage2_done" ]] || die "Stage 2 not complete — run scripts/build-rootfs-debootstrap.sh first"

command -v debootstrap >/dev/null || die "debootstrap not found"
command -v qemu-arm-static >/dev/null || die "qemu-user-static not found"

# Ensure QEMU is present (may be missing if rebuilt without debootstrap)
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

# ── Configure apt sources ─────────────────────────────────────────────────

echo "==> Configuring apt sources..."
cat > "${SYSROOT}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

# ── Install packages ──────────────────────────────────────────────────────

if [[ -f "${PACKAGES_STAMP}" && "${REBUILD_PACKAGES}" != true ]]; then
    echo "==> Packages already installed (skipping). Set REBUILD_PACKAGES=true to reinstall."
else
    echo "==> Installing packages..."
    chroot "${SYSROOT}" apt-get update -q

    chroot "${SYSROOT}" apt-get install -y --no-install-recommends \
        systemd-sysv dbus systemd-timesyncd \
        iproute2 iputils-ping iw wpasupplicant network-manager \
        openssh-server \
        firmware-brcm80211 wireless-regdb \
        usbutils pciutils \
        vim-tiny less \
        util-linux e2fsprogs dosfstools parted \
        rsync wget curl \
        mtd-utils \
        kmod iptables conntrack nftables

    # Ensure iptables uses the legacy backend
    chroot "${SYSROOT}" update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
    chroot "${SYSROOT}" update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    chroot "${SYSROOT}" update-alternatives --set arptables /usr/sbin/arptables-legacy 2>/dev/null || true
    chroot "${SYSROOT}" update-alternatives --set ebtables /usr/sbin/ebtables-legacy 2>/dev/null || true

    # Docker CE (optional)
    if [[ "${INSTALL_DOCKER}" == "true" ]]; then
        echo "==> Setting up Docker CE..."
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
    fi

    # Clean apt cache
    chroot "${SYSROOT}" apt-get clean
    rm -rf "${SYSROOT}/var/lib/apt/lists/"*

    touch "${PACKAGES_STAMP}"
    echo "    Packages installed."
fi

echo ""
echo "==> Packages stage complete. Run build-rootfs-kernel.sh next."
