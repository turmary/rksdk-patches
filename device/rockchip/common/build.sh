#!/bin/bash

export LC_ALL=C
export LD_LIBRARY_PATH=
unset RK_CFG_TOOLCHAIN

err_handler() {
	ret=$?
	[ "$ret" -eq 0 ] && return

	echo "ERROR: Running ${FUNCNAME[1]} failed!"
	echo "ERROR: exit code $ret from line ${BASH_LINENO[0]}:"
	echo "    $BASH_COMMAND"
	exit $ret
}
trap 'err_handler' ERR
set -eE

function finish_build(){
	echo "Running ${FUNCNAME[1]} succeeded."
	cd $TOP_DIR
}

function check_config(){
	unset missing
	for var in $@; do
		eval [ \$$var ] && continue

		missing="$missing $var"
	done

	[ -z "$missing" ] && return 0

	echo "Skipping ${FUNCNAME[1]} for missing configs: $missing."
	return 1
}

function choose_target_board()
{
	echo
	echo "You're building on Linux"
	echo "Launch menu...pick a combo:"
	echo ""

	echo "0. default BoardConfig.mk"
	echo ${RK_TARGET_BOARD_ARRAY[@]} | xargs -n 1 | sed "=" | sed "N;s/\n/. /"

	local INDEX
	read -p "Which would you like? [0]: " INDEX
	INDEX=$((${INDEX:-0} - 1))

	if echo $INDEX | grep -vq [^0-9]; then
		RK_BUILD_TARGET_BOARD="${RK_TARGET_BOARD_ARRAY[$INDEX]}"
	else
		echo "Launching for Default BoardConfig.mk boards..."
		RK_BUILD_TARGET_BOARD=BoardConfig.mk
	fi
}

function build_select_board()
{
	RK_TARGET_BOARD_ARRAY=( $(cd ${TARGET_PRODUCT_DIR}/; ls *.mk | sort) )

	RK_TARGET_BOARD_ARRAY_LEN=${#RK_TARGET_BOARD_ARRAY[@]}
	if [ $RK_TARGET_BOARD_ARRAY_LEN -eq 0 ]; then
		echo "No available Board Config"
		return
	fi

	choose_target_board

	ln -rfs $TARGET_PRODUCT_DIR/$RK_BUILD_TARGET_BOARD device/rockchip/.BoardConfig.mk

	unset RK_PACKAGE_FILE
	source $TARGET_PRODUCT_DIR/$RK_BUILD_TARGET_BOARD
	if [[ x"$RK_PACKAGE_FILE" != x ]];then
		PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware/rockdev/
		cd $PACK_TOOL_DIR
		rm -f package-file
		ln -sf $RK_PACKAGE_FILE package-file
	fi

	if [[ x"$RK_PARAMETER" != x ]];then
		PARAMETER=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_PARAMETER
		ln -sf $PARAMETER $ROCKDEV/parameter.txt
	else
		echo -e "\e[31m error: $SD_PARAMETER not found! \e[0m"
	fi

    MKUPDATE_FILE=${RK_TARGET_PRODUCT}-mkupdate.sh
    if [[ x"$MKUPDATE_FILE" != x-mkupdate.sh ]];then
		PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware/rockdev/
		cd $PACK_TOOL_DIR
		rm -f mkupdate.sh
		ln -sf $MKUPDATE_FILE mkupdate.sh
	fi

	echo "switching to board: `realpath $BOARD_CONFIG`"
}

function unset_board_config_all()
{
	local tmp_file=`mktemp`
	grep -o "^export.*RK_.*=" `find $TOP_DIR/device/rockchip -name "Board*.mk" -type f` -h | sort | uniq > $tmp_file
	source $tmp_file
	rm -f $tmp_file
}

CMD=`realpath $0`
COMMON_DIR=`dirname $CMD`
TOP_DIR=$(realpath $COMMON_DIR/../../..)
IMGNAME=
ROCKDEV=$TOP_DIR/rockdev

BOARD_CONFIG=$TOP_DIR/device/rockchip/.BoardConfig.mk
TARGET_PRODUCT="$TOP_DIR/device/rockchip/.target_product"
TARGET_PRODUCT_DIR=$(realpath ${TARGET_PRODUCT})

if [ ! -L "$BOARD_CONFIG" -a  "$1" != "lunch" ]; then
        build_select_board
fi
unset_board_config_all
[ -L "$BOARD_CONFIG" ] && source $BOARD_CONFIG

CFG_DIR=$TOP_DIR/device/rockchip
PARAMETER=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_PARAMETER
SD_PARAMETER=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_SD_PARAMETER

NPROC=`nproc`
export RK_JOBS=$NPROC

if [ ! -d "$TOP_DIR/rockdev/pack" ];then
	mkdir -p rockdev/pack
fi

function prebuild_uboot()
{
	UBOOT_COMPILE_COMMANDS="\
			${RK_TRUST_INI_CONFIG:+../rkbin/RKTRUST/$RK_TRUST_INI_CONFIG} \
			${RK_SPL_INI_CONFIG:+../rkbin/RKBOOT/$RK_SPL_INI_CONFIG} \
			${RK_UBOOT_SIZE_CONFIG:+--sz-uboot $RK_UBOOT_SIZE_CONFIG} \
			${RK_TRUST_SIZE_CONFIG:+--sz-trust $RK_TRUST_SIZE_CONFIG}"
	UBOOT_COMPILE_COMMANDS="$(echo $UBOOT_COMPILE_COMMANDS)"

	if [ "$RK_LOADER_UPDATE_SPL" = "true" ]; then
		UBOOT_COMPILE_COMMANDS="--spl-new $UBOOT_COMPILE_COMMANDS"
		UBOOT_COMPILE_COMMANDS="$(echo $UBOOT_COMPILE_COMMANDS)"
	fi

	if [ "$RK_RAMDISK_SECURITY_BOOTUP" = "true" ];then
		UBOOT_COMPILE_COMMANDS=" \
			$UBOOT_COMPILE_COMMANDS \
			${RK_ROLLBACK_INDEX_BOOT:+--rollback-index-boot $RK_ROLLBACK_INDEX_BOOT} \
			${RK_ROLLBACK_INDEX_UBOOT:+--rollback-index-uboot $RK_ROLLBACK_INDEX_UBOOT} "
	fi
}

function prebuild_security_uboot()
{
	local mode=$1

	if [ "$RK_RAMDISK_SECURITY_BOOTUP" = "true" ];then
		if [ "$RK_SECURITY_OTP_DEBUG" != "true" ]; then
			UBOOT_COMPILE_COMMANDS="$UBOOT_COMPILE_COMMANDS --burn-key-hash"
		fi

		case "${mode:-normal}" in
			uboot)
				;;
			boot)
				UBOOT_COMPILE_COMMANDS=" \
					--boot_img $TOP_DIR/u-boot/boot.img \
					$UBOOT_COMPILE_COMMANDS "
				;;
			recovery)
				UBOOT_COMPILE_COMMANDS=" \
					--recovery_img $TOP_DIR/u-boot/recovery.img
					$UBOOT_COMPILE_COMMANDS "
				;;
			*)
				UBOOT_COMPILE_COMMANDS=" \
					--boot_img $TOP_DIR/u-boot/boot.img \
					$UBOOT_COMPILE_COMMANDS "
				test -z "${RK_PACKAGE_FILE_AB}" && \
					UBOOT_COMPILE_COMMANDS="$UBOOT_COMPILE_COMMANDS --recovery_img $TOP_DIR/u-boot/recovery.img"
				;;
		esac

		UBOOT_COMPILE_COMMANDS="$(echo $UBOOT_COMPILE_COMMANDS)"
	fi
}

function usagekernel()
{
	check_config RK_KERNEL_DTS RK_KERNEL_DEFCONFIG || return 0

	echo "cd kernel"
	echo "make ARCH=$RK_ARCH $RK_KERNEL_DEFCONFIG $RK_KERNEL_DEFCONFIG_FRAGMENT"
	echo "make ARCH=$RK_ARCH $RK_KERNEL_DTS.img -j$RK_JOBS"
}

function usageuboot()
{
	check_config RK_UBOOT_DEFCONFIG || return 0
	prebuild_uboot
	prebuild_security_uboot $1

	cd u-boot
	echo "cd u-boot"
	if [ -n "$RK_UBOOT_DEFCONFIG_FRAGMENT" ]; then
		if [ -f "configs/${RK_UBOOT_DEFCONFIG}_defconfig" ]; then
			echo "make ${RK_UBOOT_DEFCONFIG}_defconfig $RK_UBOOT_DEFCONFIG_FRAGMENT"
		else
			echo "make ${RK_UBOOT_DEFCONFIG}.config $RK_UBOOT_DEFCONFIG_FRAGMENT"
		fi
		echo "./make.sh $UBOOT_COMPILE_COMMANDS"
	else
		echo "./make.sh $RK_UBOOT_DEFCONFIG $UBOOT_COMPILE_COMMANDS"
	fi

	if [ "$RK_IDBLOCK_UPDATE_SPL" = "true" ]; then
		echo "./make.sh --idblock --spl"
	fi

	finish_build
}

function usagerootfs()
{
	check_config RK_ROOTFS_IMG || return 0

	if [ "${RK_CFG_BUILDROOT}x" != "x" ];then
		echo "source envsetup.sh $RK_CFG_BUILDROOT"
	else
		if [ "${RK_CFG_RAMBOOT}x" != "x" ];then
			echo "source envsetup.sh $RK_CFG_RAMBOOT"
		else
			echo "Not found config buildroot. Please Check !!!"
		fi
	fi

	case "${RK_ROOTFS_SYSTEM:-buildroot}" in
		yocto)
			;;
		debian)
			;;
		*)
			echo "make"
			;;
	esac
}

function usagerecovery()
{
	check_config RK_CFG_RECOVERY || return 0

	echo "source envsetup.sh $RK_CFG_RECOVERY"
	echo "$COMMON_DIR/mk-ramdisk.sh recovery.img $RK_CFG_RECOVERY"
}

function usageramboot()
{
	check_config RK_CFG_RAMBOOT || return 0

	echo "source envsetup.sh $RK_CFG_RAMBOOT"
	echo "$COMMON_DIR/mk-ramdisk.sh ramboot.img $RK_CFG_RAMBOOT"
}

function usagemodules()
{
	check_config RK_KERNEL_DEFCONFIG || return 0

	echo "cd kernel"
	echo "make ARCH=$RK_ARCH $RK_KERNEL_DEFCONFIG"
	echo "make ARCH=$RK_ARCH modules -j$RK_JOBS"
}

function usagesecurity()
{
	case "$1" in
		uboot) usageboot $1;;
		boot)
			usageramboot;
			echo "cp buildroot/output/$RK_CFG_RAMBOOT/images/ramboot.img u-boot/boot.img"
			usageuboot $1;;
		recovery)
			usagerecovery;
			echo "cp buildroot/output/$RK_CFG_RECOVERY/images/recovery.img u-boot/recovery.img"
			usageuboot $1;;
		rootfs)
			usagerootfs;
			usagesecurity boot;;
		*);;
	esac
}

function usagesecurity_uboot()
{
	usageuboot uboot
}

function usagesecurity_boot()
{
	usagesecurity boot
}

function usagesecurity_recovery()
{
	usagesecurity recovery
}

function usagesecurity_rootfs()
{
	usagesecurity rootfs
}

function usage()
{
	echo "Usage: build.sh [OPTIONS]"
	echo "Available options:"
	echo "*.mk               -switch to specified board config"
	echo "lunch              -list current SDK boards and switch to specified board config"
	echo "wifibt             -build wifibt"
	echo "uboot              -build uboot"
	echo "uefi		 -build uefi"
	echo "spl                -build spl"
	echo "loader             -build loader"
	echo "kernel             -build kernel"
	echo "modules            -build kernel modules"
	echo "toolchain          -build toolchain"
	echo "extboot            -build extlinux boot.img, boot from EFI partition"
	echo "rootfs             -build default rootfs, currently build buildroot as default"
	echo "rootfs_inst_mods   -install kernel modules to rootfs image"
	echo "buildroot          -build buildroot rootfs"
	echo "ramboot            -build ramboot image"
	echo "multi-npu_boot     -build boot image for multi-npu board"
	echo "yocto              -build yocto rootfs"
	echo "debian             -build debian rootfs"
	echo "pcba               -build pcba"
	echo "recovery           -build recovery"
	echo "all                -build uboot, kernel, rootfs, recovery image"
	echo "cleanall           -clean uboot, kernel, rootfs, recovery"
	echo "firmware           -pack all the image we need to boot up system"
	echo "updateimg          -pack update image"
	echo "pupdateimg         -pack the image, add release information and compress the 7z format"
	echo "rawimg             -pack raw image"
	echo "otapackage         -pack ab update otapackage image (update_ota.img)"
	echo "sdpackage          -pack update sdcard package image (update_sdcard.img)"
	echo "save               -save images, patches, commands used to debug"
	echo "allsave            -build all & firmware & updateimg & save"
	echo "check              -check the environment of building"
	echo "info               -see the current board building information"
	echo "app/<pkg>          -build packages in the dir of app/*"
	echo "external/<pkg>     -build packages in the dir of external/*"
	echo ""
	echo "createkeys         -create secureboot root keys"
	echo "security_rootfs    -build rootfs and some relevant images with security paramter (just for dm-v)"
	echo "security_boot      -build boot with security paramter"
	echo "security_uboot     -build uboot with security paramter"
	echo "security_recovery  -build recovery with security paramter"
	echo "security_check     -check security paramter if it's good"
	echo ""
	echo "Default option is 'allsave'."
}

