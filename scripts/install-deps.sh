#!/bin/bash
# install-deps.sh — Install build host dependencies for CubieBoard4 cross-compilation.
#
# Run once on a Debian/Ubuntu x86-64 build host.
# Must be run as root (apt-get).

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: Must be run as root" >&2; exit 1; }

apt-get update -q
apt-get install -y --no-install-recommends \
    gcc-arm-linux-gnueabihf \
    binutils-arm-linux-gnueabihf \
    make \
    bc \
    bison \
    flex \
    libssl-dev \
    libncurses-dev \
    device-tree-compiler \
    u-boot-tools \
    debootstrap \
    qemu-user-static \
    binfmt-support \
    parted \
    dosfstools \
    e2fsprogs \
    rsync \
    pigz \
    bmap-tools \
    curl \
    wget \
    xz-utils \
    ca-certificates \
    git

echo ""
echo "==> All build dependencies installed."
echo "    Build order:"
echo "      1. scripts/build-uboot.sh"
echo "      2. scripts/build-kernel.sh"
echo "      3. sudo scripts/build-rootfs.sh"
echo "      4. sudo scripts/assemble-sd-image.sh"
