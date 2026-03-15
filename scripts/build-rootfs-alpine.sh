#!/bin/bash
# build-rootfs-alpine.sh — Bootstrap Alpine Linux 3.20 armhf rootfs for CubieBoard4.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   scripts/install-deps.sh
#   scripts/build-kernel.sh
#
# Environment variables:
#   BOARD_HOSTNAME=myboard — set board hostname (default: cubieboard4)
#   WIFI_SSID=MyNetwork    — pre-configure WiFi (requires WIFI_PASSWORD)
#   WIFI_PASSWORD=secret    — WPA2 passphrase for WIFI_SSID
#
# Produces: alpine-rootfs/
# Consumed by: scripts/assemble-sd-image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/alpine-rootfs"
KERNEL_BUILD="${REPO_ROOT}/build/kernel"
MODULES_DIR="${KERNEL_BUILD}/modules"
ARCH="armhf"
ALPINE_VERSION="3.20.9"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"

BOARD_HOSTNAME="${BOARD_HOSTNAME:-cubieboard4}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

echo "========================================"
echo "Alpine Linux ${ALPINE_VERSION} Rootfs Build"
echo "========================================"
echo "    Hostname: ${BOARD_HOSTNAME}"
echo "    WiFi SSID: ${WIFI_SSID:-<not set>}"
echo "    Output: ${SYSROOT}"
echo ""

mkdir -p "${SYSROOT}"
mkdir -p "${REPO_ROOT}/build/sources"

# ── Download and extract Alpine mini rootfs ─────────────────────────────────────

ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
ALPINE_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/${ALPINE_TARBALL}"

echo "==> Downloading Alpine minirootfs..."
if [[ ! -f "${REPO_ROOT}/build/sources/${ALPINE_TARBALL}" ]]; then
    wget -q -O "${REPO_ROOT}/build/sources/${ALPINE_TARBALL}" "${ALPINE_URL}" || \
        die "Failed to download Alpine rootfs"
fi

echo "==> Extracting to ${SYSROOT}..."
tar -xzf "${REPO_ROOT}/build/sources/${ALPINE_TARBALL}" -C "${SYSROOT}" --strip-components=1

# ── Install qemu-user-static for running armhf binaries on x86_64 ──────────────────

if ! command -v qemu-arm-static &> /dev/null; then
    echo "==> Installing qemu-user-static..."
    apt-get update && apt-get install -y qemu-user-static || die "Failed to install qemu-user-static"
fi

# Copy qemu binary to rootfs for chroot
cp /usr/bin/qemu-arm-static "${SYSROOT}/usr/bin/" 2>/dev/null || true

# Copy musl libraries for qemu to find
mkdir -p /lib/arm-linux-gnueabihf
cp -a "${SYSROOT}"/lib/* /lib/arm-linux-gnueabihf/ 2>/dev/null || true

# ── Setup APK package manager ────────────────────────────────────────────────

mkdir -p "${SYSROOT}/etc/apk"
cat > "${SYSROOT}/etc/apk/repositories" <<EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

# ── Install base packages ─────────────────────────────────────────────────────

echo "==> Installing base packages..."
# Run apk with QEMU - need to set up proper library path
export QEMU_LD_PREFIX="${SYSROOT}"
"${SYSROOT}/sbin/apk" add --no-cache --root "${SYSROOT}" \
    alpine-base \
    openssh \
    sudo \
    doas \
    wpa_supplicant \
    wifi \
    iw \
    dhcpcd \
    dnsmasq \
    bash \
    coreutils \
    util-linux \
    e2fsprogs \
    dosfstools \
    udev \
    udev-init-scripts \
    libusb \
    pciutils \
    usbutils \
    kmod \
    linux-firmware-brcm \
    bluez \
    bluez-deprecated \
    dbus \
    polkit \
    neovim \
    git \
    curl \
    wget \
    rsync \
    htop \
    btop \
    tmux \
    chrony

# ── Install wireless firmware for brcmfmac (AP6330) ────────────────────────────

echo "==> Installing WiFi firmware..."
"${APK}" add --no-cache linux-firmware-brcm

# ── Configure hostname ──────────────────────────────────────────────────────────

echo "==> Configuring hostname..."
echo "${BOARD_HOSTNAME}" > "${SYSROOT}/etc/hostname"
cat > "${SYSROOT}/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  ${BOARD_HOSTNAME}
::1        localhost ip6-localhost ip6-loopback
EOF

# ── Configure network ───────────────────────────────────────────────────────────

mkdir -p "${SYSROOT}/etc/network"

cat > "${SYSROOT}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# ── WiFi configuration ─────────────────────────────────────────────────────────

if [[ -n "${WIFI_SSID}" ]]; then
    echo "==> Configuring WiFi: ${WIFI_SSID}"
    mkdir -p "${SYSROOT}/etc/wpa_supplicant"
    
    cat > "${SYSROOT}/etc/wpa_supplicant/wpa_supplicant.conf" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASSWORD}"
}
EOF

    cat > "${SYSROOT}/etc/init.d/wifi" <<EOF
#!/bin/sh
NAME=wifi
DESC="WiFi configuration"

start() {
    echo "Starting WiFi..."
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
    sleep 2
    udhcpc -i wlan0
}

stop() {
    echo "Stopping WiFi..."
    killall wpa_supplicant 2>/dev/null || true
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    *) echo "Usage: \$0 {start|stop|restart}" ;;
esac
EOF
    chmod +x "${SYSROOT}/etc/init.d/wifi"
fi

# ── Configure serial console ───────────────────────────────────────────────────

echo "==> Configuring serial console..."
mkdir -p "${SYSROOT}/etc/init.d"
cat > "${SYSROOT}/etc/init.d/serial" <<EOF
#!/bin/sh
NAME=serial
DESC="Serial console"

start() {
    echo "Starting serial console..."
    getty -L 115200 ttyS0 vt100 &
}

stop() {
    true
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    *) echo "Usage: \$0 {start|stop}" ;;
esac
EOF
chmod +x "${SYSROOT}/etc/init.d/serial"

# ── Enable services ────────────────────────────────────────────────────────────

echo "==> Enabling services..."
mkdir -p "${SYSROOT}/etc/runlevels/default"
ln -sf /etc/init.d/Networking "${SYSROOT}/etc/runlevels/default/networking"
ln -sf /etc/init.d/dhcpcd "${SYSROOT}/etc/runlevels/default/dhcpcd"
ln -sf /etc/init.d/serial "${SYSROOT}/etc/runlevels/default/serial"
ln -sf /etc/init.d/sshd "${SYSROOT}/etc/runlevels/default/sshd"

# ── Create default user ────────────────────────────────────────────────────────

echo "==> Creating default user..."
mkdir -p "${SYSROOT}/home/root"
adduser -D -s /bin/bash root || true

# ── Install kernel modules ───────────────────────────────────────────────────

if [[ -d "${MODULES_DIR}" ]]; then
    echo "==> Installing kernel modules..."
    rsync -a "${MODULES_DIR}/" "${SYSROOT}/"
fi

# ── Fix permissions ───────────────────────────────────────────────────────────

echo "==> Fixing permissions..."
chmod 755 "${SYSROOT}"
chmod 700 "${SYSROOT}/root"

echo ""
echo "==> Alpine Linux ${ALPINE_VERSION} rootfs ready at: ${SYSROOT}"
echo "    Hostname: ${BOARD_HOSTNAME}"
echo "    WiFi SSID: ${WIFI_SSID:-<not set>}"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