function build_info(){
	if [ ! -L $TARGET_PRODUCT_DIR ];then
		echo "No found target product!!!"
	fi
	if [ ! -L $BOARD_CONFIG ];then
		echo "No found target board config!!!"
	fi

	if [ -f .repo/manifest.xml ]; then
		local sdk_ver=""
		sdk_ver=`grep "include name"  .repo/manifest.xml | awk -F\" '{print $2}'`
		sdk_ver=`realpath .repo/manifests/${sdk_ver}`
		echo "Build SDK version: `basename ${sdk_ver}`"
	else
		echo "Not found .repo/manifest.xml [ignore] !!!"
	fi

	echo "Current Building Information:"
	echo "Target Product: $TARGET_PRODUCT_DIR"
	echo "Target BoardConfig: `realpath $BOARD_CONFIG`"
	echo "Target Misc config:"
	echo "`env |grep "^RK_" | grep -v "=$" | sort`"

	local kernel_file_dtb

	if [ "$RK_ARCH" == "arm" ]; then
		kernel_file_dtb="${TOP_DIR}/kernel/arch/arm/boot/dts/${RK_KERNEL_DTS}.dtb"
	else
		kernel_file_dtb="${TOP_DIR}/kernel/arch/arm64/boot/dts/rockchip/${RK_KERNEL_DTS}.dtb"
	fi

	rm -f $kernel_file_dtb

	cd kernel
	make ARCH=$RK_ARCH dtbs -j$RK_JOBS
}

function build_check_power_domain(){
	local dump_kernel_dtb_file
	local tmp_phandle_file
	local tmp_io_domain_file
	local tmp_regulator_microvolt_file
	local tmp_final_target
	local tmp_none_item
	local kernel_file_dtb_dts

	if [ "$RK_ARCH" == "arm" ]; then
		kernel_file_dtb_dts="${TOP_DIR}/kernel/arch/arm/boot/dts/$RK_KERNEL_DTS"
	else
		kernel_file_dtb_dts="${TOP_DIR}/kernel/arch/arm64/boot/dts/rockchip/$RK_KERNEL_DTS"
	fi

	dump_kernel_dtb_file=${kernel_file_dtb_dts}.dump.dts
	tmp_phandle_file=`mktemp`
	tmp_io_domain_file=`mktemp`
	tmp_regulator_microvolt_file=`mktemp`
	tmp_final_target=`mktemp`
	tmp_grep_file=`mktemp`

	dtc -I dtb -O dts -o ${dump_kernel_dtb_file} ${kernel_file_dtb_dts}.dtb 2>/dev/null

	if [ "$RK_SYSTEM_CHECK_METHOD" = "DM-E" ] ; then
		if ! grep "compatible = \"linaro,optee-tz\";" $dump_kernel_dtb_file > /dev/null 2>&1 ; then
			echo "Please add: "
			echo "        optee: optee {"
			echo "                compatible = \"linaro,optee-tz\";"
			echo "                method = \"smc\";"
			echo "                status = \"okay\";"
			echo "        }"
			echo "To your dts file"
			return -1;
		fi
	fi

	if ! grep -Pzo "io-domains\s*{(\n|\w|-|;|=|<|>|\"|_|\s|,)*};" $dump_kernel_dtb_file 1>$tmp_grep_file 2>/dev/null; then
		echo "Not Found io-domains in ${kernel_file_dtb_dts}.dts"
		rm -f $tmp_grep_file
		return 0
	fi
	grep -a supply $tmp_grep_file > $tmp_io_domain_file
	rm -f $tmp_grep_file
	awk '{print "phandle = " $3}' $tmp_io_domain_file > $tmp_phandle_file


	while IFS= read -r item_phandle && IFS= read -u 3 -r item_domain
	do
		echo "${item_domain% *}" >> $tmp_regulator_microvolt_file
		tmp_none_item=${item_domain% *}
		cmds="grep -Pzo \"{(\\n|\w|-|;|=|<|>|\\\"|_|\s)*"$item_phandle\"

		eval "$cmds $dump_kernel_dtb_file | strings | grep "regulator-m..-microvolt" >> $tmp_regulator_microvolt_file" || \
			eval "sed -i \"/${tmp_none_item}/d\" $tmp_regulator_microvolt_file" && continue

		echo >> $tmp_regulator_microvolt_file
	done < $tmp_phandle_file 3<$tmp_io_domain_file

	while read -r regulator_val
	do
		if echo ${regulator_val} | grep supply &>/dev/null; then
			echo -e "\n\n\e[1;33m${regulator_val%*=}\e[0m" >> $tmp_final_target
		else
			tmp_none_item=${regulator_val##*<}
			tmp_none_item=${tmp_none_item%%>*}
			echo -e "${regulator_val%%<*} \e[1;31m$(( $tmp_none_item / 1000 ))mV\e[0m" >> $tmp_final_target
		fi
	done < $tmp_regulator_microvolt_file

	echo -e "\e[41;1;30m PLEASE CHECK BOARD GPIO POWER DOMAIN CONFIGURATION !!!!!\e[0m"
	echo -e "\e[41;1;30m <<< ESPECIALLY Wi-Fi/Flash/Ethernet IO power domain >>> !!!!!\e[0m"
	echo -e "\e[41;1;30m Check Node [pmu_io_domains] in the file: ${kernel_file_dtb_dts}.dts \e[0m"
	echo
	echo -e "\e[41;1;30m 请再次确认板级的电源域配置！！！！！！\e[0m"
	echo -e "\e[41;1;30m <<< 特别是Wi-Fi，FLASH，以太网这几路IO电源的配置 >>> ！！！！！\e[0m"
	echo -e "\e[41;1;30m 检查内核文件 ${kernel_file_dtb_dts}.dts 的节点 [pmu_io_domains] \e[0m"
	cat $tmp_final_target

	rm -f $tmp_phandle_file
	rm -f $tmp_regulator_microvolt_file
	rm -f $tmp_io_domain_file
	rm -f $tmp_final_target
	rm -f $dump_kernel_dtb_file
}

function build_check_cross_compile(){

	case $RK_ARCH in
	arm|armhf)
		if [ "$RK_TARGET_PRODUCT" = "rv1126_rv1109" ];then
			if [ -d "$TOP_DIR/prebuilts/gcc/linux-x86/arm/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabihf" ]; then
				CROSS_COMPILE=$(realpath $TOP_DIR)/prebuilts/gcc/linux-x86/arm/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabihf/bin/arm-rockchip830-linux-gnueabihf-
			fi
		else
			if [ -d "$TOP_DIR/prebuilts/gcc/linux-x86/arm/gcc-arm-10.3-2021.07-x86_64-arm-none-linux-gnueabihf" ]; then
				CROSS_COMPILE=$(realpath $TOP_DIR)/prebuilts/gcc/linux-x86/arm/gcc-arm-10.3-2021.07-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-
			fi
		fi
		export CROSS_COMPILE=$CROSS_COMPILE
		;;
	arm64|aarch64)
		if [ -d "$TOP_DIR/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu" ]; then
			CROSS_COMPILE=$(realpath $TOP_DIR)/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-
		export CROSS_COMPILE=$CROSS_COMPILE
		fi
		;;
	*)
		echo "the $RK_ARCH not supported for now, please check it again\n"
		;;
	esac
}

