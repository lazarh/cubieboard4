FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append:cubieboard4 = " file://0001-dts-sun9i-a80-cubieboard4-fix-mmc1-wifi-init.patch"
SRC_URI:append:cubieboard4 = " file://docker.cfg"

KERNEL_CONFIG_FRAGMENTS:append:cubieboard4 = " ${WORKDIR}/docker.cfg"
