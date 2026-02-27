#!/bin/bash
# Install all host dependencies required for the Yocto CubieBoard4 build
# and the Debian 13 rootfs / image assembly scripts.
set -e

sudo apt install -y \
  gawk wget git diffstat unzip texinfo gcc build-essential \
  chrpath socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
  iputils-ping python3-git python3-jinja2 python3-subunit zstd liblz4-tool \
  file locales libacl1 lz4 bc swig flex bison libssl-dev

# Additional tools for debootstrap-based Debian rootfs and image assembly
sudo apt install -y \
  qemu-user-static binfmt-support debootstrap \
  parted dosfstools rsync e2fsprogs

echo "All host dependencies installed."
echo ""
echo "Build steps:"
echo "  1. kas build kas.yml          # build kernel + U-Boot"
echo "  2. sudo scripts/build-debian-rootfs.sh   # create Debian 13 rootfs"
echo "  3. sudo scripts/assemble-sd-image.sh     # assemble .img.gz"