function build_check(){
	local build_depend_cfg="build-depend-tools.txt"
	common_product_build_tools="$TOP_DIR/device/rockchip/common/$build_depend_cfg"
	target_product_build_tools="$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$build_depend_cfg"
	cat $common_product_build_tools $target_product_build_tools 2>/dev/null | while read chk_item
		do
			chk_item=${chk_item###*}
			echo $chk_item
			if [ -z "$chk_item" ]; then
				continue
			fi

			dst=${chk_item%%,*}
			src=${chk_item##*,}
			echo "**************************************"
			if eval $dst &>/dev/null;then
				echo "Check [OK]: $dst"
			else
				echo "Please install ${dst%% *} first"
				echo "    sudo apt-get install $src"
			fi
		done
}

function build_pkg() {
	check_config RK_CFG_BUILDROOT || check_config RK_CFG_RAMBOOT || check_config RK_CFG_RECOVERY || check_config RK_CFG_PCBA || return 0

	local target_pkg=$1
	target_pkg=${target_pkg%*/}

	if [ ! -d $target_pkg ];then
		echo "build pkg: error: not found package $target_pkg"
		return 1
	fi

	if ! eval [ $rk_package_mk_arrry ];then
		rk_package_mk_arrry=( $(find buildroot/package/rockchip/ -name "*.mk" | sort) )
	fi

	local pkg_mk pkg_config_in pkg_br pkg_final_target pkg_final_target_upper pkg_cfg

	for it in ${rk_package_mk_arrry[@]}
	do
		pkg_final_target=$(basename $it)
		pkg_final_target=${pkg_final_target%%.mk*}
		pkg_final_target_upper=${pkg_final_target^^}
		pkg_final_target_upper=${pkg_final_target_upper//-/_}
		if grep "${pkg_final_target_upper}_SITE.*$target_pkg" $it &>/dev/null; then
			pkg_mk=$it
			pkg_config_in=$(dirname $pkg_mk)/Config.in
			pkg_br=BR2_PACKAGE_$pkg_final_target_upper

			for cfg in RK_CFG_BUILDROOT RK_CFG_RAMBOOT RK_CFG_RECOVERY RK_CFG_PCBA
			do
				if eval [ \$$cfg ] ;then
					pkg_cfg=$( eval "echo \$$cfg" )
					if grep -wq ${pkg_br}=y buildroot/output/$pkg_cfg/.config; then
						echo "Found $pkg_br in buildroot/output/$pkg_cfg/.config "
						make -C buildroot/output/$pkg_cfg ${pkg_final_target}-dirclean O=buildroot/output/$pkg_cfg
						make -C buildroot/output/$pkg_cfg ${pkg_final_target}-rebuild O=buildroot/output/$pkg_cfg
					else
						echo "[SKIP BUILD $target_pkg] NOT Found ${pkg_br}=y in buildroot/output/$pkg_cfg/.config"
					fi
				fi
			done
		fi
	done

	finish_build
}

function build_uefi(){
	build_check_cross_compile
	local kernel_file_dtb

	if [ "$RK_ARCH" == "arm" ]; then
		kernel_file_dtb="${TOP_DIR}/kernel/arch/arm/boot/dts/${RK_KERNEL_DTS}.dtb"
	else
		kernel_file_dtb="${TOP_DIR}/kernel/arch/arm64/boot/dts/rockchip/${RK_KERNEL_DTS}.dtb"
	fi

	echo "============Start building uefi============"
	echo "Copy kernel dtb $kernel_file_dtb to uefi/edk2-platforms/Platform/Rockchip/DeviceTree/rk3588.dtb"
	echo "========================================="
	if [ ! -f $kernel_file_dtb ]; then
		echo "Please compile the kernel before"
		return -1
	fi

	cp $kernel_file_dtb uefi/edk2-platforms/Platform/Rockchip/DeviceTree/rk3588.dtb
	cd uefi
	./make.sh $RK_UBOOT_DEFCONFIG
	cd -

	finish_build
}

function build_uboot(){
	check_config RK_UBOOT_DEFCONFIG || return 0
	build_check_cross_compile
	prebuild_uboot
	prebuild_security_uboot $@

	echo "============Start building uboot============"
	echo "TARGET_UBOOT_CONFIG=$RK_UBOOT_DEFCONFIG"
	echo "========================================="

	cd u-boot
	rm -f *_loader_*.bin
	if [ "$RK_LOADER_UPDATE_SPL" = "true" ]; then
		rm -f *spl.bin
	fi

	if [ -n "$RK_UBOOT_DEFCONFIG_FRAGMENT" ]; then
		if [ -f "configs/${RK_UBOOT_DEFCONFIG}_defconfig" ]; then
			make ${RK_UBOOT_DEFCONFIG}_defconfig $RK_UBOOT_DEFCONFIG_FRAGMENT
		else
			make ${RK_UBOOT_DEFCONFIG}.config $RK_UBOOT_DEFCONFIG_FRAGMENT
		fi

		if [ -n "$CROSS_COMPILE" ];then
		        ./make.sh $UBOOT_COMPILE_COMMANDS CROSS_COMPILE=$CROSS_COMPILE
		else
		        ./make.sh $UBOOT_COMPILE_COMMANDS
		fi

	elif [ -d "$TOP_DIR/prebuilts/gcc/linux-x86/arm/gcc-arm-10.3-2021.07-x86_64-arm-none-linux-gnueabihf" ]; then
		./make.sh $RK_UBOOT_DEFCONFIG \
			$UBOOT_COMPILE_COMMANDS CROSS_COMPILE=$CROSS_COMPILE
	elif [ -d "$TOP_DIR/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu" ]; then
		./make.sh $RK_UBOOT_DEFCONFIG \
			$UBOOT_COMPILE_COMMANDS CROSS_COMPILE=$CROSS_COMPILE
	else
		./make.sh $RK_UBOOT_DEFCONFIG \
			$UBOOT_COMPILE_COMMANDS
	fi

	if [ "$RK_IDBLOCK_UPDATE" = "true" ]; then
		./make.sh --idblock
	fi

	if [ "$RK_LOADER_UPDATE_TPL" = "true" ]; then
		./make.sh --tpl
	fi

	if [ "$RK_IDBLOCK_UPDATE_SPL" = "true" ]; then
		./make.sh --idblock --spl
	fi

	if [ "$RK_RAMDISK_SECURITY_BOOTUP" = "true" ];then
		ln -rsf $TOP_DIR/u-boot/boot.img $TOP_DIR/rockdev/
		test -z "${RK_PACKAGE_FILE_AB}" && \
			ln -rsf $TOP_DIR/u-boot/recovery.img $TOP_DIR/rockdev/ || true
	fi

	finish_build
}

# TODO: build_spl can be replaced by build_uboot with define RK_LOADER_UPDATE_SPL
function build_spl(){
	check_config RK_SPL_DEFCONFIG || return 0

	echo "============Start building spl============"
	echo "TARGET_SPL_CONFIG=$RK_SPL_DEFCONFIG"
	echo "========================================="
	if [ -f u-boot/*spl.bin ]; then
		rm u-boot/*spl.bin
	fi
	cd u-boot && ./make.sh $RK_SPL_DEFCONFIG && ./make.sh spl-s && cd -
	if [ $? -eq 0 ]; then
		echo "====Build spl ok!===="
	else
		echo "====Build spl failed!===="
		exit 1
	fi

	finish_build
}

function build_loader(){
	check_config RK_LOADER_BUILD_TARGET || return 0

	echo "============Start building loader============"
	echo "RK_LOADER_BUILD_TARGET=$RK_LOADER_BUILD_TARGET"
	echo "=========================================="
	cd loader && ./build.sh $RK_LOADER_BUILD_TARGET && cd -
	if [ $? -eq 0 ]; then
		echo "====Build loader ok!===="
	else
		echo "====Build loader failed!===="
		exit 1
	fi

	finish_build
}

function build_kernel(){
	check_config RK_KERNEL_DTS RK_KERNEL_DEFCONFIG || return 0

	echo "============Start building kernel============"
	echo "TARGET_ARCH          =$RK_ARCH"
	echo "TARGET_KERNEL_CONFIG =$RK_KERNEL_DEFCONFIG"
	echo "TARGET_KERNEL_DTS    =$RK_KERNEL_DTS"
	echo "TARGET_KERNEL_CONFIG_FRAGMENT =$RK_KERNEL_DEFCONFIG_FRAGMENT"
	echo "=========================================="
	pwd

	build_check_cross_compile

	cd kernel
	make ARCH=$RK_ARCH $RK_KERNEL_DEFCONFIG $RK_KERNEL_DEFCONFIG_FRAGMENT
	make ARCH=$RK_ARCH $RK_KERNEL_DTS.img -j$RK_JOBS
	if [ -f "$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_KERNEL_FIT_ITS" ]; then
		$COMMON_DIR/mk-fitimage.sh $TOP_DIR/kernel/$RK_BOOT_IMG \
			$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_KERNEL_FIT_ITS \
			$TOP_DIR/kernel/ramdisk.img
	fi

	if [ -f "$TOP_DIR/kernel/$RK_BOOT_IMG" ]; then
		mkdir -p $TOP_DIR/rockdev
		ln -sf  $TOP_DIR/kernel/$RK_BOOT_IMG $TOP_DIR/rockdev/boot.img
	fi

	if [ "$RK_RAMDISK_SECURITY_BOOTUP" = "true" ];then
		cp $TOP_DIR/kernel/$RK_BOOT_IMG \
			$TOP_DIR/u-boot/boot.img
	fi

	finish_build
}

function build_kerneldeb(){
	check_config RK_KERNEL_DTS RK_KERNEL_DEFCONFIG || return 0

	build_check_cross_compile

	echo "============Start building kernel deb============"
	echo "TARGET_ARCH          =$RK_ARCH"
	echo "TARGET_KERNEL_CONFIG =$RK_KERNEL_DEFCONFIG"
	echo "TARGET_KERNEL_DTS    =$RK_KERNEL_DTS"
	echo "TARGET_KERNEL_CONFIG_FRAGMENT =$RK_KERNEL_DEFCONFIG_FRAGMENT"
	echo "=========================================="
	pwd
	cd kernel
	make ARCH=$RK_ARCH $RK_KERNEL_DEFCONFIG $RK_KERNEL_DEFCONFIG_FRAGMENT
	make ARCH=$RK_ARCH bindeb-pkg RK_KERNEL_DTS=$RK_KERNEL_DTS -j$RK_JOBS
	finish_build
}

function build_extboot(){
	check_config RK_KERNEL_DTS RK_KERNEL_DEFCONFIG || return 0

	echo "============Start building kernel============"
	echo "TARGET_ARCH          =$RK_ARCH"
	echo "TARGET_KERNEL_CONFIG =$RK_KERNEL_DEFCONFIG"
	echo "TARGET_KERNEL_DTS    =$RK_KERNEL_DTS"
	echo "TARGET_KERNEL_CONFIG_FRAGMENT =$RK_KERNEL_DEFCONFIG_FRAGMENT"
	echo "=========================================="
	pwd

	build_check_cross_compile

	cd kernel
	make ARCH=$RK_ARCH $RK_KERNEL_DEFCONFIG $RK_KERNEL_DEFCONFIG_FRAGMENT
	make ARCH=$RK_ARCH $RK_KERNEL_DTS.img -j$RK_JOBS

	echo -e "\e[36m Generate extLinuxBoot image start\e[0m"

	EXTBOOT_IMG=${TOP_DIR}/kernel/extboot.img
	EXTBOOT_DIR=${TOP_DIR}/kernel/extboot
	rm -rf ${EXTBOOT_DIR} && mkdir -p ${EXTBOOT_DIR}/extlinux

    KERNEL_VERSION=$(cat $TOP_DIR/kernel/include/config/kernel.release)
	echo "label rk-kernel.dtb linux-$KERNEL_VERSION" > $EXTBOOT_DIR/extlinux/extlinux.conf

    cp ${TOP_DIR}/$RK_KERNEL_IMG $EXTBOOT_DIR/Image-$KERNEL_VERSION
	echo -e "\tkernel /Image-$KERNEL_VERSION" >> $EXTBOOT_DIR/extlinux/extlinux.conf

    if [ -f $CFG_DIR/$RK_TARGET_PRODUCT/.$RK_PRODUCT_MODEL ];then
	dtblist=$(cat $CFG_DIR/$RK_TARGET_PRODUCT/.$RK_PRODUCT_MODEL)
	for i in $dtblist
	do
		if [ "$RK_ARCH" == "arm64" ];then
			make ARCH=$RK_ARCH rockchip/$i.dtb -j$RK_JOBS
			cp ${TOP_DIR}/kernel/arch/${RK_ARCH}/boot/dts/rockchip/$i.dtb $EXTBOOT_DIR
		else
			make ARCH=$RK_ARCH $i.dtb -j$RK_JOBS
			cp ${TOP_DIR}/kernel/arch/${RK_ARCH}/boot/dts/$i.dtb $EXTBOOT_DIR
		fi
	done
    fi

    if [ "$RK_ARCH" == "arm64" ];then
    	cp ${TOP_DIR}/kernel/arch/${RK_ARCH}/boot/dts/rockchip/${RK_KERNEL_DTS}.dtb $EXTBOOT_DIR
    else
    	cp ${TOP_DIR}/kernel/arch/${RK_ARCH}/boot/dts/${RK_KERNEL_DTS}.dtb $EXTBOOT_DIR
    fi
    ln -sf ${RK_KERNEL_DTS}.dtb $EXTBOOT_DIR/rk-kernel.dtb

    echo -e "\tfdt /rk-kernel.dtb" >> $EXTBOOT_DIR/extlinux/extlinux.conf

    if [[ -e ${TOP_DIR}/kernel/ramdisk.img ]]; then
        cp ${TOP_DIR}/kernel/ramdisk.img $EXTBOOT_DIR/initrd-$KERNEL_VERSION
        echo -e "\tinitrd /initrd-$KERNEL_VERSION" >> $EXTBOOT_DIR/extlinux/extlinux.conf
    fi

    cp ${TOP_DIR}/kernel/.config $EXTBOOT_DIR/config-$KERNEL_VERSION
    cp ${TOP_DIR}/kernel/System.map $EXTBOOT_DIR/System.map-$KERNEL_VERSION
    cp ${TOP_DIR}/kernel/*.bmp $EXTBOOT_DIR/ || true

    make ARCH=$RK_ARCH INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=$EXTBOOT_DIR modules_install

    if [ -n "$FF_EXTBOOT_SIZE" ];then
	EXTBOOT_IMG_SIZE=$FF_EXTBOOT_SIZE
    else
	EXTBOOT_IMG_SIZE=128M
    fi

    rm -rf $EXTBOOT_IMG && truncate -s $EXTBOOT_IMG_SIZE $EXTBOOT_IMG
    fakeroot ${TOP_DIR}/device/rockchip/common/mkfs.ext4 -Fq -L "boot" -d $EXTBOOT_DIR $EXTBOOT_IMG
    finish_build
}

function build_wifibt(){
	build_check_cross_compile
	case $RK_ARCH in
	arm|armhf)
		WIFI_ARCH=arm
		RKWIFIBT_APP_GCC=$TOP_DIR/buildroot/output/$RK_CFG_BUILDROOT/host/bin/arm-buildroot-linux-gnueabihf-gcc
		RKWIFIBT_APP_SYSROOT=$TOP_DIR/buildroot/output/$RK_CFG_BUILDROOT/host/arm-buildroot-linux-gnueabihf/sysroot
		;;
	arm64|aarch64)
		WIFI_ARCH=arm64
		RKWIFIBT_APP_GCC=$TOP_DIR/buildroot/output/$RK_CFG_BUILDROOT/host/bin/aarch64-buildroot-linux-gnu-gcc
		RKWIFIBT_APP_SYSROOT=$TOP_DIR/buildroot/output/$RK_CFG_BUILDROOT/host/aarch64-buildroot-linux-gnu/sysroot
		;;
	esac

	if [ -n "$1" ]; then
		WIFI_CHIP=$1
	elif [ -n "$RK_WIFIBT_CHIP" ]; then
		WIFI_CHIP=$RK_WIFIBT_CHIP
	else
		# defile ALL_AP
		echo "=== WARNNING WIFI_CHIP is NULL so default to ALL_AP ==="
		WIFI_CHIP=ALL_AP
	fi

	if [ -n "$2" ]; then
		BT_TTY_DEV=$2
	elif [ -n "$RK_WIFIBT_TTY" ]; then
		BT_TTY_DEV=$RK_WIFIBT_TTY
	else
		echo "=== WARNNING BT_TTY is NULL so default to ttyS0 ==="
		BT_TTY_DEV=ttyS0
	fi

	#check kernel .config
	WIFI_USB=`grep "CONFIG_USB=y" $TOP_DIR/kernel/.config` || true
	WIFI_SDIO=`grep "CONFIG_MMC=y" $TOP_DIR/kernel/.config` || true
	WIFI_PCIE=`grep "CONFIG_PCIE_DW_ROCKCHIP=y" $TOP_DIR/kernel/.config` || true
	WIFI_RFKILL=`grep "CONFIG_RFKILL=y" $TOP_DIR/kernel/.config` || true
	if [ -z "WIFI_SDIO" ]; then
		echo "=== WARNNING CONFIG_MMC not set !!! ==="
	fi
	if [ -z "WIFI_RFKILL" ]; then
		echo "=== WARNNING CONFIG_USB not set !!! ==="
	fi
	if [[ "$WIFI_CHIP" =~ "U" ]];then
		if [ -z "$WIFI_USB" ]; then
			echo "=== WARNNING CONFIG_USB not set so ABORT!!! ==="
			exit 0
		fi
	fi
	echo "kernel config: $WIFI_USB $WIFI_SDIO $WIFI_RFKILL"

	TARGET_CC=${CROSS_COMPILE}gcc
	RKWIFIBT=$TOP_DIR/external/rkwifibt
	RKWIFIBT_APP=$TOP_DIR/external/rkwifibt-app
	TARGET_ROOTFS_DIR=$TOP_DIR/buildroot/output/$RK_CFG_BUILDROOT/target

	echo "========build wifibt info======="
	echo CROSS_COMPILE=$CROSS_COMPILE
	echo WIFI_CHIP=$WIFI_CHIP
	echo BT_TTY_DEV=$BT_TTY_DEV
	echo TARGET_ROOTFS_DIR=$TARGET_ROOTFS_DIR
	echo RKWIFIBT_APP_GCC=$RKWIFIBT_APP_GCC
	echo RKWIFIBT_APP_SYSROOT=$RKWIFIBT_APP_SYSROOT

	if [[ "$WIFI_CHIP" =~ "ALL_AP" ]];then
		echo "building bcmdhd sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/bcmdhd CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8 CONFIG_BCMDHD=m CONFIG_BCMDHD_SDIO=y CONFIG_BCMDHD_PCIE=
		if [ -n "$WIFI_PCIE" ]; then
			echo "building bcmdhd pcie"
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/bcmdhd CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8 CONFIG_BCMDHD=m CONFIG_BCMDHD_PCIE=y CONFIG_BCMDHD_SDIO=
		fi
		if [ -n "$WIFI_USB" ]; then
			echo "building rtl8188fu usb"
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8188fu CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		fi
		echo "building rtl8189fs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8189fs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8723ds sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8723ds CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8821cs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8821cs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8822cs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8822cs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8852bs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8852bs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8 DRV_PATH=$RKWIFIBT/drivers/rtl8852bs
		if [ -n "$WIFI_PCIE" ]; then
			echo "building rtl8852be pcie"
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8852be CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8 DRV_PATH=$RKWIFIBT/drivers/rtl8852be
		fi
	fi

	if [[ "$WIFI_CHIP" =~ "ALL_CY" ]];then
		echo "building CYW4354"
		cp $RKWIFIBT/drivers/infineon/chips/CYW4354_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
		echo "building CYW4373"
		cp $RKWIFIBT/drivers/infineon/chips/CYW4373_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
		echo "building CYW43438"
		cp $RKWIFIBT/drivers/infineon/chips/CYW43438_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
		echo "building CYW43455"
		cp $RKWIFIBT/drivers/infineon/chips/CYW43455_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
		echo "building CYW5557X"
		cp $RKWIFIBT/drivers/infineon/chips/CYW5557X_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
		if [ -n "$WIFI_PCIE" ]; then
			echo "building CYW5557X_PCIE"
			cp $RKWIFIBT/drivers/infineon/chips/CYW5557X_PCIE_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
			echo "building CYW54591_PCIE"
			cp $RKWIFIBT/drivers/infineon/chips/CYW54591_PCIE_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
		fi
		echo "building CYW54591"
		cp $RKWIFIBT/drivers/infineon/chips/CYW54591_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8

		if [ -n "$WIFI_USB" ]; then
			echo "building rtl8188fu usb"
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8188fu CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		fi
		echo "building rtl8189fs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8189fs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8723ds sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8723ds CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8821cs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8821cs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8822cs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8822cs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8
		echo "building rtl8852bs sdio"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8852bs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8 DRV_PATH=$RKWIFIBT/drivers/rtl8852bs
		if [ -n "$WIFI_PCIE" ]; then
			echo "building rtl8852be pcie"
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8852be CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j8 DRV_PATH=$RKWIFIBT/drivers/rtl8852be
		fi
	fi

	if [[ "$WIFI_CHIP" =~ "AP6" ]];then
		if [[ "$WIFI_CHIP" = "AP6275_PCIE" ]];then
			echo "building bcmdhd pcie driver"
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/bcmdhd CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8 CONFIG_BCMDHD=m CONFIG_BCMDHD_PCIE=y CONFIG_BCMDHD_SDIO=
		else
			echo "building bcmdhd sdio driver"
			make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/bcmdhd CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8 CONFIG_BCMDHD=m CONFIG_BCMDHD_SDIO=y CONFIG_BCMDHD_PCIE=
		fi
	fi

	if [[ "$WIFI_CHIP" = "CYW4354" ]];then
		echo "building CYW4354"
		cp $RKWIFIBT/drivers/infineon/chips/CYW4354_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "CYW4373" ]];then
		echo "building CYW4373"
		cp $RKWIFIBT/drivers/infineon/chips/CYW4373_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "CYW43438" ]];then
		echo "building CYW43438"
		cp $RKWIFIBT/drivers/infineon/chips/CYW43438_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "CYW43455" ]];then
		echo "building CYW43455"
		cp $RKWIFIBT/drivers/infineon/chips/CYW43455_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "CYW5557X" ]];then
		echo "building CYW5557X"
		cp $RKWIFIBT/drivers/infineon/chips/CYW5557X_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "CYW5557X_PCIE" ]];then
		echo "building CYW5557X_PCIE"
		cp $RKWIFIBT/drivers/infineon/chips/CYW5557X_PCIE_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "CYW54591" ]];then
		echo "building CYW54591"
		cp $RKWIFIBT/drivers/infineon/chips/CYW54591_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "CYW54591_PCIE" ]];then
		echo "building CYW54591_PCIE"
		cp $RKWIFIBT/drivers/infineon/chips/CYW54591_PCIE_Makefile $RKWIFIBT/drivers/infineon/Makefile -r
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/infineon CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH -j8
	fi

	if [[ "$WIFI_CHIP" = "RTL8188FU" ]];then
		echo "building rtl8188fu driver"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8188fu CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j32
	fi

	if [[ "$WIFI_CHIP" = "RTL8189FS" ]];then
		echo "building rtl8189fs driver"
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8189fs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j32
	fi

	if [[ "$WIFI_CHIP" = "RTL8723DS" ]];then
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8723ds CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j32
	fi

	if [[ "$WIFI_CHIP" = "RTL8821CS" ]];then
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8821cs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j32
	fi

	if [[ "$WIFI_CHIP" = "RTL8822CS" ]];then
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8822cs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j32
	fi

	if [[ "$WIFI_CHIP" = "RTL8852BS" ]];then
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8852bs CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j32
	fi

	if [[ "$WIFI_CHIP" = "RTL8852BE" ]];then
		make -C $TOP_DIR/kernel M=$RKWIFIBT/drivers/rtl8852be CROSS_COMPILE=$CROSS_COMPILE ARCH=$WIFI_ARCH modules -j32
	fi

	echo "building brcm_tools"
	$TARGET_CC -o $RKWIFIBT/tools/brcm_tools/brcm_patchram_plus1 $RKWIFIBT/tools/brcm_tools/brcm_patchram_plus1.c
	$TARGET_CC -o $RKWIFIBT/tools/brcm_tools/dhd_priv $RKWIFIBT/tools/brcm_tools/dhd_priv.c

	echo "building rk_wifibt_init"
	$TARGET_CC -o $RKWIFIBT/src/rk_wifibt_init $RKWIFIBT/src/rk_wifi_init.c

	echo "building realtek_tools"
	make -C $RKWIFIBT/tools/rtk_hciattach/ CC=$TARGET_CC

	echo "building realtek bt drivers"
	make -C $TOP_DIR/kernel/ M=$RKWIFIBT/drivers/bluetooth_uart_driver ARCH=$WIFI_ARCH CROSS_COMPILE=$CROSS_COMPILE
	if [ -n "$WIFI_USB" ]; then
		make -C $TOP_DIR/kernel/ M=$RKWIFIBT/drivers/bluetooth_usb_driver ARCH=$WIFI_ARCH CROSS_COMPILE=$CROSS_COMPILE
	fi

	if [ "$RK_TARGET_PRODUCT" = "rv1126_rv1109" ];then
		echo "target is rv1126_rv1109, skip $RKWIFIBT_APP"
	else
		echo "building rkwifibt-app"
		make -C $RKWIFIBT_APP CC=$RKWIFIBT_APP_GCC SYSROOT=$RKWIFIBT_APP_SYSROOT ARCH=$RK_ARCH
	fi

	echo "chmod +x tools"
	chmod 755 $RKWIFIBT/tools/brcm_tools/brcm_patchram_plus1
	chmod 755 $RKWIFIBT/tools/brcm_tools/dhd_priv
	chmod 755 $RKWIFIBT/src/rk_wifibt_init
	chmod 755 $RKWIFIBT/tools/rtk_hciattach/rtk_hciattach

	echo "mkdir rootfs dir" $TARGET_ROOTFS_DIR
	rm -rf $TARGET_ROOTFS_DIR/system/lib/modules/
	rm -rf $TARGET_ROOTFS_DIR/system/etc/firmware/
	rm -rf $TARGET_ROOTFS_DIR/vendor/
        rm -rf $TARGET_ROOTFS_DIR/usr/lib/modules/
        mkdir -p $TARGET_ROOTFS_DIR/usr/lib/modules/
	mkdir -p $TARGET_ROOTFS_DIR/system/lib/modules/
	mkdir -p $TARGET_ROOTFS_DIR/system/etc/firmware/
	mkdir -p $TARGET_ROOTFS_DIR/lib/firmware/rtlbt/

	echo "create link system->vendor"
	cd $TARGET_ROOTFS_DIR/
	rm -rf $TARGET_ROOTFS_DIR/vendor
	ln -sf system $TARGET_ROOTFS_DIR/vendor
	cd -

	echo "copy tools/sh to rootfs"
	cp $RKWIFIBT/bin/$WIFI_ARCH/* $TARGET_ROOTFS_DIR/usr/bin/
	cp $RKWIFIBT/sh/wifi_start.sh $TARGET_ROOTFS_DIR/usr/bin/
	cp $RKWIFIBT/sh/wifi_ap6xxx_rftest.sh $TARGET_ROOTFS_DIR/usr/bin/
	cp $RKWIFIBT/conf/wpa_supplicant.conf $TARGET_ROOTFS_DIR/etc/
	cp $RKWIFIBT/conf/dnsmasq.conf $TARGET_ROOTFS_DIR/etc/
	cp $RKWIFIBT/tools/brcm_tools/dhd_priv $TARGET_ROOTFS_DIR/usr/bin/
	cp $RKWIFIBT/tools/brcm_tools/brcm_patchram_plus1 $TARGET_ROOTFS_DIR/usr/bin/
	cp $RKWIFIBT/src/rk_wifibt_init $TARGET_ROOTFS_DIR/usr/bin/

	if [[ "$WIFI_CHIP" = "ALL_CY" ]];then
		echo "copy infineon/realtek firmware/nvram to rootfs"
		cp $RKWIFIBT/drivers/infineon/*.ko $TARGET_ROOTFS_DIR/system/lib/modules/ || true
		cp $RKWIFIBT/firmware/infineon/*/* $TARGET_ROOTFS_DIR/system/etc/firmware/ || true

		#todo rockchip
		#cp $RKWIFIBT/firmware/rockchip/* $TARGET_ROOTFS_DIR/system/etc/firmware/
		cp $RKWIFIBT/sh/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_init.sh
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_pcba_test

		#reatek
		cp $RKWIFIBT/firmware/realtek/*/* $TARGET_ROOTFS_DIR/lib/firmware/
		cp $RKWIFIBT/firmware/realtek/*/* $TARGET_ROOTFS_DIR/lib/firmware/rtlbt/
		cp $RKWIFIBT/tools/rtk_hciattach/rtk_hciattach $TARGET_ROOTFS_DIR/usr/bin/
		cp $RKWIFIBT/drivers/bluetooth_uart_driver/hci_uart.ko $TARGET_ROOTFS_DIR/usr/lib/modules/
		if [ -n "$WIFI_USB" ]; then
			cp $RKWIFIBT/drivers/bluetooth_usb_driver/rtk_btusb.ko $TARGET_ROOTFS_DIR/usr/lib/modules/
		fi

		rm -rf $TARGET_ROOTFS_DIR/etc/init.d/S36load_wifi_modules
		cp $RKWIFIBT/S36load_all_wifi_modules $TARGET_ROOTFS_DIR/etc/init.d/
		sed -i "s/BT_TTY_DEV/\/dev\/${BT_TTY_DEV}/g" $TARGET_ROOTFS_DIR/etc/init.d/S36load_all_wifi_modules
	fi

	if [[ "$WIFI_CHIP" = "ALL_AP" ]];then
		echo "copy ap6xxx/realtek firmware/nvram to rootfs"
		cp $RKWIFIBT/drivers/bcmdhd/*.ko $TARGET_ROOTFS_DIR/system/lib/modules/
		cp $RKWIFIBT/firmware/broadcom/*/wifi/* $TARGET_ROOTFS_DIR/system/etc/firmware/ || true
		cp $RKWIFIBT/firmware/broadcom/*/bt/* $TARGET_ROOTFS_DIR/system/etc/firmware/ || true

		#todo rockchip
		#cp $RKWIFIBT/firmware/rockchip/* $TARGET_ROOTFS_DIR/system/etc/firmware/
		cp $RKWIFIBT/sh/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_init.sh
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_pcba_test

		#reatek
		cp -rf $RKWIFIBT/firmware/realtek/*/* $TARGET_ROOTFS_DIR/lib/firmware/
		cp -rf $RKWIFIBT/firmware/realtek/*/* $TARGET_ROOTFS_DIR/lib/firmware/rtlbt/
		cp $RKWIFIBT/tools/rtk_hciattach/rtk_hciattach $TARGET_ROOTFS_DIR/usr/bin/
		cp $RKWIFIBT/drivers/bluetooth_uart_driver/hci_uart.ko $TARGET_ROOTFS_DIR/usr/lib/modules/
		if [ -n "$WIFI_USB" ]; then
			cp $RKWIFIBT/drivers/bluetooth_usb_driver/rtk_btusb.ko $TARGET_ROOTFS_DIR/usr/lib/modules/
		fi

		rm -rf $TARGET_ROOTFS_DIR/etc/init.d/S36load_wifi_modules
		cp $RKWIFIBT/S36load_all_wifi_modules $TARGET_ROOTFS_DIR/etc/init.d/
		sed -i "s/BT_TTY_DEV/\/dev\/${BT_TTY_DEV}/g" $TARGET_ROOTFS_DIR/etc/init.d/S36load_all_wifi_modules
	fi

	if [[ "$WIFI_CHIP" =~ "RTL" ]];then
		echo "Copy RTL file to rootfs"
		if [ -d "$RKWIFIBT/firmware/realtek/$WIFI_CHIP" ]; then
			cp $RKWIFIBT/firmware/realtek/$WIFI_CHIP/* $TARGET_ROOTFS_DIR/lib/firmware/rtlbt/
			cp $RKWIFIBT/firmware/realtek/$WIFI_CHIP/* $TARGET_ROOTFS_DIR/lib/firmware/
		else
			echo "INFO: $WIFI_CHIP isn't bluetooth?"
		fi

		WIFI_KO_DIR=$(echo $WIFI_CHIP | tr '[A-Z]' '[a-z]')

		cp $RKWIFIBT/drivers/$WIFI_KO_DIR/*.ko $TARGET_ROOTFS_DIR/system/lib/modules/

		cp $RKWIFIBT/sh/bt_load_rtk_firmware $TARGET_ROOTFS_DIR/usr/bin/
		sed -i "s/BT_TTY_DEV/\/dev\/${BT_TTY_DEV}/g" $TARGET_ROOTFS_DIR/usr/bin/bt_load_rtk_firmware
		if [ -n "$WIFI_USB" ]; then
			cp $RKWIFIBT/drivers/bluetooth_usb_driver/rtk_btusb.ko $TARGET_ROOTFS_DIR/usr/lib/modules/
			sed -i "s/BT_DRV/rtk_btusb/g" $TARGET_ROOTFS_DIR/usr/bin/bt_load_rtk_firmware
		else
			cp $RKWIFIBT/drivers/bluetooth_uart_driver/hci_uart.ko $TARGET_ROOTFS_DIR/usr/lib/modules/
			sed -i "s/BT_DRV/hci_uart/g" $TARGET_ROOTFS_DIR/usr/bin/bt_load_rtk_firmware
		fi
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_rtk_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_init.sh
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_rtk_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_pcba_test
		cp $RKWIFIBT/tools/rtk_hciattach/rtk_hciattach $TARGET_ROOTFS_DIR/usr/bin/
		rm -rf $TARGET_ROOTFS_DIR/etc/init.d/S36load_all_wifi_modules
		cp $RKWIFIBT/S36load_wifi_modules $TARGET_ROOTFS_DIR/etc/init.d/
		sed -i "s/WIFI_KO/\/system\/lib\/modules\/$WIFI_CHIP.ko/g" $TARGET_ROOTFS_DIR/etc/init.d/S36load_wifi_modules
	fi

	if [[ "$WIFI_CHIP" =~ "CYW" ]];then
		echo "Copy CYW file to rootfs"
		#tools
		cp $RKWIFIBT/tools/brcm_tools/dhd_priv $TARGET_ROOTFS_DIR/usr/bin/
		cp $RKWIFIBT/tools/brcm_tools/brcm_patchram_plus1 $TARGET_ROOTFS_DIR/usr/bin/
		#firmware
		cp $RKWIFIBT/firmware/infineon/$WIFI_CHIP/* $TARGET_ROOTFS_DIR/system/etc/firmware/
		cp $RKWIFIBT/drivers/infineon/*.ko $TARGET_ROOTFS_DIR/system/lib/modules/
		#bt
		cp $RKWIFIBT/sh/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/
		sed -i "s/BT_TTY_DEV/\/dev\/${BT_TTY_DEV}/g" $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware
		sed -i "s/BTFIRMWARE_PATH/\/system\/etc\/firmware\//g" $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_init.sh
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_pcba_test
		#wifi
		rm -rf $TARGET_ROOTFS_DIR/etc/init.d/S36load_all_wifi_modules
		cp $RKWIFIBT/S36load_wifi_modules $TARGET_ROOTFS_DIR/etc/init.d/
		sed -i "s/WIFI_KO/\/system\/lib\/modules\/$WIFI_CHIP.ko/g" $TARGET_ROOTFS_DIR/etc/init.d/S36load_wifi_modules
	fi

	if [[ "$WIFI_CHIP" =~ "AP6" ]];then
		echo "Copy AP file to rootfs"
		#tools
		cp $RKWIFIBT/tools/brcm_tools/dhd_priv $TARGET_ROOTFS_DIR/usr/bin/
		cp $RKWIFIBT/tools/brcm_tools/brcm_patchram_plus1 $TARGET_ROOTFS_DIR/usr/bin/
		#firmware
		cp $RKWIFIBT/firmware/broadcom/$WIFI_CHIP/wifi/* $TARGET_ROOTFS_DIR/system/etc/firmware/
		cp $RKWIFIBT/firmware/broadcom/$WIFI_CHIP/bt/* $TARGET_ROOTFS_DIR/system/etc/firmware/
		cp $RKWIFIBT/drivers/bcmdhd/*.ko $TARGET_ROOTFS_DIR/system/lib/modules/
		#bt
		cp $RKWIFIBT/sh/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/
		sed -i "s/BT_TTY_DEV/\/dev\/${BT_TTY_DEV}/g" $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware
		sed -i "s/BTFIRMWARE_PATH/\/system\/etc\/firmware\//g" $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_init.sh
		cp $TARGET_ROOTFS_DIR/usr/bin/bt_load_broadcom_firmware $TARGET_ROOTFS_DIR/usr/bin/bt_pcba_test
		#wifi
		rm -rf $TARGET_ROOTFS_DIR/etc/init.d/S36load_all_wifi_modules
		cp $RKWIFIBT/S36load_wifi_modules $TARGET_ROOTFS_DIR/etc/init.d/
		if [[ "$WIFI_CHIP" =~ "AP" ]];then
			sed -i "s/WIFI_KO/\/system\/lib\/modules\/bcmdhd.ko/g" $TARGET_ROOTFS_DIR/etc/init.d/S36load_wifi_modules
		else
			sed -i "s/WIFI_KO/\/system\/lib\/modules\/bcmdhd_pcie.ko/g" $TARGET_ROOTFS_DIR/etc/init.d/S36load_wifi_modules
		fi
	fi
	finish_build
	#exit 0
}

function build_modules(){
	check_config RK_KERNEL_DEFCONFIG || return 0

	echo "============Start building kernel modules============"
	echo "TARGET_ARCH          =$RK_ARCH"
	echo "TARGET_KERNEL_CONFIG =$RK_KERNEL_DEFCONFIG"
	echo "TARGET_KERNEL_CONFIG_FRAGMENT =$RK_KERNEL_DEFCONFIG_FRAGMENT"
	echo "=================================================="

	build_check_cross_compile

	cd kernel
	make ARCH=$RK_ARCH $RK_KERNEL_DEFCONFIG $RK_KERNEL_DEFCONFIG_FRAGMENT
	make ARCH=$RK_ARCH modules -j$RK_JOBS
	MODS_DIR=ko
	rm -rf $MODS_DIR
	make ARCH=$RK_ARCH INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=$MODS_DIR modules_install

	finish_build
}

function build_rootfs_install_modules(){
	build_modules || return 0

	ROOTFS_IMAGE=$TOP_DIR/rockdev/rootfs.img
	MODS_DIR=ko
	fakeroot ${COMMON_DIR}/overwr-ext4 -d lib/modules -a kernel/$MODS_DIR $ROOTFS_IMAGE

	finish_build
}

function build_toolchain(){
	check_config RK_CFG_TOOLCHAIN || return 0

	echo "==========Start building toolchain =========="
	echo "TARGET_TOOLCHAIN_CONFIG=$RK_CFG_TOOLCHAIN"
	echo "========================================="
	[[ $RK_CFG_TOOLCHAIN ]] \
		&& /usr/bin/time -f "you take %E to build toolchain" $COMMON_DIR/mk-toolchain.sh $BOARD_CONFIG \
		|| echo "No toolchain step, skip!"
	if [ $? -eq 0 ]; then
		echo "====Build toolchain ok!===="
	else
		echo "====Build toolchain failed!===="
		exit 1
	fi

	finish_build
}

function build_buildroot(){
	check_config RK_CFG_BUILDROOT || return 0

	echo "==========Start building buildroot=========="
	echo "TARGET_BUILDROOT_CONFIG=$RK_CFG_BUILDROOT"
	echo "========================================="
	if [ -z ${RK_CFG_BUILDROOT} ];then
		echo "====No Found config on `realpath $BOARD_CONFIG`. Just exit ..."
		return
	fi

	DST_DIR=.buildroot

	/usr/bin/time -f "you take %E to build builroot" $COMMON_DIR/mk-buildroot.sh $RK_CFG_BUILDROOT $DST_DIR
	if [ $? -eq 0 ]; then
		echo "====Build buildroot ok!===="
	else
		echo "====Build buildroot failed!===="
		exit 1
	fi
}

function build_ramboot(){
	check_config RK_CFG_RAMBOOT || return 0

	echo "=========Start building ramboot========="
	echo "TARGET_RAMBOOT_CONFIG=$RK_CFG_RAMBOOT"
	echo "====================================="
	if [ -z ${RK_CFG_RAMBOOT} ];then
		echo "====No Found config on `realpath $BOARD_CONFIG`. Just exit ..."
		return
	fi
	/usr/bin/time -f "you take %E to build ramboot" $COMMON_DIR/mk-ramdisk.sh ramboot.img $RK_CFG_RAMBOOT
	if [ $? -eq 0 ]; then
		rm $TOP_DIR/rockdev/boot.img
		ln -rfs $TOP_DIR/buildroot/output/$RK_CFG_RAMBOOT/images/ramboot.img $TOP_DIR/rockdev/boot.img
		echo "====Build ramboot ok!===="
	else
		echo "====Build ramboot failed!===="
		exit 1
	fi


	cp buildroot/output/$RK_CFG_RAMBOOT/images/ramboot.img \
		u-boot/boot.img

	finish_build
}

function build_multi-npu_boot(){
	check_config RK_MULTINPU_BOOT || return 0

	echo "=========Start building multi-npu boot========="
	echo "TARGET_RAMBOOT_CONFIG=$RK_CFG_RAMBOOT"
	echo "====================================="

	/usr/bin/time -f "you take %E to build multi-npu boot" \
		$COMMON_DIR/mk-multi-npu_boot.sh

	finish_build
}

function kernel_version(){
	VERSION_KEYS="VERSION PATCHLEVEL"
	VERSION=""

	for k in $VERSION_KEYS; do
		v=$(grep "^$k = " $1/Makefile | cut -d' ' -f3)
		VERSION=${VERSION:+${VERSION}.}$v
	done
	echo $VERSION
}

function build_yocto(){
	check_config RK_YOCTO_MACHINE || return 0

	echo "=========Start build ramboot========="
	echo "TARGET_MACHINE=$RK_YOCTO_MACHINE"
	echo "====================================="

	KERNEL_VERSION=$(kernel_version kernel/)

	cd yocto
	ln -sf $RK_YOCTO_MACHINE.conf build/conf/local.conf
	source oe-init-build-env
	LANG=en_US.UTF-8 LANGUAGE=en_US.en LC_ALL=en_US.UTF-8 \
		bitbake core-image-minimal -r conf/include/rksdk.conf \
		-r conf/include/kernel-$KERNEL_VERSION.conf

	finish_build
}

function build_debian(){
	ARCH=${RK_DEBIAN_ARCH:-${RK_ARCH}}
	case $ARCH in
		arm|armhf) ARCH=armhf ;;
		*) ARCH=arm64 ;;
	esac

	echo "=========Start building debian for $ARCH========="

	cd debian
	if [ ! -e linaro-$RK_DEBIAN_VERSION-alip-*.tar.gz ]; then
		RELEASE=$RK_DEBIAN_VERSION TARGET=desktop ARCH=$ARCH ./mk-base-debian.sh
		ln -rsf linaro-$RK_DEBIAN_VERSION-alip-*.tar.gz linaro-$RK_DEBIAN_VERSION-$ARCH.tar.gz
	fi

	VERSION=debug ARCH=$ARCH ./mk-rootfs-$RK_DEBIAN_VERSION.sh

	./mk-image.sh
	cd ..
	if [ $? -eq 0 ]; then
		echo "====Build Debian ok!===="
	else
		echo "====Build Debian failed!===="
		exit 1
	fi
	finish_build
}

function build_rootfs(){
	check_config RK_ROOTFS_IMG || return 0

	RK_ROOTFS_DIR=.rootfs
	ROOTFS_IMG=${RK_ROOTFS_IMG##*/}

	if [ "$RK_ROOTFS_SYSTEM" != "ubuntu" ]; then
		rm -rf $RK_ROOTFS_IMG $RK_ROOTFS_DIR
		mkdir -p ${RK_ROOTFS_IMG%/*} $RK_ROOTFS_DIR
		echo "rootfs dir $RK_ROOTFS_DIR"
	fi

	case "$1" in
		yocto)
			build_yocto
			ROOTFS_IMG=yocto/build/tmp/deploy/images/$RK_YOCTO_MACHINE/rootfs.img
			;;
		debian)
			ROOTFS_IMG=debian/debian*-rootfs.img
			if ls ${ROOTFS_IMG} | grep -q img;then
				echo "====Build Debian rootfs.img!===="
				ROOTFS_IMG=$(ls ${ROOTFS_IMG})
			else
				echo "====Can not found Debian rootfs.img!===="
				echo "====Please execute \"sudo ./build.sh debian\" to compile===="
				exit -1
			fi
			;;
		*)
			if [ -n "$RK_CFG_BUILDROOT" ];then
				build_buildroot
				ROOTFS_IMG=buildroot/output/$RK_CFG_BUILDROOT/images/rootfs.$RK_ROOTFS_TYPE
				if [ "$RK_TARGET_PRODUCT" = "rk3588" ]; then
				build_wifibt
                        	#fixed requires second compilation issue
				build_buildroot
				fi
				for f in $(ls buildroot/output/$RK_CFG_BUILDROOT/images/rootfs.*);do
					ln -rsf $f $RK_ROOTFS_DIR/
				done
			fi
			;;
	esac

	[ -z "$ROOTFS_IMG" ] && return

	if [ ! -f "$ROOTFS_IMG" ]; then
		echo "$ROOTFS_IMG not generated?"
	else
		mkdir -p ${RK_ROOTFS_IMG%/*}
		rm -f $RK_ROOTFS_IMG
		ln -rsf $TOP_DIR/$ROOTFS_IMG $RK_ROOTFS_IMG
	fi


	finish_build
}

function build_recovery(){

	if [ "$RK_UPDATE_SDCARD_ENABLE_FOR_AB" = "true" ] ;then
		RK_CFG_RECOVERY=$RK_UPDATE_SDCARD_CFG_RECOVERY
	fi

	if [ ! -z "$RK_PACKAGE_FILE_AB" ]; then
		return 0
	fi

	#check_config RK_CFG_RECOVERY || return 0

	echo "==========Start building recovery=========="
	echo "TARGET_RECOVERY_CONFIG=$RK_CFG_RECOVERY"
	echo "========================================"
	/usr/bin/time -f "you take %E to build recovery" $COMMON_DIR/mk-ramdisk.sh recovery.img $RK_CFG_RECOVERY
	if [ $? -eq 0 ]; then
		echo "====Build recovery ok!===="
	else
		echo "====Build recovery failed!===="
		exit 1
	fi


#	ln -rsf buildroot/output/$RK_CFG_RECOVERY/images/recovery.img \
#		rockdev/recovery.img

	if [ -n "$RK_CFG_RECOVERY" ];then
		cp buildroot/output/$RK_CFG_RECOVERY/images/recovery.img \
			u-boot/recovery.img
	fi

	finish_build
}

function build_pcba(){
	check_config RK_CFG_PCBA || return 0

	echo "==========Start building pcba=========="
	echo "TARGET_PCBA_CONFIG=$RK_CFG_PCBA"
	echo "===================================="
	if [ -z ${RK_CFG_PCBA} ];then
		echo "====No Found config on `realpath $BOARD_CONFIG`. Just exit ..."
		return
	fi
	/usr/bin/time -f "you take %E to build pcba" $COMMON_DIR/mk-ramdisk.sh pcba.img $RK_CFG_PCBA
	if [ $? -eq 0 ]; then
		echo "====Build pcba ok!===="
	else
		echo "====Build pcba failed!===="
		exit 1
	fi
}

BOOT_FIXED_CONFIGS="
	CONFIG_BLK_DEV_DM
	CONFIG_DM_CRYPT
	CONFIG_BLK_DEV_CRYPTOLOOP
	CONFIG_DM_VERITY"

BOOT_OPTEE_FIXED_CONFIGS="
	CONFIG_TEE
	CONFIG_OPTEE"

UBOOT_FIXED_CONFIGS="
	CONFIG_FIT_SIGNATURE
	CONFIG_SPL_FIT_SIGNATURE"

UBOOT_AB_FIXED_CONFIGS="
	CONFIG_ANDROID_AB"

ROOTFS_UPDATE_ENGINEBIN_CONFIGS="
	BR2_PACKAGE_RECOVERY
	BR2_PACKAGE_RECOVERY_UPDATEENGINEBIN"

ROOTFS_AB_FIXED_CONFIGS="
	$ROOTFS_UPDATE_ENGINEBIN_CONFIGS
	BR2_PACKAGE_RECOVERY_BOOTCONTROL"

function defconfig_check() {
	# 1. defconfig 2. fixed config
	echo debug-$1
	for i in $2
	do
		echo "look for $i"
		result=$(cat $1 | grep "${i}=y" -w || echo "No found")
		if [ "$result" = "No found" ]; then
			echo -e "\e[41;1;37mSecurity: No found config ${i} in $1 \e[0m"
			echo "make sure your config include this list"
			echo "---------------------------------------"
			echo "$2"
			echo "---------------------------------------"
			return -1;
		fi
	done
	return 0
}

function find_string_in_config(){
	result=$(cat "$2" | grep "$1" || echo "No found")
	if [ "$result" = "No found" ]; then
		echo "Security: No found string $1 in $2"
		return -1;
	fi
	return 0;
}

function check_security_condition(){
	# check security enabled
	test -z "$RK_SYSTEM_CHECK_METHOD" && return 0

	if [ ! -d u-boot/keys ]; then
		echo "ERROR: No root keys(u-boot/keys) found in u-boot"
		echo "       Create it by ./build.sh createkeys or move your key to it"
		return -1
	fi

	if [ "$RK_SYSTEM_CHECK_METHOD" = "DM-E" ]; then
		if [ ! -e u-boot/keys/root_passwd ]; then
			echo "ERROR: No root passwd(u-boot/keys/root_passwd) found in u-boot"
			echo "       echo your root key for sudo to u-boot/keys/root_passwd"
			echo "       some operations need supper user permission when create encrypt image"
			return -1
		fi

		if [ ! -e u-boot/keys/system_enc_key ]; then
			echo "ERROR: No enc key(u-boot/keys/system_enc_key) found in u-boot"
			echo "       Create it by ./build.sh createkeys or move your key to it"
			return -1
		fi

		BOOT_FIXED_CONFIGS="${BOOT_FIXED_CONFIGS}
				    ${BOOT_OPTEE_FIXED_CONFIGS}"
	fi

	echo "check kernel defconfig"
	defconfig_check kernel/arch/$RK_ARCH/configs/$RK_KERNEL_DEFCONFIG "$BOOT_FIXED_CONFIGS"

	if [ ! -z "${RK_PACKAGE_FILE_AB}" ]; then
		UBOOT_FIXED_CONFIGS="${UBOOT_FIXED_CONFIGS}
				     ${UBOOT_AB_FIXED_CONFIGS}"

		defconfig_check buildroot/configs/${RK_CFG_BUILDROOT}_defconfig "$ROOTFS_AB_FIXED_CONFIGS"
	fi
	echo "check uboot defconfig"
	defconfig_check u-boot/configs/${RK_UBOOT_DEFCONFIG}_defconfig "$UBOOT_FIXED_CONFIGS"

	if [ "$RK_SYSTEM_CHECK_METHOD" = "DM-E" ]; then
		echo "check ramdisk defconfig"
		defconfig_check buildroot/configs/${RK_CFG_RAMBOOT}_defconfig "$ROOTFS_UPDATE_ENGINEBIN_CONFIGS"
	fi

	echo "check rootfs defconfig"
	find_string_in_config "BR2_ROOTFS_OVERLAY=\".*board/rockchip/common/security-system-overlay.*" "buildroot/configs/${RK_CFG_BUILDROOT}_defconfig"

	echo "Security: finish check"
}

function build_all(){
	echo "============================================"
	echo "TARGET_ARCH=$RK_ARCH"
	echo "TARGET_PLATFORM=$RK_TARGET_PRODUCT"
	echo "TARGET_UBOOT_CONFIG=$RK_UBOOT_DEFCONFIG"
	echo "TARGET_SPL_CONFIG=$RK_SPL_DEFCONFIG"
	echo "TARGET_KERNEL_CONFIG=$RK_KERNEL_DEFCONFIG"
	echo "TARGET_KERNEL_DTS=$RK_KERNEL_DTS"
	echo "TARGET_TOOLCHAIN_CONFIG=$RK_CFG_TOOLCHAIN"
	echo "TARGET_BUILDROOT_CONFIG=$RK_CFG_BUILDROOT"
	echo "TARGET_RECOVERY_CONFIG=$RK_CFG_RECOVERY"
	echo "TARGET_PCBA_CONFIG=$RK_CFG_PCBA"
	echo "TARGET_RAMBOOT_CONFIG=$RK_CFG_RAMBOOT"
	echo "============================================"

	# NOTE: On secure boot-up world, if the images build with fit(flattened image tree)
	#       we will build kernel and ramboot firstly,
	#       and then copy images into u-boot to sign the images.
	if [ "$RK_RAMDISK_SECURITY_BOOTUP" != "true" ];then
		#note: if build spl, it will delete loader.bin in uboot directory,
		# so can not build uboot and spl at the same time.
		if [ -z $RK_SPL_DEFCONFIG ]; then
			build_uboot
		else
			build_spl
		fi
	fi

	check_security_condition
	build_loader
	if [ "$FF_EXTBOOT" = "true" ]; then
		build_extboot
	else
		build_kernel
	fi

	build_toolchain && \
	build_rootfs ${RK_ROOTFS_SYSTEM:-buildroot}
	build_recovery
	build_ramboot

	if [ "$RK_RAMDISK_SECURITY_BOOTUP" = "true" ];then
		#note: if build spl, it will delete loader.bin in uboot directory,
		# so can not build uboot and spl at the same time.
		if [ -z $RK_SPL_DEFCONFIG ]; then
			build_uboot
		else
			build_spl
		fi
	fi

	finish_build
}

function build_cleanall(){
	echo "clean uboot, kernel, rootfs, recovery"

	cd u-boot
	make distclean
	cd -
	cd kernel
	make distclean
	cd -
	rm -rf buildroot/output
	rm -rf yocto/build/tmp
	rm -rf debian/binary

	finish_build
}

function build_firmware(){
	./mkfirmware.sh $BOARD_CONFIG
	if [ $? -eq 0 ]; then
		echo "Make image ok!"
	else
		echo "Make image failed!"
		exit 1
	fi
}


function gen_file_name() {
	local day=$(date +%y%m%d)
	#local time=$(date +%H%M)
	local os_all="buildroot debian ubuntu UnionTech UniKylin centos"

	local model=$(basename $(realpath ${BOARD_CONFIG}) .mk)
	local os_mk=$(echo $model | egrep -io ${os_all// /|} || true)
	# Set the string before os name in the BOARD_CONFIG file name as the model name
	[[ -n "$os_mk" ]] && model=${model/-$os_mk*/}
	IMGNAME=${model^^}

	# Set the string before first "_" in the rootfs file name as the system name
	# OSName_xxxx_vx.x.x.img"
	local rootfs=$(basename $(realpath $TOP_DIR/rockdev/rootfs.img))
	#remove suffix, get string before first "-" or "_"
	local os_name=$(echo ${rootfs%.*} | sed 's/[-_].*//')
	if [[ ${os_name^^} == "ROOTFS" ]] || [[ ${os_name^^} == "SYSTEM" ]]; then
		os_name=${os_mk}
	fi

	[[ -z "$os_name" ]] && os_name="Linux"

	#Uper first letter
	IMGNAME+=_$(echo ${os_name,,} | sed 's/./\u&/')

	#local os_mode=$(echo $rootfs | egrep -io "desktop|minimal|server" || true)
	local os_mode=$(echo $rootfs | egrep -io "gnome|xfce|minimal|server" || true)
	[[ -n "$os_mode" ]] && IMGNAME+=-$(echo ${os_mode,,} | sed 's/./\u&/')

	os_version=$(echo $rootfs | sed -n 's/.*[-_]\([vV][0-9.a-zA-Z]*\(\-[0-9]\{1,\}\)\{,1\}\)[-_\.].*/\1/p')
	if [[ -z "$os_version" ]]; then
		#get date string in rootfs as rootfs version
		os_version=$(echo $rootfs | sed -n 's/.*[-_]\(20[0-9]\{2,\}[-_.0-9]*\)[-_.].*/\1/p')
	fi
	if [[ -n "$os_version" ]]; then
		os_version=${os_version,,}
		#delete . - _ v
		os_version=${os_version/v/r}
		os_version=$(echo $os_version | sed 's/[-_\.]//g')
		IMGNAME+=-${os_version}
	fi

	local sdk_version=""
	local manifest=$(realpath ${TOP_DIR}/.repo/manifest.xml)
	if [[ -f $manifest ]]; then
		manifest=$(basename $(realpath ${TOP_DIR}/.repo/manifest.xml) .xml)
		sdk_version=$(echo $manifest | sed -n 's/.*[-_]\([vV][0-9.a-zA-Z]*\).*/\1/p')
		IMGNAME+=_${sdk_version}
	fi

	if [ -n "$1" ];then
		IMGNAME+=_${1}
	fi

	#IMGNAME+=_${day}-${time}.img
	IMGNAME+=_${day}.img

	echo -e "File name is \e[36m $IMGNAME\e[0m"
	if [ "$rename" == "0" ];then
		:
	else
		read -t 10 -e -p "Rename the file? [N|y]" ANS || :
		ANS=${ANS:-n}

		case $ANS in
				Y|y|yes|YES|Yes) rename=1;;
				N|n|no|NO|No) rename=0;;
				*) rename=0;;
		esac
	fi

	if [[ ${rename} == "1" ]]; then
		read -e -p "Enter new file name: " -i $IMGNAME newname
		IMGNAME=$newname
	fi
}


