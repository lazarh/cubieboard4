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
        patch -N -d "${UBOOT_SRC}" -p1 < "${patch}" || true
    done

    # Fix pylibfdt setup.py for SWIG >= 4.2 compatibility.
    # SWIG 4.2 changed SWIG_Python_AppendOutput from 2 to 3 arguments, but
    # the libfdt.i typemaps in U-Boot 2024.01 still generate 2-arg call
    # sites. Override build_ext.swig_sources() to fix the calls after SWIG
    # generates libfdt_wrap.c so the C compiler is happy.
    echo "==> Patching pylibfdt setup.py for SWIG >= 4.2 compatibility..."
    python3 - "${UBOOT_SRC}/scripts/dtc/pylibfdt/setup.py" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Idempotency: skip if already patched
if 'build_ext as _build_ext' in src:
    sys.exit(0)

# 1. Add build_ext import
src = src.replace(
    'from setuptools.command.build_py import build_py as _build_py',
    'from setuptools.command.build_py import build_py as _build_py\n'
    'from setuptools.command.build_ext import build_ext as _build_ext'
)

# 2. Build the regex strings explicitly to avoid escape-sequence issues
# inside triple-quoted strings. Written verbatim to the file.
re_pattern = "r'SWIG_Python_AppendOutput" + r"\(" + r"([^,)]+),\s*([^,)]+)" + r"\)'"
re_replace = "r'SWIG_Python_AppendOutput(" + r"\1" + ", " + r"\2" + ", 0)'"

swig_fix_class = (
    '\nclass build_ext(_build_ext):\n'
    '    """Post-process SWIG wrapper for SWIG >= 4.2 compatibility.\n\n'
    '    SWIG 4.2 changed SWIG_Python_AppendOutput to require a third\n'
    '    argument (is_void), but libfdt.i still emits 2-argument calls.\n'
    '    """\n'
    '    def swig_sources(self, sources, extension):\n'
    '        result = super().swig_sources(sources, extension)\n'
    '        for wrap in result:\n'
    '            if not wrap.endswith("_wrap.c"):\n'
    '                continue\n'
    '            with open(wrap) as f:\n'
    '                content = f.read()\n'
    '            fixed = re.sub(\n'
    '                ' + re_pattern + ',\n'
    '                ' + re_replace + ',\n'
    '                content,\n'
    '            )\n'
    '            if fixed != content:\n'
    '                with open(wrap, "w") as f:\n'
    '                    f.write(fixed)\n'
    '        return result\n\n'
)

src = src.replace('setup(\n', swig_fix_class + 'setup(\n', 1)

# 3. Register in cmdclass
src = src.replace(
    "cmdclass = {'build_py' : build_py},",
    "cmdclass = {'build_py' : build_py, 'build_ext': build_ext},"
)

with open(path, 'w') as f:
    f.write(src)
print("    setup.py patched successfully.")
PYEOF

    touch "${PATCH_STAMP}"
fi

# ── Configure ─────────────────────────────────────────────────────────────

echo "==> Configuring U-Boot (Cubieboard4_defconfig)..."
make -C "${UBOOT_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    Cubieboard4_defconfig

# ── Build ──────────────────────────────────────────────────────────────────

echo "==> Building U-Boot (-j${JOBS})..."
make -C "${UBOOT_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
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
