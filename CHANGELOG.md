# Changelog

All notable changes to this project are documented here.

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