function build_rawimg(){
	packm="unpack"
	[[ -n "$1" ]] && [[ $1 != "-p" ]] && usage
	[[ -n "$1" ]] && packm="pack"

	gen_file_name RAW

	if [ $packm == "pack" ];then
		cd rockdev && ./version.sh $IMGNAME init && cd -
	fi

	if [ -n "$RK_RECOVERY_RAMDISK_RAW" ]; then
		local mk_path=$(realpath $BOARD_CONFIG)
		sed -i '$a\'"export RK_RECOVERY_RAMDISK=$RK_RECOVERY_RAMDISK_RAW" $mk_path
		sed -i '$a\'"export RK_CFG_RECOVERY=" $mk_path
		if [ -n "$TOP_DIR/rockdev/recovery.img" ]; then
			mv $TOP_DIR/rockdev/recovery.img $TOP_DIR/rockdev/recovery.img_bk
		fi
		build_recovery
		sed -i "/export RK_RECOVERY_RAMDISK=$RK_RECOVERY_RAMDISK_RAW/d" $mk_path
		sed -i "/export RK_CFG_RECOVERY=/d" $mk_path
	else
		echo "Not found RK_RECOVERY_RAMDISK_RAW!"
		exit 1
	fi

	IMAGE_PATH=$TOP_DIR/rockdev
	PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware

	cd $PACK_TOOL_DIR/rockdev

	if [ -f "$RK_PACKAGE_FILE_AB" ]; then
		build_sdcard_package
		build_otapackage

		cd $PACK_TOOL_DIR/rockdev
		echo "Make Linux a/b update_ab.img."
		source_package_file_name=`ls -lh package-file | awk -F ' ' '{print $NF}'`
		ln -fs "$RK_PACKAGE_FILE_AB" package-file
		./mkupdate.sh
		mv update.img $IMAGE_PATH/update_ab.img
		ln -fs $source_package_file_name package-file
	else
		echo "Make raw.img"

		if [ "$RK_MISC_WR" = "true" ]; then
			${TOP_DIR}/device/rockchip/common/misc-wr --firmware $IMAGE_PATH/misc.img $IMGNAME
		fi
		if [ -f "$RK_PACKAGE_FILE" ]; then
			source_package_file_name=`ls -lh package-file | awk -F ' ' '{print $NF}'`
			ln -fs "$RK_PACKAGE_FILE" package-file
			./mkrawimg.sh
			ln -fs $source_package_file_name package-file
		else
			cd $PACK_TOOL_DIR/rockdev && ./mkrawimg.sh && cd -
		fi
	mv $PACK_TOOL_DIR/rockdev/raw.img $IMAGE_PATH/pack/$IMGNAME
	rm -rf $IMAGE_PATH/raw.img
	if [ -n "$TOP_DIR/rockdev/recovery.img_bk" ]; then
		mv $TOP_DIR/rockdev/recovery.img_bk $TOP_DIR/rockdev/recovery.img
	fi

	if [ $? -eq 0 ]; then
	   echo "Make raw image ok!"
	   echo -e "\e[36m $IMAGE_PATH/pack/$IMGNAME \e[0m"
	else
	   echo "Make raw image failed!"
	   exit 1
	fi

	if [ $packm == "pack" ];then
		cd $TOP_DIR/rockdev && ./version.sh $IMGNAME pack && cd -
	fi
    fi
}

