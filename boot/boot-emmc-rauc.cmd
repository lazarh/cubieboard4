# RAUC U-Boot boot script for CubieBoard4 — A/B dual-slot eMMC boot.
#
# Implements RAUC's U-Boot slot selection protocol:
#   BOOT_ORDER     — space-separated preferred-first slot order (e.g. "A B")
#   BOOT_A_LEFT    — remaining boot attempts for slot A (0 = disabled)
#   BOOT_B_LEFT    — remaining boot attempts for slot B (0 = disabled)
#
# On each boot this script:
#   1. Picks the highest-priority slot that still has attempts left
#   2. Decrements its counter
#   3. Saves the env (saveenv)
#   4. Boots the kernel from the shared /boot FAT partition (mmc 1:1)
#      with root= pointing to the selected slot's partition
#
# After a successful boot the rauc-mark-good OpenRC service must run
# "rauc status mark-good" to reset the counter, preventing fallback.
#
# Slot mapping (U-Boot mmc 1 = Linux /dev/mmcblk2):
#   Slot A  →  mmc 1:1 /boot (FAT, shared)  +  /dev/mmcblk2p2 (rootfsA)
#   Slot B  →  mmc 1:1 /boot (FAT, shared)  +  /dev/mmcblk2p3 (rootfsB)

# Ensure load addresses are set (may be absent if saved env lacks them)
if test "${kernel_addr_r}" = ""; then setenv kernel_addr_r 0x80080000; fi
if test "${fdt_addr_r}"    = ""; then setenv fdt_addr_r    0x8FA00000; fi

setenv rauc_slot ""
setenv rootpart ""

# Default BOOT_ORDER if env vars are not set (first boot / wiped env)
if test "${BOOT_ORDER}" = ""; then
    setenv BOOT_ORDER "A B"
    setenv BOOT_A_LEFT 3
    setenv BOOT_B_LEFT 3
fi

# Try slots in BOOT_ORDER priority
if test "${BOOT_ORDER}" = "A B"; then
    if test ${BOOT_A_LEFT} -gt 0; then
        setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
        setenv rauc_slot A
        setenv rootpart /dev/mmcblk2p2
    elif test ${BOOT_B_LEFT} -gt 0; then
        setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
        setenv rauc_slot B
        setenv rootpart /dev/mmcblk2p3
    fi
else
    if test ${BOOT_B_LEFT} -gt 0; then
        setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
        setenv rauc_slot B
        setenv rootpart /dev/mmcblk2p3
    elif test ${BOOT_A_LEFT} -gt 0; then
        setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
        setenv rauc_slot A
        setenv rootpart /dev/mmcblk2p2
    fi
fi

# Emergency fallback: no bootable slot found
if test "${rootpart}" = ""; then
    echo "RAUC: WARNING — no bootable slot (all attempt counters exhausted)"
    echo "RAUC: Emergency fallback to slot A"
    setenv rauc_slot A
    setenv rootpart /dev/mmcblk2p2
fi

saveenv

echo "RAUC: booting slot ${rauc_slot} (root=${rootpart})"

load mmc 1:1 ${fdt_addr_r} sun9i-a80-cubieboard4.dtb
load mmc 1:1 ${kernel_addr_r} zImage
setenv bootargs console=tty1 console=ttyS0,115200 root=${rootpart} rootwait rw panic=10 rauc.slot=${rauc_slot} ${extra}
bootz ${kernel_addr_r} - ${fdt_addr_r}
