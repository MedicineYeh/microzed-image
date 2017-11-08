#!/bin/bash
SCRIPT_DIR=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")
# NOTE: $BUILD_DIR will be loaded from utils.sh

config_name='kernel-4.6.0.config'
kernel_folder='linux-xlnx'
guest_image='rootfs.img'
bootfs='bootfs'
rootfs='rootfs'

ARCH=arm
CROSS=arm-linux-gnueabi-

files=($config_name
       'xilinx-v2016.4.tar.gz'
       'ArchLinuxARM-zedboard-latest.tar.gz'
       'BOOT.bin')

sources=('http://vserver.13thfloor.at/Stuff/AXIOM/BETA/kernel-4.6.0-xilinx-00016-gb49271f.config'
         'https://github.com/Xilinx/linux-xlnx/archive/xilinx-v2016.4.tar.gz'
         'http://archlinuxarm.org/os/ArchLinuxARM-zedboard-latest.tar.gz'
         'http://vserver.13thfloor.at/Stuff/JARHAB/boot.bin')

sha256sums=('ecc33bfcf9a66d766870953bacf0b5313798c60c988f5c96bcce397c74fd7120'
            '2e97f9f66eaaf4833e99647ec595798480ccb46f8f0df39ebd651cabc06b3c87'
            '' # Skip sha256 sum on the changing target
            '23fdc710069efbfd48479f3633c085db3ea21922691c8945e5d5869bc3b0a5fb')

# Prepare all the files and sources for latter use
function pre_install() {
    [[ ! -d "mbrfs" ]] && git clone https://github.com/snippits/mbrfs

    # Alternative ways of downloading the linux kernel, but hard to have a centeralized control
    #local kernel_link='https://github.com/Xilinx/linux-xlnx.git'
    #local kernel_name='linux-xlnx.git'
    #if [[ ! -d "$kernel_name" ]]; then
    #    git clone --branch xilinx-v2016.4 --depth 1 "$kernel_link" "$kernel_name"
    #fi
    return 0 # This is used to surpress the error of empty function
}

# Config and prepare source codes
function prepare() {
    unfold 'xilinx-v2016.4.tar.gz' $kernel_folder 1

    # Add config to linux
    cd "${BUILD_DIR}/${kernel_folder}"
    [[ $? != 0 ]] && print_message_and_exit "Directory ${kernel_folder} does not existed"
    cp "../${config_name}" .config
    [[ $? != 0 ]] && print_message_and_exit "${config_name} does not existed"
    make CROSS_COMPILE=$CROSS ARCH=$ARCH oldconfig
    [[ $? != 0 ]] && print_message_and_exit "Setting up linux kernel config"
}

# Build the source codes
function build() {
    # Build linux
    cd "${BUILD_DIR}/${kernel_folder}"
    make CROSS_COMPILE=$CROSS ARCH=$ARCH -j$(nproc)
    [[ $? != 0 ]] && print_message_and_exit "Make linux kernel"

    # Build helper for mounting the mbr file system
    cd "${BUILD_DIR}/mbrfs" && make
    [[ $? != 0 ]] && print_message_and_exit "Build mbrfs"
}

# Generate/install the files (will be run in root user)
function post_install() {
    rm_and_mkdir "${BUILD_DIR}/${rootfs}"
    rm_and_mkdir "${BUILD_DIR}/${bootfs}"

    # Set up third-party binaries first
    PATH="$PATH":"${BUILD_DIR}/mbrfs"
    # Copy linux files
    cp "./${kernel_folder}/arch/arm/boot/zImage" ./zImage
    cp "./${kernel_folder}/arch/arm/boot/dts/zynq-zed.dtb" ./devicetree.dtb

    # Copy kernel and uboot to bootfs
    # TODO, should be uImage and BOOT.bin built from this package
    cp ./{zImage,BOOT.bin} "./${bootfs}"
    # Copy all the prebuilt files from microzed-boot to created bootfs folder
    cp "${SCRIPT_DIR}"/microzed-boot/* "./${bootfs}"
    [[ $? != 0 ]] && print_message_and_exit "Copy files to '${bootfs}'"

    cd ${BUILD_DIR}
    echo "Decompressing template rootfs file... (this may take a while)"
    tar --warning=no-unknown-keyword -xpf 'ArchLinuxARM-zedboard-latest.tar.gz' -C "$rootfs"
    [[ $? != 0 ]] && print_message_and_exit "Preparing guest rootfs"
    sync

    # Install kernel modules to guest images
    cd "${BUILD_DIR}/${kernel_folder}"
    [[ ! -d "../${rootfs}" ]] && print_message_and_exit "${BUILD_DIR}/${rootfs} does not exist"
    make CROSS_COMPILE=$CROSS ARCH=$ARCH INSTALL_MOD_PATH="../${rootfs}" modules_install
    [[ $? != 0 ]] && print_message_and_exit "Install kernel modules"

    cd ${BUILD_DIR}
    patch_rootfs "$rootfs"
    compile_image "$guest_image"

    # Finally link all target to the root directory
    install_binary "zImage"
    install_binary "devicetree.dtb"
    install_binary "rootfs.img"
    # Install if and only if the target file is a symbolic file
    [[ -L "${INSTALL_DIR}/runQEMU.sh" ]] && install_binary "../runQEMU.sh"
}

# Patch the root file system (Note: This function would be run in a faked root user env)
function patch_rootfs() {
    echo "To be implemented: patch_rootfs()"
}

# Build up guest image (Note: This function would be run in a faked root user env)
function compile_image() {
    local tmp_mountpoint=".mount.point"
    local image_file="$1"
    cd "${BUILD_DIR}"

    # Quietly force umount with always true to surpress the error codes
    LD_PRELOAD='' fusermount -quz "$tmp_mountpoint" || true
    # Create dir if not present
    mkdir -p "$tmp_mountpoint"

    # Create a guest image with size 4G and assigning the spaces of partitions
    # create_guest_image_fixed "$image_file" 4G
    create_guest_image "$image_file" 4G "size=50M, type=b" "size=4G, type=83"
    mbrfs "$image_file" "$tmp_mountpoint"
    [[ $? != 0 ]] && print_message_and_exit "Mount(FUSE) $image_file to $tmp_mountpoint"

    # Copy boot partition files to the first partition
    mkfs.vfat -n "BOOT" -F 32 "${tmp_mountpoint}/1"
    mcopy -i "${tmp_mountpoint}/1" ${bootfs}/* ::
    [[ $? != 0 ]] && print_message_and_exit "Create BOOT partition"

    # Copy root partition files to the second partition
    mkfs.ext4 -d ${rootfs} "${tmp_mountpoint}/2"
    [[ $? != 0 ]] && print_message_and_exit "Create ROOT partition"

    sync
    # Quietly force umount with always true to surpress the error codes
    LD_PRELOAD='' fusermount -quz "$tmp_mountpoint" || true
}

# =================================
# ======= Utility functions =======
source "${SCRIPT_DIR}/utils.sh"
# ==== Endof utility functions ====
# =================================

# Run the main function of the build system with perfect argument forwarding (escape spaces)
build_system_main "$@"

exit 0