function build_sdupdateimg(){

	gen_file_name sdupdate

	IMAGE_PATH=$TOP_DIR/rockdev
	PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware

	echo "Make sdupdate.img"
	if [ -f $SD_PARAMETER ]
	then
		echo -n "create parameter..."
		ln -s -f $SD_PARAMETER $ROCKDEV/parameter.txt
		echo "done."
	else
		echo -e "\e[31m error: $SD_PARAMETER not found! \e[0m"
		exit 1
	fi

	if [[ x"$RK_SD_PACKAGE_FILE" != x ]];then
		RK_PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware/rockdev/
		cd $RK_PACK_TOOL_DIR
		rm -f package-file
		ln -sf $RK_SD_PACKAGE_FILE package-file
	fi

	cd $PACK_TOOL_DIR/rockdev && ./mkupdate.sh && cd -
	mv $PACK_TOOL_DIR/rockdev/update.img $IMAGE_PATH/pack/$IMGNAME
	rm -rf $IMAGE_PATH/update.img

	if [ $? -eq 0 ]; then
	   echo "Make sdupdate image ok!"
	   echo -e "\e[36m $IMAGE_PATH/pack/$IMGNAME \e[0m"
	else
	   echo "Make sdupdate image failed!"
	fi

	if [ -f $PARAMETER ]
	then
		ln -s -f $PARAMETER $ROCKDEV/parameter.txt
	fi

	if [[ x"$RK_PACKAGE_FILE" != x ]];then
		RK_PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware/rockdev/
		cd $RK_PACK_TOOL_DIR
		rm -f package-file
		ln -sf $RK_PACKAGE_FILE package-file
	fi
}

