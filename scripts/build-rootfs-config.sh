#!/bin/bash
# build-rootfs-config.sh — Configure system settings in Debian rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   scripts/build-rootfs-debootstrap.sh must have been run
#   scripts/build-rootfs-packages.sh should have been run
#
# Environment variables:
#   HOSTNAME=myboard      — set board hostname (default: cubieboard4)
#   WIFI_SSID=MyNetwork   — pre-configure WiFi (requires WIFI_PASSWORD)
#   WIFI_PASSWORD=secret  — WPA2 passphrase for WIFI_SSID
#
# Produces: fully configured debian-rootfs/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"
KERNEL_BUILD="${REPO_ROOT}/build/kernel"
MODULES_DIR="${KERNEL_BUILD}/modules"

HOSTNAME="${HOSTNAME:-cubieboard4}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -d "${SYSROOT}" ]] || die "Rootfs not found — run scripts/build-rootfs-debootstrap.sh first"

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

echo "==> Setting hostname to ${HOSTNAME}..."
echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
# Remove machine-id so systemd regenerates it (prevents hostname conflicts)
rm -f "${SYSROOT}/etc/machine-id"
touch "${SYSROOT}/etc/machine-id"

# ── /etc/hosts ───────────────────────────────────────────────────────────

cat > "${SYSROOT}/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  ${HOSTNAME}
::1        localhost ip6-localhost ip6-loopback
EOF

# ── Locale ───────────────────────────────────────────────────────────────

if ! grep -q "en_US.UTF-8 UTF-8" "${SYSROOT}/etc/locale.gen" 2>/dev/null; then
    echo "==> Configuring locale..."
    echo "en_US.UTF-8 UTF-8" >> "${SYSROOT}/etc/locale.gen"
    chroot "${SYSROOT}" locale-gen
else
    echo "    Locale already configured."
fi

# ── Timezone ─────────────────────────────────────────────────────────────

if [[ "$(cat "${SYSROOT}/etc/timezone" 2>/dev/null)" != "UTC" ]]; then
    echo "==> Setting timezone to UTC..."
    echo "UTC" > "${SYSROOT}/etc/timezone"
    chroot "${SYSROOT}" dpkg-reconfigure -f noninteractive tzdata || true
else
    echo "    Timezone already set to UTC."
fi

# ── /etc/fstab ──────────────────────────────────────────────────────────

cat > "${SYSROOT}/etc/fstab" <<EOF
/dev/mmcblk0p2  /      ext4  defaults,noatime  0  1
/dev/mmcblk0p1  /boot  vfat  defaults          0  2
tmpfs           /tmp   tmpfs defaults,nosuid,nodev  0 0
EOF

# ── Serial console ──────────────────────────────────────────────────────

if [[ ! -L "${SYSROOT}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" ]]; then
    echo "==> Enabling serial console..."
    chroot "${SYSROOT}" systemctl enable serial-getty@ttyS0.service || true
else
    echo "    Serial console already enabled."
fi

# ── SSH ──────────────────────────────────────────────────────────────────

if ! grep -q "^PermitRootLogin yes" "${SYSROOT}/etc/ssh/sshd_config" 2>/dev/null; then
    echo "==> Configuring sshd..."
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${SYSROOT}/etc/ssh/sshd_config"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${SYSROOT}/etc/ssh/sshd_config"
    chroot "${SYSROOT}" systemctl enable ssh.service || true
else
    echo "    SSH already configured."
fi

# ── NTP ───────────────────────────────────────────────────────────────────

if [[ ! -L "${SYSROOT}/etc/systemd/system/systemd-timesyncd.service" ]]; then
    echo "==> Enabling NTP..."
    chroot "${SYSROOT}" systemctl enable systemd-timesyncd.service || true
else
    echo "    NTP already enabled."
fi

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

