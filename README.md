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

To pre-configure the hostname or WiFi so the board connects on first boot:

```bash
# Set hostname at image build time (defaults to 'cubieboard4')
sudo HOSTNAME="myboard" scripts/build-rootfs.sh

# Pre-configure WiFi (requires WIFI_PASSWORD)
sudo WIFI_SSID="MyNetwork" WIFI_PASSWORD="secret" scripts/build-rootfs.sh
```

### 5. Assemble the SD card image (as root)
```bash
# Default output image under repo root
sudo scripts/assemble-sd-image.sh

# Or specify an explicit output image path:
sudo scripts/assemble-sd-image.sh /path/to/output.img
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
| Hostname pre-config | Optional — `HOSTNAME=myboard` |
| WiFi pre-config | Optional — `WIFI_SSID=x WIFI_PASSWORD=y` |

## Kernel patches — why CubieBoard4 needs them

Three kernel patches are applied on top of mainline 6.6.85. None of these issues
are specific to this build system — they are bugs or omissions in the upstream
kernel that happen to affect the CubieBoard4.

### Comparison with other AP6330 / BCM4330 boards

The AP6330 (Broadcom BCM4330) WiFi+BT module is used on several boards. In
mainline 6.6.85, only the CubieBoard4 DTS is missing the standard power-on
timing and frequency properties:

| Board | SoC | post-power-on-delay-ms | max-frequency | mask\_data0 | Upstream status |
|---|---|---|---|---|---|
| OUYA | Tegra30 | 300 ms | 50 MHz | N/A (Tegra MMC) | Complete |
| Asus Transformer | Tegra30 | 300 ms | 50 MHz | N/A (Tegra MMC) | Complete |
| Pegatron Chagall | Tegra30 | 300 ms | 50 MHz | N/A (Tegra MMC) | Complete |
| **CubieBoard4** | **A80 (sun9i)** | **missing** | **missing** | **missing** | **Broken** |

All Tegra30 boards ship with working BCM4330 WiFi out of the box. The
CubieBoard4 is the only board where the upstream DTS and driver config are
incomplete.

### Patch 0001 — DTS: WiFi power-on delay and frequency cap

**Scope: CubieBoard4-specific (device tree)**

The upstream `sun9i-a80-cubieboard4.dts` defines the WiFi power sequence node
(`wifi_pwrseq`) and SDIO host (`mmc@1c10000`) but omits two properties that
every other BCM4330 board provides:

- `post-power-on-delay-ms`: the BCM4330 needs time after its reset line is
  released before it can respond to SDIO commands. All Tegra30 boards use
  300 ms; we use 1000 ms because the A80 MMC controller initialisation is
  slower.
- `max-frequency`: caps the SDIO clock at 25 MHz, within the range tested
  to work reliably on this board. Tegra30 boards use 50 MHz.

These are standard `mmc-pwrseq-simple` and MMC subsystem properties — the
upstream DTS simply never had them filled in for this board.

### Patch 0002 — brcmfmac: fix netdev registration race

**Scope: general kernel bug (all brcmfmac chipsets)**

This is **not** CubieBoard4-specific. After `wiphy_register()`, every netdev
with `ieee80211_ptr` set must be registered through
`cfg80211_register_netdevice()` so that `wdev->registered` is set before
`register_netdevice()` runs. The upstream code calls `register_netdev()` in
the `locked=false` path (used by `brcmf_bus_started()` and the firmware E\_IF
event handler), which only acquires `rtnl_lock` but not `wiphy_lock`.

On BCM4330 SDIO the race is **reliably** triggered at boot because firmware
E\_IF events arrive quickly via the SDIO interrupt while
`brcmf_cfg80211_attach()` is still running. The result is a kernel BUG at
`net/core/dev.c` (`reg_state != NETREG_UNINITIALIZED`) and a permanent
`rtnl_lock` deadlock that hangs all subsequent `ip` commands.

The fix acquires both `rtnl_lock` and `wiphy_lock` and always uses
`cfg80211_register_netdevice()`. This applies to all brcmfmac chipsets
(BCM4334, BCM4339, BCM43455, etc.) but is only reliably reproducible on
BCM4330 SDIO due to timing.

### Patch 0003 — sunxi-mmc: add mask\_data0 to sun9i\_a80\_cfg

**Scope: upstream driver bug (Allwinner A80 only)**

`sun9i_a80_cfg` in `drivers/mmc/host/sunxi-mmc.c` is the **only** SoC config
struct missing `mask_data0 = true`. All other recent Allwinner configs have it:

| SoC config | mask\_data0 |
|---|---|
| sun9i\_a80\_cfg | **false (missing)** |
| sun20i\_d1\_cfg | true |
| sun50i\_a64\_cfg | true |
| sun50i\_h616\_cfg | true |

Without this flag, `sunxi_mmc_oclk_onoff()` waits for DATA0 to go high
(`WAIT_PRE_OVER`) during every clock update. The BCM4330 holds DATA0 low while
in reset, so every clock change times out after ~750 ms and sets
`fatal_err = 1`, permanently preventing card initialisation. The
`mask_data0` flag is not chip-specific — it is an Allwinner MMC controller
feature. The A80 hardware supports it; the driver config simply never set it.

This bug also affects any other SDIO or non-removable MMC device on the A80
where the card may hold DATA0 low during clock transitions.

## Source tarballs

Source tarballs are downloaded to `build/sources/` on first run and reused on subsequent runs. Delete them to force a fresh download.

## Troubleshooting

### eMMC boot fails — `Bad device specification mmc 1`

If the board does not boot from eMMC after running `install-to-emmc.sh`, and
U-Boot prints:

```
Loading Environment from FAT... ** Bad device specification mmc 1 **
```

the U-Boot binary on the eMMC was built before the fixes in patches 0002–0005.
Four root causes must all be fixed together:

1. **Devnum collision** (patch 0002): The WiFi SDIO node (`mmc@1c10000`) was enabled
   in the U-Boot DTS, stealing devnum 1 from the eMMC (which U-Boot expects at devnum 1).
   Fix: disable `mmc@1c10000` in the U-Boot DTS.

2. **MMC reset not deasserted** (patch 0003): `a80_mmc_resets[]` in `clk_a80.c` used
   `GATE()` instead of `RESET()`, silently preventing the mmc-common reset from being
   deasserted. U-Boot would print `sunxi_set_reset: (RST#N) unhandled` for each MMC.

3. **Wrong config symbol in get_mclk_offset()** (patch 0005): `sunxi_mmc.c` tested
   `IS_ENABLED(CONFIG_MACH_SUN9I_A80)` (non-existent symbol) instead of
   `CONFIG_MACH_SUN9I`, causing `priv->mclkreg` to point at reserved CCU space
   (`0x06000090`) instead of the correct sd2_clk_cfg register (`0x06000418`).
   All module-clock writes were silently dropped, producing undefined init behaviour.

4. **Clock output disabled after reset** (patch 0004): After `SUNXI_MMC_GCTRL_RESET`
   in probe, `CLKCR.CLK_ENABLE` resets to 0. The first `mmc_update_clk(WAIT_PRE_OVER)`
   inside `mmc_config_clock()` then hangs 2 s (CLK never driven) and sets
   `priv->fatal_err = 1`, making the eMMC permanently inaccessible.

To fix, rebuild U-Boot (which applies all patches) and reinstall:

```bash
# On the build host — rebuild U-Boot with all fixes
rm build/sources/u-boot-2024.01/.patched
scripts/build-uboot.sh

# Rebuild and reflash the SD image, then boot from SD
sudo scripts/assemble-sd-image.sh

# On the board (booted from SD) — reinstall to eMMC
install-to-emmc.sh
```

### WiFi (`wlan0`) missing after boot

If `wlan0` is absent and `dmesg` shows a repeating stream of:

```
sunxi-mmc 1c10000.mmc: fatal err update clk timeout
...
mmc1: Failed to initialize a non-removable card
```

the root cause is a missing `mask_data0 = true` in `sun9i_a80_cfg` in the kernel
sunxi-mmc driver. Without this flag, every MMC clock update waits for DATA0 to go
high (`WAIT_PRE_OVER`), but the BCM4330 holds DATA0 low during initialisation,
causing each update to time out after 750 ms and set `fatal_err = 1`.

This is fixed by kernel patch `0003-mmc-sunxi-Add-mask_data0-to-sun9i-A80-config.patch`,
included in this repository. Rebuild the kernel to apply it:

```bash
rm build/sources/linux-6.6.85/.patched
scripts/build-kernel.sh
```

### Spurious `brcmf_fweh_event_worker: event handler failed (72)` messages

The BCM4330 firmware sends event type 72 (`FIFO_CREDIT_MAP`) which the brcmfmac
driver does not register a handler for. These messages are cosmetic and do not
indicate a problem with WiFi operation.

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
