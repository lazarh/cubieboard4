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
# SHA256 of u-boot-2024.01.tar.bz2
UBOOT_SHA256="b99611f1ed237bf3541bdc8434b68c96a6e05967061f992443cb30aabebef5b3"

# Set to false to skip applying patches (useful for testing upstream versions)
APPLY_UBOOT_PATCHES="${APPLY_UBOOT_PATCHES:-true}"

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

if [[ "${APPLY_UBOOT_PATCHES}" == true ]]; then
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
import sys

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

# 2. Insert build_ext subclass that fixes 2-arg SWIG_Python_AppendOutput calls.
# SWIG 4.2 added a third argument (is_void=0 for normal calls), but
# U-Boot 2024.01's libfdt.i typemaps still emit 2-arg calls when processed by
# any SWIG version. We count parentheses to find each call's closing paren and
# add ', 0' when there are exactly 2 top-level arguments — safe for all nested
# patterns like SWIG_From_int(*arg), SWIG_NewPointerObj((void *)p, ...), etc.
swig_fix_class = '''
def _fix_swig_append_output(content):
    """Add missing third argument to all 2-arg SWIG_Python_AppendOutput calls."""
    marker = 'SWIG_Python_AppendOutput('
    out = []
    i = 0
    while i < len(content):
        idx = content.find(marker, i)
        if idx == -1:
            out.append(content[i:])
            break
        out.append(content[i:idx + len(marker)])
        j = idx + len(marker)
        depth = 1
        top_commas = 0
        while j < len(content) and depth > 0:
            c = content[j]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    break
            elif c == ',' and depth == 1:
                top_commas += 1
            j += 1
        # j points at the closing ')'
        inner = content[idx + len(marker):j]
        if top_commas == 1:   # 2 args -> add is_void=0
            out.append(inner + ', 0)')
        else:
            out.append(inner + ')')
        i = j + 1
    return ''.join(out)


class build_ext(_build_ext):
    """Post-process SWIG wrapper for SWIG >= 4.2 compatibility."""
    def swig_sources(self, sources, extension):
        result = super().swig_sources(sources, extension)
        for wrap in result:
            if not wrap.endswith('_wrap.c'):
                continue
            with open(wrap) as f:
                content = f.read()
            fixed = _fix_swig_append_output(content)
            if fixed != content:
                with open(wrap, 'w') as f:
                    f.write(fixed)
        return result

'''
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
else
    echo "==> Skipping patches (APPLY_UBOOT_PATCHES=false)"
fi

# ── Configure ─────────────────────────────────────────────────────────────

echo "==> Configuring U-Boot (Cubieboard4_defconfig)..."
make -C "${UBOOT_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    Cubieboard4_defconfig

# Override bootcmd: try eMMC (mmc 1) directly first, before any distro scan
# probes mmc0.  On A80 the voltage-select failure for a plain SD card
# corrupts the shared mmc_config_clk state and prevents eMMC init.
# Booting eMMC directly avoids touching mmc0 entirely.
# Fall back to distro_bootcmd for initial SD-card installs.
cat >> "${BUILD_DIR}/.config" << 'UBOOT_CFG'
CONFIG_BOOTCOMMAND="if mmc dev 1 && load mmc 1:1 ${fdt_addr_r} ${fdtfile}; then if load mmc 1:1 ${kernel_addr_r} zImage || load mmc 1:1 ${kernel_addr_r} boot/zImage; then setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/mmcblk2p2 rootwait panic=10 ${extra}; bootz ${kernel_addr_r} - ${fdt_addr_r}; fi; fi; run distro_bootcmd"
UBOOT_CFG

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
