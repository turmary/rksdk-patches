#!/bin/bash

set -o errexit

ROOTFS_DIR="ubuntu_rootfs"
TGT_IMG_NAME="rk3399_ubuntu_rootfs.img"
BUSYBOX_VER="1.27.2"
BUSYBOX_PKG="buildroot/dl/busybox-$BUSYBOX_VER.tar.bz2"
BUSYBOX_CFG="buildroot/package/busybox/busybox.config"
BUSYBOX_SRC="busybox-$BUSYBOX_VER"
CROSS_COMPILE=${CROSS_COMPILE-"aarch64-linux-gnu-"}
AARCH64_GCC=${CROSS_COMPILE}gcc
TGT_ARCH=arm64

export CROSS_COMPILE TGT_ARCH

_apt_updated=false
function apt_install() {
	local pkg=$1 status _pkg

	status=$(dpkg -l "$pkg" | tail -1)
	_pkg=$(  echo "$status" | awk '{ printf "%s", $2; }')
	status=$(echo "$status" | awk '{ printf "%s", $1; }')
	# echo $status $_pkg $pkg

	if [ "X$status" == "Xii" -a "X$_pkg" == "X$pkg" ]; then
		echo "debian package $pkg already installed"
		return 1
	fi

	# install the debian package
	if [ "X$_apt_updated" == "Xfalse" ]; then
		apt-get -y update
		_apt_updated=true
	fi
	apt-get -y install "$pkg"
	return 0
}

function aarch64_rt_install() {
	local _lnk _tgt
	local _t_root="/etc/qemu-binfmt/aarch64"

	[ -n "$_t_root" ] && {
		[ ! -d "$_t_root/lib" ] && mkdir -p "$_t_root/lib"
	}

	for _lnk in \
		"ld-linux-aarch64.so.1" "libm.so.6" "libc.so.6" \
	; do
		_tgt=$(realpath "$($AARCH64_GCC -print-file-name=$_lnk)")
		# echo $_tgt
		# shellcheck disable=SC2015
		[ -e $_t_root/lib/$_lnk ] && {
			echo "$_t_root/lib/$_lnk already installed"
		} || {
			ln -s "$_tgt" "$_t_root/lib/$_lnk"
			echo "$_t_root/lib/$_lnk installed"
		}
	done
	return 0
}


# echo "BASH_SOURCE=${BASH_SOURCE}"
_CMD=$(realpath "$0")
TOOLS_DIR=$(dirname "$_CMD")
# acquire root urgently
sudo ls &> /dev/null


[ "$EUID" -eq 0 ] && {
	# qemu-user-static required
	apt_install qemu-user-static
	apt_install gcc-aarch64-linux-gnu
	apt_install initramfs-tools-core
	aarch64_rt_install
	exit 1
}


[ -d $ROOTFS_DIR ] || {
	rm -rf $ROOTFS_DIR
	mkdir $ROOTFS_DIR
}

# Prepare busybox source
[ -d $BUSYBOX_SRC ] || {
	[ -s "$BUSYBOX_PKG" ] || {
		echo "### Not found $BUSYBOX_PKG ###"
		echo "### Error, please run in root folder of RK Linux SDK ###"
		exit 1
	}
	tar -xf $BUSYBOX_PKG
}
echo "###### Busybox source ready in $BUSYBOX_SRC/: ######"
# ls -l --color $BUSYBOX_SRC/

# Apply configuration
[ -f "$BUSYBOX_SRC/.config" ] || {
	cp $BUSYBOX_CFG $BUSYBOX_SRC/.config
	cmd="make -C $BUSYBOX_SRC ARCH=$TGT_ARCH CROSS_COMPILE=$CROSS_COMPILE defconfig"
	echo "$cmd"; $cmd
}

echo "CROSS_COMPILE=$CROSS_COMPILE"
cmd="make -j -C $BUSYBOX_SRC ARCH=$TGT_ARCH CROSS_COMPILE=$CROSS_COMPILE"
echo "$cmd"; $cmd


DESTDIR="$(mktemp -d "${TMPDIR:-/var/tmp}/mkinitramfs_XXXXXX")" || exit 1
chmod 755 "${DESTDIR}"

export DESTDIR TGT_ARCH

# Create usr-merged filesystem layout, to avoid duplicates if the host
# filesystem is usr-merged.
for d in /bin /lib* /sbin; do
	mkdir -p "${DESTDIR}/usr${d}"
	ln -s "usr${d}" "${DESTDIR}${d}"
done
for d in conf/conf.d etc run scripts ${MODULESDIR}; do
	mkdir -p "${DESTDIR}/${d}"
done

# shellcheck disable=SC2046
sysroot=$(dirname $(realpath -s "$(${CROSS_COMPILE}gcc -print-prog-name=ld)"))
sysroot=${sysroot%%/bin}

[ -f "${sysroot}/lib/ld-linux-aarch64.so.1" ] || {
	sysroot=$(aarch64-linux-gnu-gcc -print-file-name=ld-linux-aarch64.so.1)
	sysroot=$(realpath "${sysroot%/lib/ld-linux-aarch64.so.1}")
}

cmd="sudo -E $TOOLS_DIR/_mk-busybox-rootfs.sh -b $BUSYBOX_SRC -u $sysroot -s 30720"
echo "$cmd"; $cmd

[ -s rootfs.gz ] && {
	gunzip -ck rootfs.gz > "$ROOTFS_DIR/$TGT_IMG_NAME"
}

# shellcheck disable=SC2015
[ -s "$ROOTFS_DIR/$TGT_IMG_NAME" ] && {
	echo -e "\e[32m==== Make $ROOTFS_DIR/$TGT_IMG_NAME OK ===="
	echo -e "$(ls -l --color $ROOTFS_DIR/$TGT_IMG_NAME)"
	echo -e "====\e[0m"
	echo
} || {
	echo "#### Fail to make $ROOTFS_DIR/$TGT_IMG_NAME ####"
}

