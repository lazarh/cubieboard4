# U-Boot mmc device → Linux block device mapping on CubieBoard4:
#   mmc 0  (mmc@1c0f000) = SD card  → mmcblk0
#   mmc 1  (mmc@1c11000) = eMMC     → mmcblk2
#
# If this script was loaded from SD (devnum=0), check whether eMMC
# (mmc 1) already has a kernel and prefer it.  This prevents an
# inserted CB4 SD image from overriding a normal eMMC boot.
if test "${devnum}" = "0"; then
	if load mmc 1:1 ${fdt_addr_r} ${fdtfile}; then
		load mmc 1:1 ${kernel_addr_r} zImage || load mmc 1:1 ${kernel_addr_r} boot/zImage
		setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/mmcblk2p2 rootwait panic=10 ${extra}
		bootz ${kernel_addr_r} - ${fdt_addr_r}
	fi
fi

setenv mmc_rootdev mmcblk0p2
if test "${devnum}" = "1"; then
	setenv mmc_rootdev mmcblk2p2
fi

setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/${mmc_rootdev} rootwait panic=10 regulator.debug=1 ${extra}
load mmc ${devnum}:1 ${fdt_addr_r} ${fdtfile} || load mmc ${devnum}:1 ${fdt_addr_r} boot/allwinner/${fdtfile}
load mmc ${devnum}:1 ${kernel_addr_r} zImage || load mmc ${devnum}:1 ${kernel_addr_r} boot/zImage
bootz ${kernel_addr_r} - ${fdt_addr_r}