function build_otapackage(){
	IMAGE_PATH=$TOP_DIR/rockdev
	PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware

	echo "Make ota ab update_ota.img"
	cd $PACK_TOOL_DIR/rockdev
	if [ -f "$RK_PACKAGE_FILE_OTA" ]; then
		source_package_file_name=`ls -lh $PACK_TOOL_DIR/rockdev/package-file | awk -F ' ' '{print $NF}'`
		ln -fs "$RK_PACKAGE_FILE_OTA" package-file
		./mkupdate.sh
		mv update.img $IMAGE_PATH/update_ota.img
		ln -fs $source_package_file_name package-file
	fi

	finish_build
}

function build_sdcard_package(){

	check_config RK_UPDATE_SDCARD_ENABLE_FOR_AB || return 0

	local image_path=$TOP_DIR/rockdev
	local pack_tool_dir=$TOP_DIR/tools/linux/Linux_Pack_Firmware
	local rk_sdupdate_ab_misc=${RK_SDUPDATE_AB_MISC:=sdupdate-ab-misc.img}
	local rk_parameter_sdupdate=${RK_PARAMETER_SDUPDATE:=parameter-sdupdate.txt}
	local rk_package_file_sdcard_update=${RK_PACKAGE_FILE_SDCARD_UPDATE:=sdcard-update-package-file}
	local sdupdate_ab_misc_img=$TOP_DIR/device/rockchip/rockimg/$rk_sdupdate_ab_misc
	local parameter_sdupdate=$TOP_DIR/device/rockchip/rockimg/$rk_parameter_sdupdate
	local recovery_img=$TOP_DIR/buildroot/output/$RK_UPDATE_SDCARD_CFG_RECOVERY/images/recovery.img

	if [ $RK_UPDATE_SDCARD_CFG_RECOVERY ]; then
		if [ -f $recovery_img ]; then
			echo -n "create recovery.img..."
			ln -rsf $recovery_img $image_path/recovery.img
		else
			echo "error: $recovery_img not found!"
			return 1
		fi
	fi


	echo "Make sdcard update update_sdcard.img"
	cd $pack_tool_dir/rockdev
	if [ -f "$rk_package_file_sdcard_update" ]; then

		if [ $rk_parameter_sdupdate ]; then
			if [ -f $parameter_sdupdate ]; then
				echo -n "create sdcard update image parameter..."
				ln -rsf $parameter_sdupdate $image_path/
			fi
		fi

		if [ $rk_sdupdate_ab_misc ]; then
			if [ -f $sdupdate_ab_misc_img ]; then
				echo -n "create sdupdate ab misc.img..."
				ln -rsf $sdupdate_ab_misc_img $image_path/
			fi
		fi

		source_package_file_name=`ls -lh $pack_tool_dir/rockdev/package-file | awk -F ' ' '{print $NF}'`
		ln -fs "$rk_package_file_sdcard_update" package-file
		./mkupdate.sh
		mv update.img $image_path/update_sdcard.img
		ln -fs $source_package_file_name package-file
		rm -f $image_path/$rk_sdupdate_ab_misc $image_path/$rk_parameter_sdupdate $image_path/recovery.img
	fi

	finish_build
}

