#!/bin/bash
# build-rootfs.sh — Orchestrator for building Debian rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# This script calls the following sub-scripts in sequence:
#   1. build-rootfs-debootstrap.sh   — Stage 1 & 2 debootstrap
#   2. build-rootfs-packages.sh    — Install packages
#   3. build-rootfs-kernel.sh       — Install kernel modules
#   4. build-rootfs-config.sh      — Configure system settings
#
# Environment variables:
#   FORCE_REBUILD=true    — delete all stamps and rebuild everything
#   REBUILD_PACKAGES=true — reinstall packages
#   REBUILD_KERNEL=true   — reinstall kernel modules
#   INSTALL_DOCKER=true   — include Docker CE (default: false)
#   HOSTNAME=myboard     — set board hostname (default: cubieboard4)
#   WIFI_SSID=MyNetwork  — pre-configure WiFi (requires WIFI_PASSWORD)
#   WIFI_PASSWORD=secret — WPA2 passphrase for WIFI_SSID
#
# Individual sub-scripts can also be run separately:
#   sudo scripts/build-rootfs-debootstrap.sh
#   sudo scripts/build-rootfs-packages.sh
#   sudo scripts/build-rootfs-kernel.sh
#   sudo scripts/build-rootfs-config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sub-scripts require root)"

FORCE_REBUILD="${FORCE_REBUILD:-false}"
REBUILD_PACKAGES="${REBUILD_PACKAGES:-false}"
REBUILD_KERNEL="${REBUILD_KERNEL:-false}"

echo "========================================"
echo "  CubieBoard4 Rootfs Build Orchestrator"
echo "========================================"
echo "FORCE_REBUILD:    ${FORCE_REBUILD}"
echo "REBUILD_PACKAGES: ${REBUILD_PACKAGES}"
echo "REBUILD_KERNEL:   ${REBUILD_KERNEL}"
echo "INSTALL_DOCKER:   ${INSTALL_DOCKER:-false}"
echo "HOSTNAME:         cubieboard4"
echo "========================================"
echo ""

# Export variables for sub-scripts
export INSTALL_DOCKER="${INSTALL_DOCKER:-false}"
# Use BOARD_HOSTNAME to avoid conflict with shell's HOSTNAME variable
export BOARD_HOSTNAME="cubieboard4"
export WIFI_SSID="${WIFI_SSID:-}"
export WIFI_PASSWORD="${WIFI_PASSWORD:-}"

if [[ "${FORCE_REBUILD}" == true ]]; then
    export FORCE_REBUILD=true
fi

if [[ "${REBUILD_PACKAGES}" == true ]]; then
    export REBUILD_PACKAGES=true
fi

if [[ "${REBUILD_KERNEL}" == true ]]; then
    export REBUILD_KERNEL=true
fi

# Stage 1: Debootstrap
echo ">>> [1/4] Running build-rootfs-debootstrap.sh..."
"${SCRIPT_DIR}/build-rootfs-debootstrap.sh"

# Stage 2: Packages
echo ">>> [2/4] Running build-rootfs-packages.sh..."
"${SCRIPT_DIR}/build-rootfs-packages.sh"

# Stage 3: Kernel modules
echo ">>> [3/4] Running build-rootfs-kernel.sh..."
"${SCRIPT_DIR}/build-rootfs-kernel.sh"

# Stage 4: Configuration
echo ">>> [4/4] Running build-rootfs-config.sh..."
"${SCRIPT_DIR}/build-rootfs-config.sh"

echo ""
echo "========================================"
echo "  Rootfs build complete!"
echo "========================================"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
