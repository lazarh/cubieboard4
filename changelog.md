# Changelog

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

### Known remaining issues

| Issue | Details |
|---|---|
| `regulatory.db` missing | `brcmfmac` logs `failed to load regulatory.db` — add `wireless-regdb` to `IMAGE_INSTALL` if regulatory compliance is needed |
| Unclean SD card unmount | EXT4/FAT `Volume was not properly unmounted` warnings on every boot — always run `halt` before removing power |
| mmc1 `vcc-io-wifi-codec-io2: voltage operation not allowed` | May still appear once during boot (regulator enabled but fixed voltage), harmless after the `vqmmc-supply` removal |
