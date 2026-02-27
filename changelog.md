# Changelog

## 2026-02-27 — Debian 13 image build with Docker CE and eMMC installer

Added a full hybrid build system: Yocto builds the bootloader and kernel;
`debootstrap` bootstraps a Debian 13 (trixie, armhf) rootfs; helper scripts
assemble a bootable SD card image and install it to the internal eMMC.

### Architecture overview

```
kas build kas.yml
  └─> U-Boot + Linux kernel artifacts

sudo scripts/build-debian-rootfs.sh
  └─> debian-rootfs/  (Debian 13 trixie, armhf)
      ├─ Docker CE (armhf) from docker.com
      ├─ WiFi: firmware-brcm80211, wpasupplicant, NetworkManager
      ├─ Kernel modules from Yocto
      └─ install-to-emmc.sh embedded at /usr/local/sbin/

sudo scripts/assemble-sd-image.sh
  └─> cubieboard4-debian13.img.gz
      ├─ offset 8 KiB : U-Boot SPL (sunxi raw format)
      ├─ part1 FAT    : uImage, DTB, boot.scr
      └─ part2 ext4   : Debian rootfs
```

### Hardware support confirmed

| Peripheral | Status | Notes |
|------------|--------|-------|
| Ethernet (GMAC RGMII) | ✅ | Already enabled in DTS |
| WiFi (BCM4330 / AP6330) | ✅ | `firmware-brcm80211`, `wpasupplicant` |
| Internal eMMC (`mmc2`, 8-bit) | ✅ | `install-to-emmc.sh` partitions, flashes U-Boot, rsyncs rootfs |
| SD card (`mmc0`) | ✅ | Boot source |
| Docker CE (armhf, linux/arm/v7) | ✅ | Kernel config + Docker CE apt repo |

> **Note:** The A80 is 32-bit ARMv7. Only `linux/arm/v7` container images will run;
> arm64-only images will not.

### Files added

| File | Purpose |
|------|---------|
| `meta-cubieboard4/recipes-kernel/linux/linux-mainline/docker.cfg` | Kernel config fragment: cgroups v1+v2, namespaces, overlayfs, netfilter, veth, bridge, seccomp |
| `scripts/build-debian-rootfs.sh` | `qemu-debootstrap` trixie/armhf → configure system → install Docker CE + WiFi + networking → copy kernel modules |
| `scripts/assemble-sd-image.sh` | Creates raw `.img.gz` from Yocto artifacts + debootstrap sysroot |
| `scripts/install-to-emmc.sh` | Runs on the board: partitions `/dev/mmcblk2`, flashes U-Boot at 8 KiB, rsyncs rootfs, fixes `/etc/fstab` |

### Files modified

| File | Change |
|------|--------|
| `kas.yml` | Target changed from `core-image-minimal` to `[virtual/kernel, virtual/bootloader]`; removed poky-only wifi `IMAGE_INSTALL` |
| `meta-cubieboard4/recipes-kernel/linux/linux-mainline_%.bbappend` | Wire `docker.cfg` into `KERNEL_CONFIG_FRAGMENTS` |
| `install-deps.sh` | Replace `pip install kas` with `pipx install kas` (PEP 668); drop obsolete `liblz4-tool`; add `qemu-user-static`, `debootstrap`, `parted`, `dosfstools`, `rsync`, `pipx` |
| `README.md` | Full rewrite: quick-start section, hardware support table, 3-step build flow, WiFi setup, Docker verification, eMMC install instructions |

### Key findings during investigation

- **"Internal NAND"** turned out to be an **eMMC** (`mmc2`, 8-bit bus, `non-removable`)
  in the DTS — a standard block device, no raw NAND / MTD complexity needed.
- **Ethernet** was already fully configured in `sun9i-a80-cubieboard4.dts`
  (`&gmac status = "okay"`); only Debian-side networking packages were needed.
- **Docker CE trixie** is available at `download.docker.com` — confirmed before
  adding the apt repo to the rootfs script.
- **`liblz4-tool`** no longer exists in current Debian/Ubuntu; replaced by `lz4`.
- **`pip install kas`** fails on modern Debian (PEP 668); `pipx` is the correct tool.

## 2026-02-26 — Cubieboard4 Yocto Image Fixes

### Fix: root login failing after first boot

**Symptom:** `Login incorrect` when trying to log in as `root` with no password.

**Root cause:** The `debug-tweaks` IMAGE_FEATURE was missing from the build
configuration. Without it, the root account has a locked password.

