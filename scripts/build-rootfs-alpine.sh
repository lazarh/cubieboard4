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
ALPINE_RELEASE_DIR="${ALPINE_VERSION%.*}"   # e.g. 3.20 from 3.20.9
ALPINE_URL="${ALPINE_MIRROR}/v${ALPINE_RELEASE_DIR}/releases/${ARCH}/${ALPINE_TARBALL}"
ALPINE_CACHED="${REPO_ROOT}/build/sources/${ALPINE_TARBALL}"

echo "==> Downloading Alpine minirootfs..."
# Remove zero-byte or corrupt stub files left by failed previous downloads
if [[ -f "${ALPINE_CACHED}" && ! -s "${ALPINE_CACHED}" ]]; then
    echo "    Removing empty/corrupt cached file: ${ALPINE_CACHED}"
    rm -f "${ALPINE_CACHED}"
fi
if [[ ! -f "${ALPINE_CACHED}" ]]; then
    wget --show-progress -O "${ALPINE_CACHED}.tmp" "${ALPINE_URL}" \
        && mv "${ALPINE_CACHED}.tmp" "${ALPINE_CACHED}" \
        || { rm -f "${ALPINE_CACHED}.tmp"; die "Failed to download Alpine rootfs from ${ALPINE_URL}"; }
else
    echo "    Using cached ${ALPINE_CACHED}"
fi

echo "==> Extracting to ${SYSROOT}..."
tar -xzf "${ALPINE_CACHED}" -C "${SYSROOT}" --strip-components=1

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
# Use v3.20 instead of v3.20.9 - armhf repos are only at major.minor level
ALPINE_REPO_VERSION="${ALPINE_VERSION%.*}"
cat > "${SYSROOT}/etc/apk/repositories" <<EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_REPO_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_REPO_VERSION}/community
@edgetesting https://dl-cdn.alpinelinux.org/alpine/edge/testing
EOF
# Allow rauc to be pulled from edge/testing without upgrading everything else

# Pre-create /etc/machine-id — dbus post-install rejects an empty file.
# A first-boot service will regenerate a unique ID per device.
mkdir -p "${SYSROOT}/etc"
od -vN 16 -A n -t x1 /dev/urandom | tr -d ' \n' | head -c 32 > "${SYSROOT}/etc/machine-id"
echo >> "${SYSROOT}/etc/machine-id"

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
    dbus \
    polkit \
    neovim \
    git \
    curl \
    wget \
    rsync \
    htop \
    tmux \
    chrony \
    rauc@edgetesting \
    u-boot-tools

# ── Install wireless firmware for brcmfmac (AP6330) ────────────────────────────

echo "==> Installing WiFi firmware..."
"${SYSROOT}/sbin/apk" add --no-cache linux-firmware-brcm

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
# Alpine uses busybox init with /etc/inittab (not systemd/OpenRC for getty).
# The ttyS0 line exists but is commented out; uncomment it.

echo "==> Configuring serial console..."
if grep -q '^#.*ttyS0.*getty' "${SYSROOT}/etc/inittab" 2>/dev/null; then
    sed -i 's|^#\(.*ttyS0.*getty.*\)|\1|' "${SYSROOT}/etc/inittab"
elif ! grep -q '^ttyS0' "${SYSROOT}/etc/inittab" 2>/dev/null; then
    echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" >> "${SYSROOT}/etc/inittab"
fi

# ── Configure fstab (disable fsck for vfat) ───────────────────────────────────────

echo "==> Configuring fstab..."
cat > "${SYSROOT}/etc/fstab" <<EOF
/dev/mmcblk0p1  /boot   vfat    noauto,noatime          0 0
/dev/mmcblk0p2  /       ext4    defaults,noatime         0 0
tmpfs           /tmp    tmpfs   defaults,noatime         0 0
EOF

# ── Set root password ────────────────────────────────────────────────────────────

echo "==> Setting root password..."
chroot "${SYSROOT}" /bin/sh -c "echo 'root:cubie' | chpasswd"

# ── Enable services ────────────────────────────────────────────────────────────

echo "==> Enabling services..."

# sysinit — kernel interfaces and device manager
mkdir -p "${SYSROOT}/etc/runlevels/sysinit"
for svc in devfs dmesg hwdrivers mdev seedrng; do
    [[ -f "${SYSROOT}/etc/init.d/${svc}" ]] && \
        ln -sf /etc/init.d/${svc} "${SYSROOT}/etc/runlevels/sysinit/${svc}"
done