BRCM_DIR="${SYSROOT}/usr/lib/firmware/brcm"
mkdir -p "${BRCM_DIR}"
if [[ -f "${BRCM_DIR}/brcmfmac4330-sdio.Prowise-PT301.txt" ]]; then
    if [[ ! -L "${BRCM_DIR}/brcmfmac4330-sdio.cubietech,a80-cubieboard4.txt" ]]; then
        echo "==> Creating BCM4330 firmware symlinks..."
        ln -sf brcmfmac4330-sdio.Prowise-PT301.txt \
            "${BRCM_DIR}/brcmfmac4330-sdio.cubietech,a80-cubieboard4.txt"
        for ext in bin clm_blob txcap_blob; do
            if [[ -f "${BRCM_DIR}/brcmfmac4330-sdio.${ext}" ]]; then
                ln -sf "brcmfmac4330-sdio.${ext}" "${BRCM_DIR}/brcmfmac4330-sdio.cubietech,a80-cubieboard4.${ext}"
            fi
        done
    else
        echo "    BCM4330 firmware symlinks already exist."
    fi
else
    echo "    WARNING: brcmfmac4330-sdio.Prowise-PT301.txt not found."
fi

# ── Fix regulatory.db symlink ─────────────────────────────────────────────

if [[ -L "${SYSROOT}/lib/firmware/regulatory.db" ]]; then
    echo "==> Fixing regulatory.db and signature..."
    rm -f "${SYSROOT}/lib/firmware/regulatory.db" "${SYSROOT}/lib/firmware/regulatory.db.p7s"
    if [[ -f "${SYSROOT}/lib/firmware/regulatory.db-upstream" ]]; then
        cp "${SYSROOT}/lib/firmware/regulatory.db-upstream" "${SYSROOT}/lib/firmware/regulatory.db"
    fi
    if [[ -f "${SYSROOT}/lib/firmware/regulatory.db.p7s-upstream" ]]; then
        cp "${SYSROOT}/lib/firmware/regulatory.db.p7s-upstream" "${SYSROOT}/lib/firmware/regulatory.db.p7s"
    fi
fi

# ── Embed install-to-emmc.sh ──────────────────────────────────────────────

if [[ ! -f "${SYSROOT}/usr/local/sbin/install-to-emmc.sh" ]]; then
    echo "==> Embedding install-to-emmc.sh..."
    install -m 0755 "${SCRIPT_DIR}/install-to-emmc.sh" \
        "${SYSROOT}/usr/local/sbin/install-to-emmc.sh"
else
    echo "    install-to-emmc.sh already embedded."
fi

# ── Copy U-Boot binary to /boot ──────────────────────────────────────────

UBOOT_BIN="${REPO_ROOT}/build/uboot/u-boot-sunxi-with-spl.bin"
if [[ -f "${UBOOT_BIN}" ]]; then
    if [[ ! -f "${SYSROOT}/boot/u-boot-sunxi-with-spl.bin" ]]; then
        echo "==> Copying U-Boot to /boot..."
        install -m 0644 "${UBOOT_BIN}" "${SYSROOT}/boot/u-boot-sunxi-with-spl.bin"
    else
        echo "    U-Boot already in /boot."
    fi
else
    echo "    WARNING: ${UBOOT_BIN} not found."
fi

# ── Root password ────────────────────────────────────────────────────────

echo "==> Setting root password to 'root' (change after first boot!)"
# Use chpasswd with SHA512 (default in Debian)
chroot "${SYSROOT}" bash -c 'echo "root:root" | chpasswd'

# ── WiFi pre-configuration ──────────────────────────────────────────────

NM_DIR="${SYSROOT}/etc/NetworkManager/system-connections"
if [[ -n "${WIFI_SSID}" && -n "${WIFI_PASSWORD}" ]]; then
    if [[ -f "${NM_DIR}/wifi-preconfigured.nmconnection" ]]; then
        echo "==> WiFi already pre-configured (skipping)."
    else
        echo "==> Pre-configuring WiFi for SSID: ${WIFI_SSID}"
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
    fi
elif [[ -n "${WIFI_SSID}" || -n "${WIFI_PASSWORD}" ]]; then
    echo "    WARNING: Both WIFI_SSID and WIFI_PASSWORD must be set to pre-configure WiFi."
fi

# ── Cleanup ──────────────────────────────────────────────────────────────

rm -f "${SYSROOT}/usr/bin/qemu-arm-static"

echo ""
echo "==> Rootfs configuration complete."
echo "    HOSTNAME was: ${HOSTNAME}"
echo "    WIFI_SSID  was: ${WIFI_SSID:-<not set>}"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