**Fix:** Added `debug-tweaks` to `kas.yml` via `local_conf_header` so it
persists across kas runs (setting it only in `build/conf/local.conf` is not
sufficient as kas regenerates that file on every build).

**Files changed:**
- `kas.yml` — added `local_conf_header.debug-tweaks`:
  ```yaml
  EXTRA_IMAGE_FEATURES += "debug-tweaks"
  ```

---

### Fix: WiFi (AP6210/BCM43362) not working — no wlan0 interface

**Symptom:** No `wlan0` interface, `lsmod` empty, no `/lib/firmware/`,
`mmc1: Failed to initialize a non-removable card` in dmesg.

**Root cause (1) — missing userspace and firmware packages:** The
`core-image-minimal` image did not include the `brcmfmac` kernel module,
BCM43362 firmware, `wpa-supplicant`, or `iw`.

**Fix:** Added WiFi packages to `kas.yml`:

**Files changed:**
- `kas.yml` — added `local_conf_header.wifi`:
  ```yaml
  IMAGE_INSTALL:append = " kernel-module-brcmfmac linux-firmware-bcm43362 wpa-supplicant iw"
  ```

---

**Root cause (2) — mmc1 SDIO clock timeout preventing WiFi chip init:**
The `sun9i-a80-cubieboard4.dts` mmc1 node had `vqmmc-supply = <&reg_cldo3>`.
The `reg_cldo3` regulator (`vcc-io-wifi-codec-io2`) is fixed at 3.0V and
cannot switch voltage. During SDIO card initialization the mmc driver attempts
IO voltage switching, which fails with `vcc-io-wifi-codec-io2: voltage
operation not allowed`, cascading into repeated `sunxi-mmc 1c10000.mmc: fatal
err update clk timeout` and ultimately `mmc1: Failed to initialize a
non-removable card`.

**Fix:** Created a kernel DTS patch for the cubieboard4 machine that:
- Removes `vqmmc-supply` from the `mmc1` node (no IO voltage switching needed
  for the non-UHS AP6210 SDIO device)
- Adds `max-frequency = <50000000>` to cap the SDIO bus at 50 MHz
- Adds the `brcmf: wifi@1` child node so the `brcmfmac` driver binds correctly

**Files added:**
- `meta-cubieboard4/recipes-kernel/linux/linux-mainline_%.bbappend`
- `meta-cubieboard4/recipes-kernel/linux/linux-mainline/0001-dts-sun9i-a80-cubieboard4-fix-mmc1-wifi-init.patch`

---

## 2026-02-26 — Fix WiFi chip identification (BCM4330 not BCM43362)

**Symptom:** `brcmfmac: probe of mmc1:0001:1 failed with error -110` even after
mmc1 clock fix and NVRAM symlink.

**Root cause:** The onboard WiFi chip is **BCM4330** (SDIO `0x02d0:0x4330`),
not BCM43362 as previously assumed. The wrong firmware package was being
installed. The `linux-firmware-bcm4330` package already ships
`brcmfmac4330-sdio.cubietech,a80-cubieboard4.bin` which matches the board's
DT compatible string (`cubietech,a80-cubieboard4`) exactly.

**Fix:**
- Added `require conf/machine/include/hardware/ap6330.inc` to `cubieboard4.conf`.
  This automatically pulls in `kernel-module-brcmfmac` and
  `linux-firmware-bcm4330` via `MACHINE_EXTRA_RRECOMMENDS/RDEPENDS`.
- Replaced `linux-firmware-bcm43362` with `linux-firmware-bcm4330` in
  `kas.yml`.
- Removed the wrong BCM43362 NVRAM symlink recipe
  (`brcmfmac-nvram-cubieboard4_1.0.bb`) — no longer needed since
  `linux-firmware-bcm4330` ships the correct board-specific file.

**Files changed:**
- `kas.yml`
- `meta-cubieboard4/conf/machine/cubieboard4.conf`



| Issue | Details |
|---|---|
| `regulatory.db` missing | `brcmfmac` logs `failed to load regulatory.db` — add `wireless-regdb` to `IMAGE_INSTALL` if regulatory compliance is needed |
| Unclean SD card unmount | EXT4/FAT `Volume was not properly unmounted` warnings on every boot — always run `halt` before removing power |
| mmc1 `vcc-io-wifi-codec-io2: voltage operation not allowed` | May still appear once during boot (regulator enabled but fixed voltage), harmless after the `vqmmc-supply` removal |
