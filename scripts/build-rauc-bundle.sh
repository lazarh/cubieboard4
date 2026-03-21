#!/bin/bash
# build-rauc-bundle.sh — Create a signed RAUC update bundle (.raucb) for CubieBoard4.
#
# Prerequisites:
#   scripts/gen-rauc-cert.sh       — run once to generate the signing certificate
#   scripts/build-rootfs.sh        — rootfs must be built (ROOTFS_DISTRO=alpine)
#   scripts/build-kernel.sh        — kernel modules must be built
#   rauc                           — installed on the build host (apt install rauc)
#
# Usage:
#   scripts/build-rauc-bundle.sh
#   VERSION=20240101 scripts/build-rauc-bundle.sh
#   ROOTFS_DIR=/path/to/custom/rootfs scripts/build-rauc-bundle.sh
#
# Environment variables:
#   VERSION        — bundle version string  (default: YYYYMMDD-HHMMSS)
#   ROOTFS_DIR     — rootfs source dir      (default: alpine-rootfs/)
#   ROOTFS_SIZE_MB — ext4 image size in MiB (default: 1800)
#   OUTPUT_DIR     — where to write .raucb  (default: repo root)
#
# Output:
#   cubieboard4-<VERSION>.raucb   — signed RAUC update bundle

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="${VERSION:-$(date +%Y%m%d-%H%M%S)}"
ROOTFS_DIR="${ROOTFS_DIR:-${REPO_ROOT}/alpine-rootfs}"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-1800}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}}"

CERT_FILE="${REPO_ROOT}/configs/rauc/dev-cert/ca.cert.pem"
KEY_FILE="${REPO_ROOT}/configs/rauc/dev-cert/ca.key.pem"
COMPATIBLE="cubieboard4"

OUTPUT_BUNDLE="${OUTPUT_DIR}/cubieboard4-${VERSION}.raucb"

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
WORK_DIR=""

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        umount "${WORK_DIR}/mnt" 2>/dev/null || true
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

# ── Preflight ──────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must be run as root (needs loop device for ext4 image)"
[[ -d "${ROOTFS_DIR}" ]] || die "Rootfs not found: ${ROOTFS_DIR} — run scripts/build-rootfs.sh first"
[[ -f "${CERT_FILE}"  ]] || die "CA certificate not found: ${CERT_FILE} — run scripts/gen-rauc-cert.sh first"
[[ -f "${KEY_FILE}"   ]] || die "CA private key not found: ${KEY_FILE} — run scripts/gen-rauc-cert.sh first"

command -v rauc      >/dev/null || die "rauc not found on build host — apt install rauc"
command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 not found — apt install e2fsprogs"

echo "========================================"
echo "  CubieBoard4 RAUC Bundle Builder"
echo "========================================"
echo "  Version    : ${VERSION}"
echo "  Rootfs     : ${ROOTFS_DIR}"
echo "  Image size : ${ROOTFS_SIZE_MB} MiB"
echo "  Output     : ${OUTPUT_BUNDLE}"
echo "========================================"
echo ""

WORK_DIR=$(mktemp -d)
BUNDLE_STAGING="${WORK_DIR}/bundle"
mkdir -p "${BUNDLE_STAGING}" "${WORK_DIR}/mnt"

# ── Create rootfs ext4 image ───────────────────────────────────────────────

ROOTFS_IMG="${BUNDLE_STAGING}/rootfs.ext4"

echo "==> Creating ${ROOTFS_SIZE_MB} MiB ext4 rootfs image..."
fallocate -l "${ROOTFS_SIZE_MB}MiB" "${ROOTFS_IMG}"
mkfs.ext4 -L rootfs "${ROOTFS_IMG}"

LOOP_DEV=$(losetup --find --show "${ROOTFS_IMG}")
mount "${LOOP_DEV}" "${WORK_DIR}/mnt"

echo "==> Populating rootfs image from ${ROOTFS_DIR}..."
rsync -aAX --exclude=/proc --exclude=/sys --exclude=/dev \
           --exclude=/run  --exclude=/tmp --exclude=/boot \
           "${ROOTFS_DIR}/" "${WORK_DIR}/mnt/"

mkdir -p "${WORK_DIR}/mnt"/{proc,sys,dev,run,tmp,boot}
chmod 1777 "${WORK_DIR}/mnt/tmp"
sync

umount "${WORK_DIR}/mnt"
losetup -d "${LOOP_DEV}"

echo "==> Rootfs image created: ${ROOTFS_IMG}"

# ── Write RAUC manifest ────────────────────────────────────────────────────

cat > "${BUNDLE_STAGING}/manifest.raucm" <<EOF
[update]
compatible=${COMPATIBLE}
version=${VERSION}

[image.rootfs]
filename=rootfs.ext4
EOF

echo "==> Manifest written."

# ── Sign and create bundle ─────────────────────────────────────────────────

echo "==> Creating signed RAUC bundle..."
rauc bundle \
    --cert="${CERT_FILE}" \
    --key="${KEY_FILE}" \
    "${BUNDLE_STAGING}" \
    "${OUTPUT_BUNDLE}"

echo ""
echo "==> Bundle ready: ${OUTPUT_BUNDLE}"
echo "    Size: $(du -sh "${OUTPUT_BUNDLE}" | cut -f1)"
echo ""
echo "    Install on the board:"
echo "      rauc install https://your-server/$(basename "${OUTPUT_BUNDLE}")"
echo "      # or from local file:"
echo "      rauc install ${OUTPUT_BUNDLE}"
echo ""
echo "    Verify bundle:"
echo "      rauc info ${OUTPUT_BUNDLE}"
