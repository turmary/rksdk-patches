#!/bin/bash
#
# mkrootfs.sh - creates a root file system
#

# TODO: need to add checks here to verify that busybox, uClibc and bzImage
# exist
set -o errexit

# command-line settable variables
BUSYBOX_DIR=..
UCLIBC_DIR=../../uClibc
TARGET_DIR=.loop #./loop
FSSIZE=4000
CLEANUP=1
MKFS='mkfs.ext2 -F'
RTFS=.rootfs-blk

# don't-touch variables
BASE_DIR=$(pwd)
TARGET_DIR="$BASE_DIR/$TARGET_DIR"


while getopts 'b:u:s:t:Cm' opt
do
	case $opt in
		b) BUSYBOX_DIR=$OPTARG ;;
		u) UCLIBC_DIR=$OPTARG ;;
		t) TARGET_DIR=$OPTARG ;;
		s) FSSIZE=$OPTARG ;;
		C) CLEANUP=0 ;;
		m) MKFS='mkfs.minix' ;;
		*)
			echo "usage: $(basename "$0") [-bu]"
			echo "  -b DIR  path to busybox direcory (default ..)"
			echo "  -u DIR  path to uClibc direcory (default ../../uClibc)"
			echo "  -t DIR  path to target direcory (default ./loop)"
			echo "  -s SIZE size of root filesystem in Kbytes (default 4000)"
			echo "  -C      don't perform cleanup (umount target dir, gzip rootfs, etc.)"
			echo "          (this allows you to 'chroot loop/ /bin/sh' to test it)"
			echo "  -m      use minix filesystem (default is ext2)"
			exit 1
			;;
	esac
done

export DESTDIR="$TARGET_DIR"
export verbose=y
source /usr/share/initramfs-tools/hook-functions

# $1 = file type (for logging)
# $2 = file to copy to ramdisk
# $3 (optional) Name for the file on the ramdisk
# Location of the image dir is assumed to be $DESTDIR
# If the target exists, we leave it and return 1.
# On any other error, we return >1.
copy_file() {
	local type src target link_target

	type="${1}"
	src="${2}"
	target="${3:-$2}"

	[ -f "${src}" ] || return 2

	if [ -d "${DESTDIR}/${target}" ]; then
		target="${target}/${src##*/}"
	fi

	# check if already copied
	[ -e "${DESTDIR}/${target}" ] && return 1

	#FIXME: inst_dir
	mkdir -p "${DESTDIR}/${target%/*}"

	if [ -h "${src}" ]; then
		[ "${verbose}" = "y" ] && echo "Adding ${type}-link ${src}"

		# We don't need to replicate a chain of links completely;
		# just link directly to the ultimate target.  Create a
		# relative link so it always points to the right place.
		link_target="$(realpath --relative-to=. $(readlink -f "${src}"))" || return $(($? + 1))
		ln -rs "${DESTDIR}/${link_target}" "${DESTDIR}/${target}"

		# Copy the link target if it doesn't already exist
		src="${link_target}"
		target="${link_target}"
		[ -e "${DESTDIR}/${target}" ] && return 1
		mkdir -p "${DESTDIR}/${target%/*}"
	fi

	[ "${verbose}" = "y" ] && echo "Adding ${type} ${src}"

	cp -pP "${src}" "${DESTDIR}/${target}" || return $(($? + 1))
}


# clean up from any previous work
mount | grep -q loop && umount "$TARGET_DIR"
# [ $? -eq 0 ] && umount $TARGET_DIR
[ -d "$TARGET_DIR" ] && rm -rf "${TARGET_DIR:?}/"
[ -f $RTFS ] && rm -f $RTFS
[ -f rootfs.gz ] && rm -f rootfs.gz


# prepare root file system and mount as loopback
dd if=/dev/zero of=$RTFS bs=1k count="$FSSIZE"
$MKFS -i 2000 $RTFS
mkdir "$TARGET_DIR"
mount -o loop,exec $RTFS "$TARGET_DIR" # must be root


# install uClibc
mkdir -p "$TARGET_DIR/lib"
cd "$UCLIBC_DIR"
# make INSTALL_DIR=
# cp -a libc.so* $TARGET_DIR/lib
copy_file library "lib/libc.so.6"
# cp -a uClibc*.so $TARGET_DIR/lib
copy_file library "lib/libm.so.6"
# cp -a ld.so-1/d-link/ld-linux-uclibc.so* $TARGET_DIR/lib
# cp -a ld.so-1/libdl/libdl.so* $TARGET_DIR/lib
copy_file library "lib/ld-linux-aarch64.so.1"
# cp -a crypt/libcrypt.so* $TARGET_DIR/lib
copy_file library "lib/libcrypt.so.1" "/lib"
cd "$BASE_DIR"


# install busybox and components
cd "$BUSYBOX_DIR"
# make distclean
# make CC=$BASE_DIR/$UCLIBC_DIR/extra/gcc-uClibc/i386-uclibc-gcc
# make CONFIG_PREFIX=$TARGET_DIR install
CMD="make ARCH=$TGT_ARCH CROSS_COMPILE=$CROSS_COMPILE CONFIG_PREFIX=$TARGET_DIR install"
# [ "X$(expr substr $i 1 1)" = X/ ] && i=$(echo $i | cut -c2-)
# echo $CMD; _RES="$($CMD)"; echo "$_RES" | head
echo "$CMD"; $CMD | {
	head
	echo "  ......"
	cat >/dev/null
}
cd "$BASE_DIR"


# make files in /dev
mkdir "$TARGET_DIR/dev"
cd "$BUSYBOX_DIR/examples/bootfloppy"
./mkdevs.sh "$TARGET_DIR/dev"


# make files in /etc
cp -a etc "$TARGET_DIR"
ln -s /proc/mounts "$TARGET_DIR/etc/mtab"

cd "$BASE_DIR"

# other miscellaneous setup
mkdir "$TARGET_DIR/initrd"
mkdir "$TARGET_DIR/proc"
mkdir "$TARGET_DIR/run"
mkdir "$TARGET_DIR/sys"


# Done. Maybe do cleanup.
if [ $CLEANUP -eq 1 ]
then
	umount "$TARGET_DIR"
	rmdir  "$TARGET_DIR"
	gzip -c9 $RTFS > rootfs.gz
	rm -f $RTFS
fi
