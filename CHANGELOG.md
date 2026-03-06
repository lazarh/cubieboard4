# Changelog

All notable changes to this project are documented here.

---

## 2026-03-06

### Fixed — Docker container start failure (`IPC_NS` / namespace unshare)

Docker and `runc` containers failed to start with `EINVAL` from namespace unshare.
Root cause: `CONFIG_IPC_NS` was silently dropped by kconfig because its dependencies
(`CONFIG_SYSVIPC` or `CONFIG_POSIX_MQUEUE`) were both disabled by `sunxi_defconfig`.

- **`b0605d0`** — `configs/kernel/cubieboard4.config`: add `CONFIG_SYSVIPC=y`,
  `CONFIG_POSIX_MQUEUE=y` (IPC_NS dependencies), `CONFIG_IPC_NS=y`, `CONFIG_CGROUP_NS=y`,
  `CONFIG_CPUSETS=y`.

### Fixed — Docker cgroup v2 BPF device filter (`bpf_prog_query` not implemented)

Containers failed with `bpf_prog_query(BPF_CGROUP_DEVICE) failed: function not implemented`.
Root cause: `CONFIG_BPF_SYSCALL` was explicitly disabled in `sunxi_defconfig`, which
also blocked `CONFIG_CGROUP_BPF`. Docker/runc requires `bpf()` syscall for cgroup v2
device access control.

- **`932894b`** — `configs/kernel/cubieboard4.config`: add `CONFIG_BPF_SYSCALL=y`,
  `CONFIG_CGROUP_BPF=y`.

### Fixed — kernel BUG in `register_netdevice` causing WiFi crash and `ip a` hang

The BCM4330 driver crashed at boot with `kernel BUG at net/core/dev.c:10174`
(`BUG_ON(dev->reg_state != NETREG_UNINITIALIZED)`). A firmware `E_IF` event fired
concurrently with `brcmf_net_attach()`, causing the network device to be registered
twice. After the BUG the RTNL lock was never released, hanging any command that needs
it (`ip a`, `ip link`, etc.).

Fix: change the `!locked` path in `brcmf_net_attach()` to use
`cfg80211_register_netdevice()` with `rtnl_lock` + `wiphy_lock` held, which sets
`wdev->registered = true` before `register_netdevice()` runs and prevents the race.

- **`ecf9a5d`** — `patches/kernel/0002-brcmfmac-fix-netdev-registration-via-cfg80211-path.patch`

### Fixed — BCM4330 intermittent SDIO init failure at boot

The BCM4330 WiFi chip occasionally failed to initialize on boot
(`mmc1: Failed to initialize a non-removable card`, multiple
`sunxi-mmc 1c10000.mmc: fatal err update clk timeout`). The SDIO bus was running
at its default 50 MHz which is unreliable on this hardware, and the power-on reset
delay was too short.

- **`4250200`** — `patches/kernel/0001-dts-sun9i-a80-cubieboard4-fix-wifi-pwrseq-delay.patch`:
  increase `post-power-on-delay-ms` from 200 ms to 500 ms; add
  `max-frequency = <25000000>` to the `mmc1` node to cap SDIO clock at 25 MHz.

---

## 2026-02-27

### Added
- **Standalone cross-compilation build system** (`a6c0bad`)  
  Complete set of scripts to build U-Boot, Linux kernel, and a Debian 13 (trixie) armhf
  root filesystem for CubieBoard4 without Yocto:
  - `scripts/install-deps.sh` — install host build dependencies
  - `scripts/build-uboot.sh` — U-Boot 2024.01 (`Cubieboard4_defconfig`)
  - `scripts/build-kernel.sh` — kernel 6.6.85 (`sunxi_defconfig` + fragment)
  - `scripts/build-rootfs.sh` — Debian 13 trixie armhf rootfs via `debootstrap`
  - `scripts/assemble-sd-image.sh` — assemble bootable `.img.gz` + `.bmap`
  - `scripts/install-to-emmc.sh` — clone running system to internal eMMC (runs on board)
  - `boot/boot.cmd` — U-Boot boot script source
  - `configs/kernel/cubieboard4.config` — board-specific kernel config fragment
  - `patches/uboot/0001-sunxi-board-Fix-early-PMIC-setup-conditions.patch` — sun9i PMIC fix
  - `README.md` with Quick Start, partition layout, build configuration, and credentials
  - `.gitignore` for build artefacts

### Fixed — `scripts/build-uboot.sh` SWIG ≥ 4.2 incompatibility (series of 6 commits)

U-Boot 2024.01's `scripts/dtc/pylibfdt` fails to build with SWIG ≥ 4.2 because
`SWIG_Python_AppendOutput` gained a mandatory third argument (`is_void`).
The fix was developed iteratively:

1. **`6c9bf65`** — First attempt: pass `PYTHON=nopython PYTHON3=nopython3` to `make` to
   skip the Python bindings entirely. Broke because U-Boot still detected Python in `PATH`
   and queued a rebuild anyway.

2. **`97846a3`** — Patch the `pylibfdt/Makefile` via `sed` to remove the `always` rebuild
   target. Broke `binman` which needs `_libfdt.so`.

3. **`6c6574f`** — Add `patch -N` flag so re-running the script on a partially-built tree
   does not fail with "Reversed (or previously applied) patch".

4. **`858b2a9`** — Fix the `sed` pattern to match the actual line in U-Boot 2024.01
   (`always += _libfdt.so libfdt.py` instead of `always-$(CONFIG_PYLIBFDT)`).

5. **`a38f687`** — Proper fix: inject a `build_ext` subclass into `setup.py` that
   post-processes the SWIG-generated `libfdt_wrap.c` after generation, adding the missing
   third argument to all `SWIG_Python_AppendOutput` calls using a regex.

6. **`b283c08`** — Harden the regex approach: replace the `[^,)]+` character class with a
   parenthesis-counting walker (`_fix_swig_append_output()`) that correctly handles nested
   expressions such as `SWIG_From_int(*arg3)` and `SWIG_NewPointerObj((void *)p, ...)`.
   This is the final, correct fix shipped in the build script.