function build_save(){
	IMAGE_PATH=$TOP_DIR/rockdev
	DATE=$(date  +%Y%m%d.%H%M)
	STUB_PATH=Image/"$RK_KERNEL_DTS"_"$DATE"_RELEASE_TEST
	STUB_PATH="$(echo $STUB_PATH | tr '[:lower:]' '[:upper:]')"
	export STUB_PATH=$TOP_DIR/$STUB_PATH
	export STUB_PATCH_PATH=$STUB_PATH/PATCHES
	mkdir -p $STUB_PATH

	#Generate patches
	$TOP_DIR/.repo/repo/repo forall -c "$TOP_DIR/device/rockchip/common/gen_patches_body.sh"

	#Copy stubs
	yes | .repo/repo/repo manifest -r -o $STUB_PATH/manifest_${DATE}.xml
	mkdir -p $STUB_PATCH_PATH/kernel
	cp $TOP_DIR/kernel/.config $STUB_PATCH_PATH/kernel
	cp $TOP_DIR/kernel/vmlinux $STUB_PATCH_PATH/kernel
	mkdir -p $STUB_PATH/IMAGES/
	cp $IMAGE_PATH/* $STUB_PATH/IMAGES/

	#Save build command info
	echo "UBOOT:  defconfig: $RK_UBOOT_DEFCONFIG" >> $STUB_PATH/build_cmd_info
	echo "KERNEL: defconfig: $RK_KERNEL_DEFCONFIG, dts: $RK_KERNEL_DTS" >> $STUB_PATH/build_cmd_info
	echo "BUILDROOT: $RK_CFG_BUILDROOT" >> $STUB_PATH/build_cmd_info

}

function build_updateimg(){
	packm="unpack"
	[[ -n "$1" ]] && [[ $1 != "-p" ]] && usage
	[[ -n "$1" ]] && packm="pack"

	gen_file_name

	if [ $packm == "pack" ];then
		cd $TOP_DIR/rockdev \
		&& ./version.sh $IMGNAME init $2 && cd -
	fi

	IMAGE_PATH=$TOP_DIR/rockdev
	PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware

	cd $PACK_TOOL_DIR/rockdev

	if [ -f "$RK_PACKAGE_FILE_AB" ]; then
		build_sdcard_package
		build_otapackage

		cd $PACK_TOOL_DIR/rockdev
		echo "Make Linux a/b update_ab.img."
		source_package_file_name=`ls -lh package-file | awk -F ' ' '{print $NF}'`
		ln -fs "$RK_PACKAGE_FILE_AB" package-file
		./mkupdate.sh
		mv update.img $IMAGE_PATH/update_ab.img
		ln -fs $source_package_file_name package-file
	else
		echo "Make update.img"

		if [ "$RK_MISC_WR" = "true" ]; then
			${TOP_DIR}/device/rockchip/common/misc-wr --firmware $IMAGE_PATH/misc.img $IMGNAME
		fi
		if [ -f "$RK_PACKAGE_FILE" ]; then
			source_package_file_name=`ls -lh package-file | awk -F ' ' '{print $NF}'`
			ln -fs "$RK_PACKAGE_FILE" package-file
			./mkupdate.sh
			ln -fs $source_package_file_name package-file
		else
			./mkupdate.sh
		fi
		mv update.img $IMAGE_PATH
	fi

	mv $IMAGE_PATH/update.img $IMAGE_PATH/pack/$IMGNAME
	rm -rf $IMAGE_PATH/update.img
	if [ $? -eq 0 ]; then
	   echo "Make update image ok!"
	   echo -e "\e[36m $IMAGE_PATH/pack/$IMGNAME \e[0m"
	else
	   echo "Make update image failed!"
	   exit 1
	fi

	if command -v ffgenswv.bin > /dev/null ; then
		if [ -z "$RK_PRODUCT_MODEL" ] ; then
			echo -e "\e[31m \"RK_PRODUCT_MODEL\" is NOT defined in device/rockchip/.BoardConfig.mk !!!\e[0m"
			RK_PRODUCT_MODEL=${RK_KERNEL_DTS}
		fi
		[ -z "$RK_DRM_VERSION" ] && RK_DRM_VERSION=1
		[[ "${RK_TARGET_PRODUCT^^}" == RK356* ]]  && RK_DRM_VERSION=100
		[[ "${RK_TARGET_PRODUCT^^}" == RK3588 ]]  && RK_DRM_VERSION=100
		ffgenswv.bin -b ${RK_TARGET_PRODUCT^^} \
					-m ${RK_PRODUCT_MODEL^^} \
					-V ${RK_DRM_VERSION} \
					-u $IMAGE_PATH/pack/$IMGNAME \
					-o $IMAGE_PATH/ffimage.swv
	fi

	finish_build
}

function ZH_parse_json(){
	local val
	local JSON_PATH=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/firefly.json
	local README_FILE="README_ZH.txt"
	local board_json

cat << EOF > ${README_FILE}
 _____ _           __ _
|  ___(_)_ __ ___ / _| |_   _
| |_  | | '__/ _ \ |_| | | | |
|  _| | | | |  __/  _| | |_| |
|_|   |_|_|  \___|_| |_|\__, |
                        |___/

* 官网 www.t-firefly.com  |  www.t-chip.com.cn
* 技术支持 service@t-firefly.com
* 开源社区 https://dev.t-firefly.com/portal.php?mod=topic&topicid=11

EOF
	if [ ! -f $JSON_PATH ]; then
		echo "没有json文件"
		return 0
	fi

	# RK_PRODUCT_MODEL
	val=`cat $JSON_PATH | jq -r ".[]|select(.RK_PRODUCT_MODEL==\"$RK_PRODUCT_MODEL\")"`
	if [ -z "$val" ]; then
		echo "没有RK_PRODUCT_MODEL,退出"
		return 0
	fi

	#如果没有定义FIREFLY_PRODUCT_MODEL，为裸板
	if [ -n "$FIREFLY_PRODUCT_MODEL" ]; then
		# 为整机产品
		board_json=`cat $JSON_PATH | jq -r ".[]|select(.FIREFLY_PRODUCT_MODEL==\"$FIREFLY_PRODUCT_MODEL\")"`


		if [ -n "$board_json" ] && [ "$board_json" != "null" ]; then
			echo "整机产品: $FIREFLY_PRODUCT_MODEL" >> ${README_FILE}

			# 获取整机产品 Wiki 链接
			val=`echo $board_json | jq -r ".FIREFLY_PRODUCT_WIKI.ZH"`
			if [ -n "$val" ] && [ "$val" != "null" ]; then
				echo "整机产品开发手册:" >> ${README_FILE}
				echo -e "$val\n" >> ${README_FILE}
			fi
		fi
	else
		board_json=`cat $JSON_PATH | jq -r ".[]|select(.RK_PRODUCT_MODEL==\"$RK_PRODUCT_MODEL\")"`
	fi

	BOARD_NAME=`echo $board_json | jq -r ".BOARD_NAME"`

	CPU_NAME=`cat $JSON_PATH | jq -r ".[]|select(.RK_PRODUCT_MODEL==\"common\")".CPU`
	if [ -n "$CPU_NAME" ] && [ "$CPU_NAME" != "null" ]; then
		echo CPU $CPU_NAME > /dev/null
	else
		echo -e "\t\e[31mPlease set CPU property to firefly.json\e[0m"
		exit -1
	fi

	val=`echo $board_json | jq -r ".BOARD_WIKI.ZH"`
	if [ -n "$val" ] && [ "$val" != "null" ]; then
		echo "获取固件的升级方法和板子的开发指南，请查看官方Wiki:" >> ${README_FILE}
		echo -e "$val\n" >> ${README_FILE}
	fi

	val=`echo $board_json | jq -r ".FW_Changelog.ZH"`
	if [ -n "$val" ] && [ "$val" != "null" ]; then
		echo "固件更新日志：" >> ${README_FILE}
		echo -e "$val\n" >> ${README_FILE}
	fi
}



function EN_parse_json(){
	local val
	local JSON_PATH=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/firefly.json
	local README_FILE="README_EN.txt"
	local board_json

cat << EOF > ${README_FILE}
 _____ _           __ _
|  ___(_)_ __ ___ / _| |_   _
| |_  | | '__/ _ \ |_| | | | |
|  _| | | | |  __/  _| | |_| |
|_|   |_|_|  \___|_| |_|\__, |
                        |___/

* Official website https://en.t-firefly.com/  |  www.t-chip.com.cn
* Technical Support service@t-firefly.com
* Forums https://bbs.t-firefly.com/forum.php?mod=forumdisplay&fid=100

EOF

	if [ ! -f $JSON_PATH ]; then
		echo "没有json文件"
		return 0
	fi

	# RK_PRODUCT_MODEL
	val=`cat $JSON_PATH | jq -r ".[]|select(.RK_PRODUCT_MODEL==\"$RK_PRODUCT_MODEL\")"`
	if [ -z "$val" ]; then
		echo "没有RK_PRODUCT_MODEL,退出"
		return 0
	fi

	#如果没有定义FIREFLY_PRODUCT_MODEL，为裸板
	if [ -n "$FIREFLY_PRODUCT_MODEL" ]; then
		# 为整机产品
		board_json=`cat $JSON_PATH | jq -r ".[]|select(.FIREFLY_PRODUCT_MODEL==\"$FIREFLY_PRODUCT_MODEL\")"`

		if [ -n "$board_json" ] && [ "$board_json" != "null" ]; then
			echo "Machine Product: $FIREFLY_PRODUCT_MODEL" >> ${README_FILE}

			# 获取整机产品 Wiki 链接
			val=`echo $board_json | jq -r ".FIREFLY_PRODUCT_WIKI.EN"`
			if [ -n "$val" ] && [ "$val" != "null" ]; then
				echo "Machine Product Development Manual:" >> ${README_FILE}
				echo -e "$val\n" >> ${README_FILE}
			fi
		fi
	else
		board_json=`cat $JSON_PATH | jq -r ".[]|select(.RK_PRODUCT_MODEL==\"$RK_PRODUCT_MODEL\")"`
	fi

	val=`echo $board_json | jq -r ".BOARD_WIKI.EN"`
	if [ -n "$val" ] && [ "$val" != "null" ]; then
		echo "For firmware upgrade method and board development guide, please check the official Wiki:" >> ${README_FILE}
		echo -e "$val\n" >> ${README_FILE}
	fi

	val=`echo $board_json | jq -r ".FW_Changelog.EN"`

	if [ -n "$val" ] && [ "$val" != "null" ]; then
		echo "Firmware update log:" >> ${README_FILE}
		echo -e "$val\n" >> ${README_FILE}
	fi
}


function create_fw_log(){
	source fw_log/.ff_log_build/3_rootfs/Fconfig
	local var=$(realpath fw_log/.ff_log_build/3_rootfs/$rootfs_name/rootfs.img)
	real_rootfs_name=${var##*/}

	echo -e "Rootfs $rootfs_name is\t\e[36m$real_rootfs_name\e[0m"
	echo Link rockdev/rootfs.img to $var
	ln -fs $var rockdev/rootfs.img
	# create update.img
	build_updateimg


	# create md5sum
	echo "MD5 data of firmware being generated"
	fw_md5=$(md5sum $IMAGE_PATH/pack/$IMGNAME | awk  '{print $1}')
	xml_version=$(readlink .repo/manifest.xml  -f | awk -F '/' '{printf $NF}')
	echo "Parse device/rockchip/$RK_TARGET_PRODUCT/firefly.json"
	ZH_parse_json
	EN_parse_json

	echo $BOARD_NAME


	if [ ! -d fw_log/$CPU_NAME/$BOARD_NAME ];then
		mkdir -p fw_log/$CPU_NAME/$BOARD_NAME
	fi


cat << EOF > .firefly_FW_log.tmp

