# Boot from whichever device U-Boot found this script on (${devnum}).
# U-Boot mmc device → Linux block device mapping on CubieBoard4:
#   mmc 0  (mmc@1c0f000) = SD card  → mmcblk0
#   mmc 1  (mmc@1c11000) = eMMC     → mmcblk2
setenv mmc_rootdev mmcblk0p2
if test "${devnum}" = "1"; then
	setenv mmc_rootdev mmcblk2p2
fi

setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/${mmc_rootdev} rootwait panic=10 ${extra}
load mmc ${devnum}:1 ${fdt_addr_r} ${fdtfile} || load mmc ${devnum}:1 ${fdt_addr_r} boot/allwinner/${fdtfile}
load mmc ${devnum}:1 ${kernel_addr_r} zImage || load mmc ${devnum}:1 ${kernel_addr_r} boot/zImage
bootz ${kernel_addr_r} - ${fdt_addr_r}
