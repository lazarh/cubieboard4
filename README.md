# Yocto + Debian 13 Image for CubieBoard4 (CC-A80)

Builds a minimal **Debian 13 (trixie, armhf)** image for the CubieBoard4 (Allwinner A80 / sun9i).

- **Yocto Scarthgap (5.0 LTS)** compiles the bootloader (U-Boot) and Linux kernel.
- **debootstrap** creates the Debian 13 rootfs with Docker CE pre-installed.
- A helper script copies the OS from the SD card to the internal eMMC.

## Hardware support

| Peripheral | Status | Notes |
|------------|--------|-------|
| Ethernet (GMAC RGMII) | ✅ | Enabled in DTS; managed by NetworkManager |
| WiFi (BCM4330 / AP6330) | ✅ | `firmware-brcm80211`, `wpasupplicant` |
| Internal eMMC (`mmc2`) | ✅ | 8-bit bus; `install-to-emmc.sh` writes the OS |
| SD card (`mmc0`) | ✅ | Boot source |
| Docker CE (armhf) | ✅ | Runs `linux/arm/v7` container images |

> **Docker note:** The board is 32-bit ARMv7. Only container images built for
> `linux/arm/v7` will run. Most modern `arm64`-only images will not work.

## Quick start (fresh machine)

```sh
git clone https://github.com/lazarh/cubieboard4.git && cd cubieboard4
sudo bash install-deps.sh                 # installs deps + kas via pipx
kas build kas.yml                         # build kernel + U-Boot (hours, first time)
sudo bash scripts/build-debian-rootfs.sh  # bootstrap Debian 13 rootfs (needs internet)
sudo bash scripts/assemble-sd-image.sh    # produce cubieboard4-debian13.img.gz
```

## Prerequisites

Install all host dependencies (including `kas`) in one shot:

```sh
sudo bash install-deps.sh
```

This installs Yocto build tools, the debootstrap toolchain
(`qemu-user-static`, `debootstrap`, `parted`, `dosfstools`, `rsync`),
and `kas` via `pipx` (safe on modern Debian/Ubuntu with PEP 668).

Requires a **Debian/Ubuntu x86-64** build host with internet access.

## Build

### Step 1 — Build kernel and U-Boot with Yocto

```sh
kas build kas.yml
```

This compiles U-Boot and the Linux kernel (with Docker-compatible config).
Artifacts land in `build/tmp/deploy/images/cubieboard4/`.
The first build takes a long time (hours) as it compiles the full toolchain from source.

### Step 2 — Bootstrap the Debian 13 rootfs

```sh
sudo scripts/build-debian-rootfs.sh
```

Runs `debootstrap` via QEMU to create `debian-rootfs/` on the build host.
Installs Docker CE, WiFi firmware, NetworkManager, and the eMMC installer script.
**Requires internet access** (pulls Debian and Docker packages).

### Step 3 — Assemble the SD card image

```sh
sudo scripts/assemble-sd-image.sh
```

Produces `cubieboard4-debian13.img.gz` (≈ 3 GiB uncompressed).

## Flashing

Write the image to a microSD card (replace `/dev/sdX`):

```sh
bmaptool copy cubieboard4-debian13.img.gz /dev/sdX
```

Or with plain `dd`:

```sh
zcat cubieboard4-debian13.img.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

## First boot

1. Insert the SD card and power on.
2. Log in as `root` with password `root`.  **Change it immediately with `passwd`.**
3. Connect to the network (Ethernet auto-configures via DHCP; for WiFi see below).

### WiFi setup

```sh
nmcli dev wifi connect "MySSID" password "MyPassword"
```

### Verify Docker

```sh
systemctl status docker
docker run --rm hello-world
```

## Install OS to internal eMMC

Once the system is running from SD card:

```sh
sudo install-to-emmc.sh
```

This partitions the eMMC, flashes U-Boot, and copies the full rootfs.
After it finishes, power off, **remove the SD card**, and boot — U-Boot will
automatically boot from eMMC.

## Layer Overview

| Layer              | Purpose                        |
|--------------------|--------------------------------|
| meta               | Yocto core (poky)              |
| meta-oe, meta-python | OpenEmbedded extras          |
| meta-arm           | ARM architecture tunings       |
| meta-sunxi         | Allwinner SoC BSP              |
| meta-cubieboard4   | CubieBoard4 machine config + Docker kernel config |
