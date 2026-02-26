# Yocto Build for CubieBoard4 (CC-A80)

Yocto Scarthgap (5.0 LTS) build for the CubieBoard4 based on Allwinner A80 (sun9i).

## Prerequisites

Install `kas`:

```sh
pip install kas
```

Install Yocto host dependencies (Debian/Ubuntu):

```sh
sudo apt install gawk wget git diffstat unzip texinfo gcc build-essential \
  chrpath socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
  iputils-ping python3-git python3-jinja2 python3-subunit zstd liblz4-tool \
  file locales libacl1 lz4 bc swig flex bison libssl-dev
```

## Build

Fetch all layers and start the build:

```sh
kas build kas.yml
```

The first build takes a long time (hours) as it compiles the full toolchain, U-Boot,
kernel, and rootfs from source.

The output image will be at:

```
build/tmp/deploy/images/cubieboard4/core-image-minimal-cubieboard4.wic.gz
```

## Flashing

Write the WIC image to a microSD card (replace `/dev/sdX`):

```sh
bmaptool copy build/tmp/deploy/images/cubieboard4/core-image-minimal-cubieboard4.wic.gz /dev/sdX
```

Or with plain dd:

```sh
zcat build/tmp/deploy/images/cubieboard4/core-image-minimal-cubieboard4.wic.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

## Layer Overview

| Layer              | Purpose                        |
|--------------------|--------------------------------|
| meta               | Yocto core (poky)              |
| meta-oe, meta-python | OpenEmbedded extras          |
| meta-arm           | ARM architecture tunings       |
| meta-sunxi         | Allwinner SoC BSP              |
| meta-cubieboard4   | CubieBoard4 machine config     |
