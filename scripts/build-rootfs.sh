#!/bin/bash
# build-rootfs.sh — Orchestrator for building the Alpine rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# This script calls the following sub-scripts in sequence:
#   1. build-rootfs-alpine.sh  — Bootstrap Alpine
#   2. build-rootfs-kernel.sh  — Install kernel modules
#   3. build-rootfs-config.sh  — Configure system settings
#
# Environment variables:
#   FORCE_REBUILD=true  — delete all stamps and rebuild everything
#   REBUILD_KERNEL=true — reinstall kernel modules
#   BOARD_HOSTNAME=myboard — set board hostname (default: cubieboard4)
#   WIFI_SSID=MyNetwork — pre-configure WiFi (requires WIFI_PASSWORD)
#   WIFI_PASSWORD=secret — WPA2 passphrase for WIFI_SSID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sub-scripts require root)"

FORCE_REBUILD="${FORCE_REBUILD:-false}"
REBUILD_KERNEL="${REBUILD_KERNEL:-false}"

echo "========================================"
echo "  CubieBoard4 Rootfs Build Orchestrator"
echo "========================================"
echo "FORCE_REBUILD:    ${FORCE_REBUILD}"
echo "REBUILD_KERNEL:  ${REBUILD_KERNEL}"
echo "BOARD_HOSTNAME:   ${BOARD_HOSTNAME:-cubieboard4}"
echo "========================================"
echo ""

export BOARD_HOSTNAME="${BOARD_HOSTNAME:-cubieboard4}"
export WIFI_SSID="${WIFI_SSID:-}"
export WIFI_PASSWORD="${WIFI_PASSWORD:-}"

if [[ "${FORCE_REBUILD}" == true ]]; then
    export FORCE_REBUILD=true
fi

if [[ "${REBUILD_KERNEL}" == true ]]; then
    export REBUILD_KERNEL=true
fi

# Stage 1: Bootstrap
echo ">>> [1/3] Running build-rootfs-alpine.sh..."
"${SCRIPT_DIR}/build-rootfs-alpine.sh"

# Stage 2: Kernel modules
echo ">>> [2/3] Running build-rootfs-kernel.sh..."
"${SCRIPT_DIR}/build-rootfs-kernel.sh"

# Stage 3: Configuration
echo ">>> [3/3] Running build-rootfs-config.sh..."
"${SCRIPT_DIR}/build-rootfs-config.sh"

echo ""
echo "========================================"
echo "  Rootfs build complete!"
echo "========================================"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
