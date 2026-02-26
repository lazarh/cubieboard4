#!/bin/bash
# Install all host dependencies required for the Yocto CubieBoard4 build
set -e

sudo apt install -y \
  gawk wget git diffstat unzip texinfo gcc build-essential \
  chrpath socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
  iputils-ping python3-git python3-jinja2 python3-subunit zstd liblz4-tool \
  file locales libacl1 lz4 bc swig flex bison libssl-dev

echo "All host dependencies installed. You can now run: kas build kas.yml"
