# Default to (primary) SD card
rootdev=mmcblk0p2
if itest.b *0x28 == 0x02 ; then
	# U-Boot loaded from eMMC so use it for rootfs too
	echo "U-Boot loaded from eMMC"
	rootdev=mmcblk1p2
fi
setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/${rootdev} rootwait panic=10 ${extra}
load mmc 0:1 ${fdt_addr_r} ${fdtfile} || load mmc 0:1 ${fdt_addr_r} boot/allwinner/${fdtfile}
load mmc 0:1 ${kernel_addr_r} zImage || load mmc 0:1 ${kernel_addr_r} boot/zImage
bootz ${kernel_addr_r} - ${fdt_addr_r}
