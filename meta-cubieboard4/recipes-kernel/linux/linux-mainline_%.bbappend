FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append:cubieboard4 = " file://0001-dts-sun9i-a80-cubieboard4-fix-mmc1-wifi-init.patch"