## Date: $(date +%F)
* Firmware name: $IMGNAME
* Firmware MD5: $fw_md5
* rootfs: $real_rootfs_name
* SDK xml: $xml_version
Update content:

EOF

#$(cat fw_log/.ff_log_build/3_rootfs/common.md)

	local fw_overlay=0

	# 1_mk
	local local_mk=$(realpath device/rockchip/.BoardConfig.mk)
	local_mk=${local_mk##*/}
	local_mk=${local_mk%.mk*}

	if [ -d fw_log/.ff_log_build/1_mk/$local_mk ];then
		#echo 1_mk
		for i in $(find fw_log/.ff_log_build/1_mk/$local_mk/ -name overlay*)
		do
			cat $i >> .firefly_FW_log.tmp
			fw_overlay=1
		done

		if [ "$fw_overlay" = "0" ];then
			for i in $(find fw_log/.ff_log_build/1_mk/$local_mk/ -name "log*.md" -o -name "log*.txt")
			do
				cat $i >> .firefly_FW_log.tmp
			done
		fi

		# cat pre_log* to README_ZH.txt README_EN.txt
		for i in $(find fw_log/.ff_log_build/1_mk/$local_mk/ -name pre_log*)
		do
			cat $i | tee -a README_ZH.txt README_EN.txt > /dev/null
		done
	fi

	# 2_board
	if [ -d fw_log/.ff_log_build/2_board/$BOARD_NAME ] && [ "$fw_overlay" = "0" ];then
		#echo 2_board
		for i in $(find fw_log/.ff_log_build/2_board/$BOARD_NAME/ -name overlay*)
		do
			cat $i >> .firefly_FW_log.tmp
			fw_overlay=1
		done

		if [ "$fw_overlay" = "0" ];then
			for i in $(find fw_log/.ff_log_build/2_board/$BOARD_NAME/ -name "log*.md" -o -name "log*.txt")
			do
				cat $i >> .firefly_FW_log.tmp
			done
		fi

		# cat pre_log* to README_ZH.txt README_EN.txt
		for i in $(find fw_log/.ff_log_build/2_board/$BOARD_NAME/ -name pre_log*)
		do
			cat $i | tee -a README_ZH.txt README_EN.txt > /dev/null
		done

	fi

	for i in $(find fw_log/.ff_log_build/2_board/ -maxdepth 1 -name "common.md" -o -name "common.txt")
	do
		cat $i >> .firefly_FW_log.tmp
	done

	# 3_rootfs
	if [ $fw_overlay = 0 ] && [ -d fw_log/.ff_log_build/3_rootfs/$rootfs_name ];then
		#echo 3_rootfs
		for i in $(find fw_log/.ff_log_build/3_rootfs/$rootfs_name/ -name "log*.md" -o -name "log*.txt")
		do
			cat $i >> .firefly_FW_log.tmp
		done


	fi

	for i in $(find fw_log/.ff_log_build/3_rootfs/ -maxdepth 1 -name "common.md" -o -name "common.txt")
	do
		cat $i >> .firefly_FW_log.tmp
	done

	# create fw log

	if [ ! -f fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md ];then
		touch fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md
	fi

	# 防止固件名字重复
	local linc_cnt=$(sed -n '$=' fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md)
	local delete_start=0
	local delete_end=0
	delete_start=$(cat fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md | grep -n "* Firmware name: $IMGNAME" | awk -F ":" '{print $1}' | head -1)

	if [ "$delete_start" != "0" ] && [ -n "$delete_start" ]; then
		delete_start=$(expr $delete_start - 1)

		# 下一个Date：的上一行
		for i in $(cat fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md | grep -n "## Date:"| awk -F ":" '{print $1}')
		do
			if [ "$i" = "$delete_start" ];then
				delete_end=$linc_cnt
				continue
			fi

			if [ "$delete_end" != "0" ];then
				if [ "$i" -gt "$delete_start" ];then
					delete_end=$(expr $i - 1)
				fi
			fi
		done

		if [ "$delete_end" -gt "$delete_start" ];then
			sed -i ${delete_start},${delete_end}d fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md
		fi
	fi

	cat .firefly_FW_log.tmp > .firefly_FW_log.tmpb
	cat fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md >> .firefly_FW_log.tmpb
	cat .firefly_FW_log.tmpb > fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md

	cat fw_log/$CPU_NAME/$BOARD_NAME/${rootfs_name}.md | tee -a README_ZH.txt README_EN.txt > /dev/null
}

function build_pupdateimg(){
	# Use automatic naming instead of manual naming
	rename=0
	local local_mk=$(realpath device/rockchip/.BoardConfig.mk)
	local_mk=${local_mk##*/}
	local_mk=${local_mk%.mk*}


	if [ -f fw_log/.ff_log_build/3_rootfs/Fconfig ]; then
		local root_dir_build=$(ls fw_log/.ff_log_build/3_rootfs/  | grep -v "Fconfig")

		for rootfs_name in $root_dir_build; do
			#echo $rootfs_name

			if [ ! -f "fw_log/.ff_log_build/3_rootfs/$rootfs_name/rootfs.img" ]; then
				continue
			fi

			local root_mk_build=$(cat fw_log/.ff_log_build/3_rootfs/$rootfs_name/Fconfig)

			pack_flag=""

			for mk_root in $root_mk_build; do
				if [ "$mk_root" = "$local_mk" ]; then
					pack_flag="pack"
					break
				fi
			done

			if [ -z "$pack_flag" ];then
				continue
			fi

			create_fw_log

			#pack
			local pack_dir=`echo $IMAGE_PATH/pack/${IMGNAME}.7z | awk -F '.img' '{print $1}'`
			rm $pack_dir -rf
			mkdir $pack_dir -p
			mv $IMAGE_PATH/pack/$IMGNAME README_EN.txt README_ZH.txt $pack_dir

			echo -e "Move $IMGNAME to\t\e[33m$pack_dir\e[0m"

			mkdir -p $pack_dir/tools/linux
			mkdir -p $pack_dir/tools/windows
			mkdir -p $pack_dir/tools/mac

			if [ -f $TOP_DIR/tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool_*.zip ];then
				cp $TOP_DIR/tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool_*.zip $pack_dir/tools/linux/
			elif [ -f $TOP_DIR/tools/linux/Linux_Upgrade_Tool/upgrade_tool_*.zip ];then
				cp $TOP_DIR/tools/linux/Linux_Upgrade_Tool/upgrade_tool_*.zip $pack_dir/tools/linux/
			fi

			if [ -f $TOP_DIR/tools/windows/RKDevTool_Release_*.zip ];then
				cp $TOP_DIR/tools/windows/RKDevTool_Release_*.zip $pack_dir/tools/windows/
			fi

			if [ -d $TOP_DIR/tools/mac/upgrade_tool ];then
				cp $TOP_DIR/tools/mac/upgrade_tool/upgrade_tool_*_mac.zip $pack_dir/tools/mac/
			else
				rm -rf $pack_dir/tools/mac
			fi

			7z a ${pack_dir}.7z ${pack_dir}
		done
	fi

}

function build_allrelease_config(){
	count=0
	sum=""
	sum_soc=""
	sum_mk=""
	DIALOG=dialog

	rm -rf .save_soc
	rm -rf .save_mkfile
	rm -rf .allrelease

	soc=$(ls $TOP_DIR/device/rockchip/ | sort | grep -Ev "common|oem|rockimg|userdata" | awk -F '/' '{print $NF}')
	for name in $soc
	do
        	let count=count+1
        	sum_soc=$sum_soc"$name = $count "
	done
	$DIALOG --backtitle "Checklist" --checklist "Select Soc" 50 100 50 $sum_soc 2> .save_soc

	if [ $? -ne 0 ];then
        	exit -1
	fi

	dir=$(cat .save_soc)

	for name in $dir
	do
        	config_mkfile=$(ls $TOP_DIR/device/rockchip/$name/*.mk | grep  -v BoardConfig  | awk -F '/' '{print $NF}')
        	sum_mk=$sum_mk"$config_mkfile "
	done

	count=0
	for name in $sum_mk
	do
        	let count=count+1
        	sum=$sum"$name = $count "
	done

	echo $sum
	$DIALOG --backtitle "Checklist" --checklist "Select mkfile" 50 100 50 $sum 2> .save_mkfile
	if [ $? -ne 0 ];then
        	exit -1
	fi

	list=$(cat .save_mkfile| sort)

	for name in $list
	do
        	echo $name >> .allrelease
	done

}

function build_allrelease(){
	build_allrelease_config

	DIALOG=$TOP_DIR/device/rockchip/common/dialog
	if [ -a $TOP_DIR/.allrelease ]; then
		mk_list=$(cat $TOP_DIR/.allrelease)
	#{
		for mkfile in $mk_list;
		do
		        ./build.sh $mkfile
			BOARD_CONFIG=$TOP_DIR/device/rockchip/.BoardConfig.mk
			TARGET_PRODUCT="$TOP_DIR/device/rockchip/.target_product"
			TARGET_PRODUCT_DIR=$(realpath ${TARGET_PRODUCT})

			unset_board_config_all
			[ -L "$BOARD_CONFIG" ] && source $BOARD_CONFIG

			PARAMETER=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_PARAMETER
			SD_PARAMETER=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_SD_PARAMETER

			build_all
			build_firmware
			./build.sh pupdateimg
		done
	#} | $DIALOG --title "coping" --gauge "Starting to build..." 20 50 10
	else
		echo "No such .allrelease"
	fi
}

function build_allff(){
	build_all
	build_firmware
	build_updateimg
}

function build_allsave(){
	rm -fr $TOP_DIR/rockdev
	build_all
	build_firmware
	build_updateimg
	build_save

	finish_build
}

function create_keys() {
	test -d u-boot/keys && echo "ERROR: u-boot/keys has existed" && return -1

	mkdir u-boot/keys -p
	cd u-boot/keys
	$TOP_DIR/rkbin/tools/rk_sign_tool kk --bits 2048
	cd -

	ln -s private_key.pem u-boot/keys/dev.key
	ln -s public_key.pem u-boot/keys/dev.pubkey
	openssl req -batch -new -x509 -key u-boot/keys/dev.key -out u-boot/keys/dev.crt

	openssl rand -out u-boot/keys/system_enc_key -hex 32
}

function security_is_enabled()
{
	if [ "$RK_RAMDISK_SECURITY_BOOTUP" != "true" ]; then
		echo "No security paramter found in .BoardConfig.mk"
		exit -1
	fi
}


#=========================
# build targets
#=========================

if echo $@|grep -wqE "help|-h"; then
	if [ -n "$2" -a "$(type -t usage$2)" == function ]; then
		echo "###Current SDK Default [ $2 ] Build Command###"
		eval usage$2
	else
		usage
	fi
	exit 0
fi

OPTIONS="${@:-allff}"

[ -f "$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_BOARD_PRE_BUILD_SCRIPT" ] \
	&& source "$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_BOARD_PRE_BUILD_SCRIPT"  # board hooks

for option in ${OPTIONS}; do
	echo "processing option: $option"
	case $option in
		*.mk)
			if [ -f $option ]; then
				CONF=${option}
			else
				CONF=$(find $CFG_DIR -name $option)
				echo "switching to board: $CONF"
				if [ ! -f $CONF ]; then
					echo "not exist!"
					exit 1
				fi
			fi

		    ln -rsf $CONF $BOARD_CONFIG

			unset RK_PACKAGE_FILE
			source $CONF
			if [[ x"$RK_PACKAGE_FILE" != x ]];then
				PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware/rockdev/
				cd $PACK_TOOL_DIR
				rm -f package-file
				ln -sf $RK_PACKAGE_FILE package-file
			fi

			if [[ x"$RK_PARAMETER" != x ]];then
				PARAMETER=$TOP_DIR/device/rockchip/$RK_TARGET_PRODUCT/$RK_PARAMETER
				ln -sf $PARAMETER $ROCKDEV/parameter.txt
			else
				echo -e "\e[31m error: $SD_PARAMETER not found! \e[0m"
			fi

		    MKUPDATE_FILE=${RK_TARGET_PRODUCT}-mkupdate.sh
		    if [[ x"$MKUPDATE_FILE" != x-mkupdate.sh ]];then
				PACK_TOOL_DIR=$TOP_DIR/tools/linux/Linux_Pack_Firmware/rockdev/
				cd $PACK_TOOL_DIR
				rm -f mkupdate.sh
				ln -sf $MKUPDATE_FILE mkupdate.sh
			fi
			;;
		lunch) build_select_board ;;
		all) build_all ;;
		save) build_save ;;
		allsave) build_allsave ;;
		allff) build_allff ;;
		allff) build_allrelease ;;
		allrelease) build_allrelease ;;
		check) build_check ;;
		cleanall) build_cleanall ;;
		firmware) build_firmware ;;
		updateimg) build_updateimg ;;
		pupdateimg) build_pupdateimg ;;
		rawimg) build_rawimg ;;
		otapackage) build_otapackage ;;
		sdpackage) build_sdcard_package ;;
		toolchain) build_toolchain ;;
		spl) build_spl ;;
		uboot) build_uboot ;;
		uefi) build_uefi ;;
		loader) build_loader ;;
		kernel) build_kernel ;;
		extboot) build_extboot ;;
		kerneldeb) build_kerneldeb ;;
		wifibt)
			build_wifibt $2 $3
			exit 1 ;;
		modules) build_modules ;;
		rootfs_inst_mods) build_rootfs_install_modules ;;
		rootfs|buildroot|yocto) build_rootfs $option ;;
		debian) build_debian ;;
		pcba) build_pcba ;;
		ramboot) build_ramboot ;;
		recovery) build_recovery ;;
		multi-npu_boot) build_multi-npu_boot ;;
		info) build_info ;;
		app/*|external/*) build_pkg $option ;;
		createkeys) create_keys ;;
		security_boot) security_is_enabled; build_ramboot; build_uboot boot ;;
		security_uboot) security_is_enabled; build_uboot uboot ;;
		security_recovery) security_is_enabled; build_recovery; build_uboot recovery ;;
		security_check) check_security_condition ;;
		security_rootfs)
			security_is_enabled
			build_rootfs
			build_ramboot
			build_uboot
			echo "please update rootfs.img / boot.img"
			;;
		*) usage ;;
	esac
done
