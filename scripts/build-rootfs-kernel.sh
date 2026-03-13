#!/bin/bash
# build-rootfs-kernel.sh — Install kernel modules into Debian rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   scripts/build-rootfs-debootstrap.sh must have been run
#   scripts/build-kernel.sh must have been run
#
# Environment variables:
#   REBUILD_KERNEL=true — reinstall kernel modules even if version matches
#
# Produces: debian-rootfs/ with kernel modules installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"
KERNEL_BUILD="${REPO_ROOT}/build/kernel"
MODULES_DIR="${KERNEL_BUILD}/modules"
REBUILD_KERNEL="${REBUILD_KERNEL:-false}"

KERNEL_MODULES_STAMP="${SYSROOT}/.kernel_modules_done"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -d "${SYSROOT}" ]] || die "Rootfs not found — run scripts/build-rootfs-debootstrap.sh first"
[[ -d "${KERNEL_BUILD}" ]] || die "build/kernel/ not found — run scripts/build-kernel.sh first"
[[ -f "${KERNEL_BUILD}/zImage" ]] || die "build/kernel/zImage not found — run scripts/build-kernel.sh first"

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

# Get current kernel version from build directory
if [[ -d "${MODULES_DIR}/lib/modules" ]]; then
    CURRENT_KERNEL_VERSION=$(ls "${MODULES_DIR}/lib/modules/" | head -1)
else
    die "No kernel modules found in ${MODULES_DIR}/lib/modules"
fi

# Get installed kernel version (if any)
if [[ -d "${SYSROOT}/usr/lib/modules" ]]; then
    INSTALLED_KERNEL_VERSION=$(ls "${SYSROOT}/usr/lib/modules/" 2>/dev/null | head -1)
else
    INSTALLED_KERNEL_VERSION=""
fi

echo "==> Current kernel version: ${CURRENT_KERNEL_VERSION}"
echo "==> Installed kernel version: ${INSTALLED_KERNEL_VERSION:-<none>}"

mount_chroot

# Check if we need to install/reinstall
if [[ "${CURRENT_KERNEL_VERSION}" == "${INSTALLED_KERNEL_VERSION}" && "${REBUILD_KERNEL}" != true ]]; then
    if [[ -f "${KERNEL_MODULES_STAMP}" ]]; then
        echo "==> Kernel modules already installed for ${CURRENT_KERNEL_VERSION} (skipping)."
        echo "    Set REBUILD_KERNEL=true to force reinstall."
    else
        echo "==> Kernel modules not stamped but version matches — installing stamp."
        touch "${KERNEL_MODULES_STAMP}"
    fi
else
    if [[ "${REBUILD_KERNEL}" == true ]]; then
        echo "==> REBUILD_KERNEL=true — reinstalling kernel modules."
    elif [[ "${INSTALLED_KERNEL_VERSION}" != "${CURRENT_KERNEL_VERSION}" ]]; then
        echo "==> Kernel version changed — reinstalling kernel modules."
    else
        echo "==> Installing kernel modules."
    fi

    # Remove old modules if version changed
    if [[ -n "${INSTALLED_KERNEL_VERSION}" && "${INSTALLED_KERNEL_VERSION}" != "${CURRENT_KERNEL_VERSION}" ]]; then
        echo "    Removing old modules for ${INSTALLED_KERNEL_VERSION}..."
        rm -rf "${SYSROOT}/usr/lib/modules/${INSTALLED_KERNEL_VERSION}"
    fi

    # Copy new modules
    echo "==> Installing kernel modules from ${MODULES_DIR}..."
    cp -a "${MODULES_DIR}/lib/modules" "${SYSROOT}/usr/lib/"
    
    # Run depmod
    chroot "${SYSROOT}" depmod -a "${CURRENT_KERNEL_VERSION}" || true

    touch "${KERNEL_MODULES_STAMP}"
    echo "    Kernel modules installed for ${CURRENT_KERNEL_VERSION}."
fi

echo ""
echo "==> Kernel modules stage complete. Run build-rootfs-config.sh next."
