#!/bin/bash
# build-kernel.sh — Download, configure, and cross-compile the Linux kernel
#                   for CubieBoard4 (Allwinner A80 / sun9i).
#
# Produces:
#   build/kernel/zImage                           — compressed kernel image
#   build/kernel/sun9i-a80-cubieboard4.dtb        — device tree blob
#   build/kernel/modules/                         — kernel modules
#
# Requires: gcc-arm-linux-gnueabihf, make, bc, flex, bison, libssl-dev, libncurses-dev
# Run: scripts/install-deps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL_VERSION="6.18.18"
KRELEASE="6"
KERNEL_URL="https://www.kernel.org/pub/linux/kernel/v${KRELEASE}.x/linux-${KERNEL_VERSION}.tar.xz"
# SHA256 of linux-6.18.18.tar.xz; leave empty to skip verification.
# After first download, record it with: sha256sum build/sources/linux-6.18.18.tar.xz
KERNEL_SHA256=""

# Set to false to skip applying patches (useful for testing upstream versions)
APPLY_KERNEL_PATCHES="false"

CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
ARCH=arm
JOBS="${JOBS:-$(nproc)}"

BUILD_DIR="${REPO_ROOT}/build/kernel"
MODULES_DIR="${BUILD_DIR}/modules"
SOURCES_DIR="${REPO_ROOT}/build/sources"
KERNEL_SRC="${SOURCES_DIR}/linux-${KERNEL_VERSION}"
CONFIG_FRAGMENT="${REPO_ROOT}/configs/kernel/cubieboard4.config"
PATCHES_DIR="${REPO_ROOT}/patches/kernel"
PATCH_STAMP="${KERNEL_SRC}/.patched"

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

command -v "${CROSS_COMPILE}gcc" >/dev/null || die "${CROSS_COMPILE}gcc not found — run scripts/install-deps.sh"

mkdir -p "${BUILD_DIR}" "${MODULES_DIR}" "${SOURCES_DIR}"

# ── Download ───────────────────────────────────────────────────────────────

TARBALL="${SOURCES_DIR}/linux-${KERNEL_VERSION}.tar.xz"
if [[ ! -f "${TARBALL}" ]]; then
    echo "==> Downloading Linux ${KERNEL_VERSION}..."
    curl -fL --progress-bar "${KERNEL_URL}" -o "${TARBALL}"
fi

echo "==> Verifying checksum..."
if [[ -n "${KERNEL_SHA256}" ]]; then
    echo "${KERNEL_SHA256}  ${TARBALL}" | sha256sum -c -
else
    echo "    Checksum not set — skipping verification."
    echo "    SHA256: $(sha256sum "${TARBALL}" | cut -d' ' -f1)"
fi

# ── Extract ────────────────────────────────────────────────────────────────

if [[ ! -d "${KERNEL_SRC}" ]]; then
    echo "==> Extracting kernel source..."
    tar -xJf "${TARBALL}" -C "${SOURCES_DIR}"
fi

# ── Apply patches ──────────────────────────────────────────────────────────

if [[ "${APPLY_KERNEL_PATCHES}" == true ]]; then
    if [[ ! -f "${PATCH_STAMP}" ]]; then
        echo "==> Applying kernel patches..."
        for p in "${PATCHES_DIR}"/*.patch; do
            [[ -f "${p}" ]] || continue
            echo "    Applying $(basename "${p}")..."
            patch -N -r /dev/null -p1 -d "${KERNEL_SRC}" < "${p}" || true
        done
        touch "${PATCH_STAMP}"
        echo "    Patches applied."
    fi
else
    echo "==> Skipping patches (APPLY_KERNEL_PATCHES=false)"
fi

# ── Configure ─────────────────────────────────────────────────────────────

echo "==> Applying sunxi_defconfig..."
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    sunxi_defconfig

echo "==> Merging CubieBoard4 config fragment..."
"${KERNEL_SRC}/scripts/kconfig/merge_config.sh" \
    -m -O "${BUILD_DIR}" \
    "${BUILD_DIR}/.config" \
    "${CONFIG_FRAGMENT}"

# Re-run olddefconfig to resolve any new symbols introduced by the fragment
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    olddefconfig

# ── Build kernel image, DTBs, and modules ─────────────────────────────────

echo "==> Building kernel (-j${JOBS})..."
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    -j"${JOBS}" \
    zImage dtbs modules

# ── Install modules ────────────────────────────────────────────────────────

echo "==> Installing modules to ${MODULES_DIR}..."
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    INSTALL_MOD_PATH="${MODULES_DIR}" \
    modules_install

# Remove build/source symlinks (not needed on target and contain host paths)
find "${MODULES_DIR}" -name "build" -o -name "source" | xargs rm -f 2>/dev/null || true

# ── Copy artifacts ─────────────────────────────────────────────────────────

cp "${BUILD_DIR}/arch/arm/boot/zImage" "${BUILD_DIR}/zImage"
cp "${BUILD_DIR}/arch/arm/boot/dts/allwinner/sun9i-a80-cubieboard4.dtb" "${BUILD_DIR}/"

echo ""
echo "==> Kernel build complete."
echo "    zImage : ${BUILD_DIR}/zImage"
echo "    DTB    : ${BUILD_DIR}/sun9i-a80-cubieboard4.dtb"
echo "    Modules: ${BUILD_DIR}/modules/"
echo "    Next step: sudo scripts/build-rootfs.sh"
