# Always boot from SD card (mmc 0) - ignore boot device detection
setenv mmc_rootdev mmcblk0p2

setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/${mmc_rootdev} rootwait panic=10 ${extra}
load mmc 0:1 ${fdt_addr_r} ${fdtfile} || load mmc 0:1 ${fdt_addr_r} boot/allwinner/${fdtfile}
load mmc 0:1 ${kernel_addr_r} zImage || load mmc 0:1 ${kernel_addr_r} boot/zImage
bootz ${kernel_addr_r} - ${fdt_addr_r}
