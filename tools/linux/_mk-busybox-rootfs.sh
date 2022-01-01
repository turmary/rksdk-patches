#!/bin/bash
#
# mkrootfs.sh - creates a root file system
#

# TODO: need to add checks here to verify that busybox, uClibc and bzImage
# exist


# command-line settable variables
BUSYBOX_DIR=..
UCLIBC_DIR=../../uClibc
TARGET_DIR=./loop
FSSIZE=4000
CLEANUP=1
MKFS='mkfs.ext2 -F'
RTFS=.rootfs-blk

# don't-touch variables
BASE_DIR=`pwd`
TARGET_DIR=$BASE_DIR/$TARGET_DIR


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
			echo "usage: `basename $0` [-bu]"
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

export DESTDIR=$TARGET_DIR
export verbose=y
source /usr/share/initramfs-tools/hook-functions

# clean up from any previous work
mount | grep -q loop
[ $? -eq 0 ] && umount $TARGET_DIR
[ -d $TARGET_DIR ] && rm -rf $TARGET_DIR/
[ -f $RTFS ] && rm -f $RTFS
[ -f rootfs.gz ] && rm -f rootfs.gz


# prepare root file system and mount as loopback
dd if=/dev/zero of=$RTFS bs=1k count=$FSSIZE
$MKFS -i 2000 $RTFS
mkdir $TARGET_DIR
mount -o loop,exec $RTFS $TARGET_DIR # must be root


# install uClibc
mkdir -p $TARGET_DIR/lib
cd $UCLIBC_DIR
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
cd $BASE_DIR


# install busybox and components
cd $BUSYBOX_DIR
# make distclean
# make CC=$BASE_DIR/$UCLIBC_DIR/extra/gcc-uClibc/i386-uclibc-gcc
# make CONFIG_PREFIX=$TARGET_DIR install
make ARCH=$TGT_ARCH CROSS_COMPILE=$CROSS_COMPILE CONFIG_PREFIX=$TARGET_DIR install
cd $BASE_DIR


# make files in /dev
mkdir $TARGET_DIR/dev
cd $BUSYBOX_DIR/examples/bootfloppy
./mkdevs.sh $TARGET_DIR/dev


# make files in /etc
cp -a etc $TARGET_DIR
ln -s /proc/mounts $TARGET_DIR/etc/mtab

cd $BASE_DIR

# other miscellaneous setup
mkdir $TARGET_DIR/initrd
mkdir $TARGET_DIR/proc


# Done. Maybe do cleanup.
if [ $CLEANUP -eq 1 ]
then
	umount $TARGET_DIR
	rmdir  $TARGET_DIR
	gzip -c9 $RTFS > rootfs.gz
	rm -f $RTFS
fi