# boot — filesystem remount (rw), hostname, modules, misc
mkdir -p "${SYSROOT}/etc/runlevels/boot"
for svc in sysfs procfs fsck localmount modules swap sysctl bootmisc hostname klogd; do
    [[ -f "${SYSROOT}/etc/init.d/${svc}" ]] && \
        ln -sf /etc/init.d/${svc} "${SYSROOT}/etc/runlevels/boot/${svc}"
done

# default — user-space services
mkdir -p "${SYSROOT}/etc/runlevels/default"
for svc in networking dhcpcd sshd chronyd dbus; do
    [[ -f "${SYSROOT}/etc/init.d/${svc}" ]] && \
        ln -sf /etc/init.d/${svc} "${SYSROOT}/etc/runlevels/default/${svc}"
done
# Remove dangling serial symlink added by agetty-openrc post-install
rm -f "${SYSROOT}/etc/runlevels/default/serial"

# ── RAUC configuration ──────────────────────────────────────────────────────────

echo "==> Installing RAUC configuration..."
mkdir -p "${SYSROOT}/etc/rauc"

# Deploy system.conf from repo
cp "${REPO_ROOT}/configs/rauc/system.conf" "${SYSROOT}/etc/rauc/system.conf"

# Deploy CA certificate if it exists (must be generated first with gen-rauc-cert.sh)
RAUC_CERT="${REPO_ROOT}/configs/rauc/dev-cert/ca.cert.pem"
if [[ -f "${RAUC_CERT}" ]]; then
    cp "${RAUC_CERT}" "${SYSROOT}/etc/rauc/ca.cert.pem"
    echo "    Installed RAUC CA certificate."
else
    echo "    WARNING: ${RAUC_CERT} not found."
    echo "    Run scripts/gen-rauc-cert.sh to generate the dev certificate,"
    echo "    then re-run this script (or copy ca.cert.pem to /etc/rauc/ manually)."
fi

# fw_env.config: tells fw_printenv/fw_setenv where U-Boot env lives on eMMC.
# Must match CONFIG_ENV_OFFSET / CONFIG_ENV_SIZE in configs/uboot/rauc.config.
# /dev/mmcblk2 is the eMMC on CubieBoard4 (present only after install-to-emmc.sh).
mkdir -p "${SYSROOT}/etc"
cat > "${SYSROOT}/etc/fw_env.config" <<'EOF'
# Device        Offset      Env-size
# CubieBoard4 eMMC (/dev/mmcblk2), raw env at 4MiB
/dev/mmcblk2    0x400000    0x20000
EOF

# OpenRC service: mark the active RAUC slot as good after a successful boot.
# If this service never runs (e.g. boot crash), U-Boot decrements the attempt
# counter until it reaches 0 and automatically falls back to the other slot.
cat > "${SYSROOT}/etc/init.d/rauc-mark-good" <<'INITEOF'
#!/sbin/openrc-run

description="Mark active RAUC slot as good after successful boot"

depend() {
    after networking
    after logger
}

start() {
    ebegin "Marking RAUC slot as good"
    if command -v rauc >/dev/null 2>&1; then
        rauc status mark-good 2>&1 | logger -t rauc-mark-good || true
    else
        ewarn "rauc not found — skipping mark-good"
    fi
    eend 0
}
INITEOF
chmod +x "${SYSROOT}/etc/init.d/rauc-mark-good"
ln -sf /etc/init.d/rauc-mark-good \
    "${SYSROOT}/etc/runlevels/default/rauc-mark-good"
echo "    rauc-mark-good OpenRC service installed."

# OpenRC service: regenerate a unique machine-id on first boot.
# The build-time machine-id is a placeholder; each device gets its own.
cat > "${SYSROOT}/etc/init.d/machine-id" <<'INITEOF'
#!/sbin/openrc-run

description="Regenerate unique machine-id on first boot"

depend() {
    before dbus
    before networking
}

start() {
    ebegin "Checking machine-id"
    if [ ! -s /run/machine-id-committed ]; then
        dbus-uuidgen > /etc/machine-id.new \
            && mv /etc/machine-id.new /etc/machine-id \
            && touch /run/machine-id-committed
        einfo "New machine-id: $(cat /etc/machine-id)"
    else
        einfo "machine-id already set: $(cat /etc/machine-id)"
    fi
    eend 0
}
INITEOF
chmod +x "${SYSROOT}/etc/init.d/machine-id"
ln -sf /etc/init.d/machine-id "${SYSROOT}/etc/runlevels/boot/machine-id"
echo "    machine-id first-boot service installed."

# ── Create default user ────────────────────────────────────────────────────────

echo "==> Creating default user..."
mkdir -p "${SYSROOT}/home/root"

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
