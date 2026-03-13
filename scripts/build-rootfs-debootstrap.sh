#!/bin/bash
# build-rootfs-debootstrap.sh — Stage 1 & 2 debootstrap for Debian rootfs.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Environment variables:
#   FORCE_REBUILD=true  — delete stamps and rebuild from scratch
#   SUITE=trixie        — Debian suite (default: trixie)
#   ARCH=armhf          — architecture (default: armhf)
#   MIRROR=...          — apt mirror (default: http://deb.debian.org/debian)
#
# Produces: debian-rootfs/ (with .stage1_done and .stage2_done stamps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"

ARCH="${ARCH:-armhf}"
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"

STAGE1_STAMP="${SYSROOT}/.stage1_done"
STAGE2_STAMP="${SYSROOT}/.stage2_done"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (debootstrap requires chroot)"
command -v debootstrap >/dev/null || die "debootstrap not found — run scripts/install-deps.sh"

mkdir -p "${SYSROOT}"

if [[ "${FORCE_REBUILD}" == true ]]; then
    echo "==> FORCE_REBUILD=true — removing existing rootfs and stamps..."
    rm -rf "${SYSROOT}"
    mkdir -p "${SYSROOT}"
fi

# ── Stage 1: debootstrap ────────────────────────────────────────────────────

if [[ -f "${STAGE1_STAMP}" ]]; then
    echo "==> Stage 1 already complete (skipping). Use FORCE_REBUILD=true to rebuild."
else
    echo "==> Stage 1: debootstrap ${SUITE} ${ARCH} into ${SYSROOT}"
    debootstrap \
        --arch="${ARCH}" \
        --foreign \
        --components=main,contrib,non-free,non-free-firmware \
        --include=ca-certificates,curl,gnupg,locales,apt-transport-https \
        "${SUITE}" "${SYSROOT}" "${MIRROR}"

    # Copy QEMU binary so the chroot can execute ARM binaries on x86
    cp /usr/bin/qemu-arm-static "${SYSROOT}/usr/bin/"

    touch "${STAGE1_STAMP}"
    echo "    Stage 1 complete."
fi

# ── Stage 2: second stage ──────────────────────────────────────────────────

if [[ -f "${STAGE2_STAMP}" ]]; then
    echo "==> Stage 2 already complete (skipping). Use FORCE_REBUILD=true to rebuild."
else
    echo "==> Stage 2: debootstrap second stage inside chroot"
    chroot "${SYSROOT}" /debootstrap/debootstrap --second-stage
    touch "${STAGE2_STAMP}"
    echo "    Stage 2 complete."
fi

echo ""
echo "==> Debootstrap complete. Run build-rootfs-packages.sh next."
