# CubieBoard4 — Standalone Build System

Build U-Boot, Linux kernel, and a Debian 13 (trixie) armhf root filesystem for the
[CubieBoard4](http://cubieboard.org/) (Allwinner A80 / sun9i, ARM Cortex-A15).

No Yocto required — everything is built via direct cross-compilation and `debootstrap`.

## Quick Start

### 1. Install build dependencies (once, as root)
```bash
sudo scripts/install-deps.sh
```

### 2. Build U-Boot
```bash
scripts/build-uboot.sh
```
Produces `build/uboot/u-boot-sunxi-with-spl.bin` and `build/uboot/boot.scr`.

### 3. Build the kernel
```bash
scripts/build-kernel.sh
```
Produces `build/kernel/zImage`, `build/kernel/sun9i-a80-cubieboard4.dtb`, and `build/kernel/modules/`.

### 4. Build the Debian rootfs (as root)
```bash
sudo scripts/build-rootfs.sh
```
Produces `debian-rootfs/`.

To also install Docker CE in the rootfs:
```bash
sudo INSTALL_DOCKER=true scripts/build-rootfs.sh
```

### 5. Assemble the SD card image (as root)
```bash
sudo scripts/assemble-sd-image.sh
```
Produces `cubieboard4-debian13.img.gz` (and `.bmap`).

### 6. Flash to SD card
```bash
# Preferred (fast, sparse-aware):
bmaptool copy cubieboard4-debian13.img.gz /dev/sdX

# Alternative:
zcat cubieboard4-debian13.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

## Default credentials

| | |
|---|---|
| User | `root` |
| Password | `root` |
| Serial console | `ttyS0 @ 115200` |

**Change the root password on first boot.**

## SD card partition layout

| Region | Content |
|---|---|
| Raw offset 8 KiB | U-Boot SPL + U-Boot proper |
| Partition 1 (FAT32, 80 MiB) | `/boot` — zImage, DTB, boot.scr |
| Partition 2 (ext4, rest) | `/` — Debian rootfs |

## Install to eMMC

After booting from SD, run as root on the board:
```bash
install-to-emmc.sh
```
This clones the running SD card system to the internal eMMC (`/dev/mmcblk2`). Remove the SD card and reboot.

## Build configuration

| Item | Value |
|---|---|
| U-Boot | 2024.01, `Cubieboard4_defconfig` |
| U-Boot patch | `patches/uboot/0001-sunxi-board-Fix-early-PMIC-setup-conditions.patch` |
| Kernel | 6.6.85, `sunxi_defconfig` + `configs/kernel/cubieboard4.config` |
| Kernel image | `zImage` |
| Cross-compiler | `arm-linux-gnueabihf-` (override via `CROSS_COMPILE=`) |
| Parallel jobs | `$(nproc)` (override via `JOBS=N`) |
| Debian suite | `trixie` (13), `armhf` |
| WiFi | AP6330 / BCM4330 — `brcmfmac` driver, firmware from `firmware-brcm80211` |
| Docker CE | Optional — `INSTALL_DOCKER=true` |

## Source tarballs

Source tarballs are downloaded to `build/sources/` on first run and reused on subsequent runs. Delete them to force a fresh download.

## Troubleshooting

### U-Boot build fails with SWIG / pylibfdt error

Symptom: build fails with errors like
```
error: too few arguments to function 'SWIG_Python_AppendOutput'
```

This is a known incompatibility between U-Boot 2024.01 and SWIG ≥ 4.2.  
`build-uboot.sh` works around it automatically by injecting a patched `build_ext`
subclass into `scripts/dtc/pylibfdt/setup.py` that post-processes the SWIG-generated
`libfdt_wrap.c` and adds the required third argument to every
`SWIG_Python_AppendOutput` call.

If you hit the error, the patch stamp may be stale. Remove it and retry:
```bash
rm -f build/sources/u-boot-2024.01/.patched
scripts/build-uboot.sh
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a full history of changes.
