#!/bin/bash
# build-uboot.sh — Download, patch, and cross-compile U-Boot for CubieBoard4.
#
# Produces:
#   build/uboot/u-boot-sunxi-with-spl.bin  — flash to SD/eMMC at 8 KiB offset
#   build/uboot/boot.scr                   — U-Boot boot script (from boot/boot.cmd)
#
# Requires: gcc-arm-linux-gnueabihf, make, bc, flex, bison, libssl-dev, u-boot-tools
# Run: scripts/install-deps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

UBOOT_VERSION="2024.01"
UBOOT_URL="https://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VERSION}.tar.bz2"
# SHA256 of u-boot-2024.01.tar.bz2; leave empty to skip verification.
# After first download, record it with: sha256sum build/sources/u-boot-2024.01.tar.bz2
UBOOT_SHA256=""

CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
ARCH=arm
JOBS="${JOBS:-$(nproc)}"

BUILD_DIR="${REPO_ROOT}/build/uboot"
SOURCES_DIR="${REPO_ROOT}/build/sources"
UBOOT_SRC="${SOURCES_DIR}/u-boot-${UBOOT_VERSION}"
PATCHES_DIR="${REPO_ROOT}/patches/uboot"

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

command -v "${CROSS_COMPILE}gcc" >/dev/null || die "${CROSS_COMPILE}gcc not found — run scripts/install-deps.sh"
command -v mkimage >/dev/null || die "mkimage not found — install u-boot-tools"

mkdir -p "${BUILD_DIR}" "${SOURCES_DIR}"

# ── Download ───────────────────────────────────────────────────────────────

TARBALL="${SOURCES_DIR}/u-boot-${UBOOT_VERSION}.tar.bz2"
if [[ ! -f "${TARBALL}" ]]; then
    echo "==> Downloading U-Boot ${UBOOT_VERSION}..."
    curl -fL --progress-bar "${UBOOT_URL}" -o "${TARBALL}"
fi

if [[ -n "${UBOOT_SHA256}" ]]; then
    echo "==> Verifying checksum..."
    echo "${UBOOT_SHA256}  ${TARBALL}" | sha256sum -c -
else
    echo "==> Checksum not set — skipping verification."
    echo "    SHA256: $(sha256sum "${TARBALL}" | cut -d' ' -f1)"
fi

# ── Extract ────────────────────────────────────────────────────────────────

if [[ ! -d "${UBOOT_SRC}" ]]; then
    echo "==> Extracting U-Boot..."
    tar -xjf "${TARBALL}" -C "${SOURCES_DIR}"
fi

# ── Apply patches ──────────────────────────────────────────────────────────

PATCH_STAMP="${UBOOT_SRC}/.patched"
if [[ ! -f "${PATCH_STAMP}" ]]; then
    echo "==> Applying patches..."
    for patch in "${PATCHES_DIR}"/*.patch; do
        [[ -f "${patch}" ]] || continue
        echo "    Applying: $(basename "${patch}")"
        patch -d "${UBOOT_SRC}" -p1 < "${patch}"
    done
    touch "${PATCH_STAMP}"
fi

# ── Configure ─────────────────────────────────────────────────────────────

echo "==> Configuring U-Boot (Cubieboard4_defconfig)..."
make -C "${UBOOT_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    PYTHON=nopython PYTHON3=nopython3 \
    Cubieboard4_defconfig

# ── Build ──────────────────────────────────────────────────────────────────
# PYTHON/PYTHON3 are set to a non-existent binary to skip building the
# pylibfdt Python bindings, which fail with SWIG >= 4.2 in U-Boot 2024.01.
echo "==> Building U-Boot (-j${JOBS})..."
make -C "${UBOOT_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    PYTHON=nopython PYTHON3=nopython3 \
    -j"${JOBS}"

echo "==> U-Boot binary: ${BUILD_DIR}/u-boot-sunxi-with-spl.bin"

# ── Generate boot.scr ──────────────────────────────────────────────────────

echo "==> Generating boot.scr from boot/boot.cmd..."
mkimage -C none -A arm -T script \
    -d "${REPO_ROOT}/boot/boot.cmd" \
    "${BUILD_DIR}/boot.scr"
echo "==> Boot script: ${BUILD_DIR}/boot.scr"

echo ""
echo "==> U-Boot build complete."
echo "    Artifacts in: ${BUILD_DIR}/"
echo "    Next step: scripts/build-kernel.sh"
