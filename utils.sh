# Copyright (c) 2017, MIT Licensed, Medicine Yeh

# NOTE: ${BASH_SOURCE[0]} is 'utils.sh' while $0 is 'build.sh'
SCRIPT_DIR=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")
BUILD_DIR="${SCRIPT_DIR}/build"
INSTALL_DIR="${SCRIPT_DIR}"
BUILD_SCRIPT=$(readlink -f "$0")
FAKEROOT_ENV="fakeroot.env"

COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'
COLOR_GREEN='\033[1;32m'
NC='\033[0m'

#######################################
# Check whether the function is defined
# Globals:
#   None
# Arguments:
#   <FUNCTION>
# Returns:
#   succeed:0 / failed:1
#######################################
function function_exists() {
    declare -f -F $1 > /dev/null
    return $?
}

#######################################
# Call a function only when it presents
# Globals:
#   None
# Arguments:
#   <FUNCTION>
# Returns:
#   None
#######################################
function invoke() {
    declare -f -F $1 > /dev/null
    if [[ $? == 0 ]]; then
        echo -e "Running ${COLOR_GREEN}${1}${NC}"
        $1
        return 0
    else
        return 1
    fi
}

#######################################
# Check whether the command exist in a safe way
# Globals:
#   None
# Arguments:
#   <command>
# Returns:
#   0: found, 1: NOT found
#######################################
function command_exist() {
    command_found=$(command -v "$1" 2> /dev/null)
    if [[ "$command_found" == "" ]]; then
        return 1 # NOT found
    else
        return 0 # Found
    fi
}

#######################################
# Check the sha256sum and return 0 when succeed.
# Always return 0 if the first argument is an empty string.
# Globals:
#   None
# Arguments:
#   <FILE PATH>
#   <SHA256SUM>
# Returns:
#   succeed:0 / failed:1
#######################################
function check_sha256() {
    local sum=$(sha256sum -b "$1" | cut -d " " -f1)
    [[ "" == "$2" ]] && return 0     # return success if the target comparison is empty
    [[ "$sum" == "$2" ]] && return 0 # success
    return 1 # fail
}

#######################################
# Simply print messages and exit with error number 1.
# This is used to indicate user what happened in the build system.
# Globals:
#   None
# Arguments:
#   <MESSAGE>
# Returns:
#   None
#######################################
function print_message_and_exit() {
    echo "Something went wrong?"
    echo -e "Possibly related to ${COLOR_YELLOW}${1}${NC}"
    exit 1
}

#######################################
# Decompress the tar file and rename the directory only when target does not exist.
# Specify the third arg to strip the number of top level directories
# Globals:
#   None
# Arguments:
#   <COMPRESSED FILE>
#   <TARGET DIRECTORY>
#   <# of STRIPPED COMPONENTS>
# Returns:
#   None
#######################################
function unfold() {
    local target_file="$1"
    local target_dir="$2"
    local strip_num="$3"

    # Try to remove empty directory if present, this helps to recover from failed decompressing
    [[ -d "$target_dir" ]] && rmdir --ignore-fail-on-non-empty "$target_dir"
    [[ -d "$target_dir" ]] && return 0 # Do nothing if target dir exists
    [[ "$strip_num" == "" ]] && strip_num=0 # Set this number to 0 if not present

    echo -e "${COLOR_GREEN}decompress file $target_file to $target_dir${NC}"
    mkdir -p "$target_dir"
    tar --warning=no-unknown-keyword --strip-components=$strip_num -xf "$target_file" -C "$target_dir"
    [[ $? != 0 ]] && print_message_and_exit "Decompressing $target_file"
}

#######################################
# A simple wrapper to remove and create a directory.
# Use it with caution!!!!!!!!!
# Globals:
#   None
# Arguments:
#   <DIR PATH>
# Returns:
#   None
#######################################
function rm_and_mkdir() {
    rm -rf "$1"
    mkdir -p "$1"
}

#######################################
# Create an image with partition table(MBR)
# Example create_guest_image rootfs.img 4G "size=50M, type=c" "type=83"
# Globals:
#   None
# Arguments:
#   <IMAGE NAME>
#   <IMAGE SIZE>
#   <sfdisk SCRIPT>
#   [sfdisk SCRIPT ...]
# Returns:
#   None
#######################################
function create_guest_image() {
    local image_file="$1"
    local num_sectors=$[ $(numfmt --from=iec ${2:-0}) / 512 ]

    # Remove the old file in order to overwrite the output file
    rm -f "$image_file"
    dd if=/dev/zero of=$image_file bs=512 seek=$[ $num_sectors - 1 ] count=1
    [[ $? != 0 ]] && print_message_and_exit "Allocate $image_file with size $image_size"

    shift 2 # Shift out the first two arguments
    # Transform the rest of input args to a line separated string
    sfdisk_script=$(printf '%s\n' "${@}")
    echo "$sfdisk_script" | sfdisk -uS $image_file
}

#######################################
# Create an image with partition table(MBR)
# The size of each partition is fixed for easy reading
# and the best compatibility.
# Example create_guest_image_fixed rootfs.img 4G
# Globals:
#   None
# Arguments:
#   <IMAGE NAME>
#   <IMAGE SIZE>
# Returns:
#   None
#######################################
function create_guest_image_fixed() {
    local image_file="$1"
    local num_sectors=$[ $(numfmt --from=iec ${2:-0}) / 512 ]

    # Remove the old file in order to overwrite the output file
    rm -f "$image_file"
    dd if=/dev/zero of=$image_file bs=512 seek=$[ $num_sectors - 1 ] count=1
    [[ $? != 0 ]] && print_message_and_exit "Allocate $image_file with size $image_size"

    sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk ${image_file}
  o # clear the in memory partition table
  n # new partition
  p # primary partition
  1 # partition number 1
    # default - start at beginning of disk
  +100M # 100 MB boot parttion
  n # new partition
  p # primary partition
  2 # partion number 2
    # default, start immediately after preceding partition
    # default, extend partition to end of disk
  a # make a partition bootable
  1 # bootable partition is partition 1 -- /dev/sda1
  p # print the in-memory partition table
  w # write the partition table
  q # and we're done
EOF
}

#######################################
# A simple function to help checking the availability of binfmts
# Example: test_binfmt_enabled qemu-aarch64 qemu-arm
# Globals:
#   None
# Arguments:
#   [NAMES ...]
# Returns:
#   None
#######################################
function test_binfmt_enabled() {
    if [[ ! -d /proc/sys/fs/binfmt_misc ]]; then
        # NOTE: This should be a service and mounted before any operation
        print_message_and_exit "binfmt_misc is not mounted, Please try
        'sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc'"
    fi
    if [[ "$(update-binfmts --version)" == "" ]]; then
        print_message_and_exit "Please install command update-binfmts"
    fi

    for name in "${@}"; do
        str=$(update-binfmts --test --enable "$name" 2>&1 | grep "already enabled")
        # No enabled message in the output
        [[ "$str" == "" ]] && print_message_and_exit "Cannot find $name in binfmt Please run
        'sudo update-binfmts --enable $name'"
    done
}

#######################################
# A simple wrapper function to help get the user:group id
# This function will echo a string in the form of USER_ID:GROUP_ID
# Globals:
#   None
# Arguments:
#   <FILE/DIR PATH>
# Returns:
#   None
#######################################
function get_user_group_id() {
    # stat file only when exist
    [[ -r "$1" ]] && stat -c "%u:%g" "$1"
}

#######################################
# A simple wrapper function to help copy files in destination ownership
# Globals:
#   None
# Arguments:
#   <SOURCE FILE/DIR PATH>
#   <DESTINATION FILE/DIR PATH>
# Returns:
#   succeed:0 / failed:1
#######################################
function cp_target_owner() {
    local src="$1"
    local dst="$2"
    local dst_owner=$(get_user_group_id "$dst")
    [[ "$dst_owner" == "" ]] && dst_owner=$(get_user_group_id "$(dirname $dst)")
    [[ "$dst_owner" == "" ]] && print_message_and_exit "Cannot find/get state of '$dst'"
    rsync -a -o -g --chown=$dst_owner "$src" "$dst"
    return $?
}

#######################################
# A simple wrapper to execute a command with sudo and tell user what it is.
# This is useful to show useful messages on why aquiring the root privileges.
# Globals:
#   None
# Arguments:
#   <COMMAND>
#   [ARGS ...]
# Returns:
#   None
#######################################
function inform_sudo() {
    echo "PWD: $(pwd)"
    echo -e "Running ${COLOR_YELLOW}sudo $@${NC}"
    sudo echo "" # Dummy command
    [[ $? != 0 ]] && echo -e "${COLOR_RED}Abort${NC}" && exit 1
    sudo "$@"
}

#######################################
# Download the source codes from links if and only if the file does not present
# If the link starts with "git+", this function will use git to clone the target.
# Notice that this function use .download as a temporary file to download the targets
# and then rename the file after completion.
# Globals:
#   files       -> array of names to be renamed
#   sources     -> array of links
#   sha256sums  -> array of sha256sum ID (leave empty to suppress the checking)
# Arguments:
#   None
# Returns:
#   None
#######################################
function sources_auto_download() {
    for index in "${!files[@]}"; do
        local tmp_file="${files[$index]}.download"
        local link="${sources[$index]}"

        if [[ "$link" == "git+"* ]]; then
            link="${link##git+}"  # Remove git+ word
            # git clone if the target deos not exist
            if [[ ! -d "${files[$index]}" ]]; then
                git clone --depth 10 "$link" "${files[$index]}"
                [[ $? != 0 ]] && print_message_and_exit "git clone to '${files[$index]}'"
            fi
        else
            # Download link as a temporary file (*.download)
            [[ ! -f "${files[$index]}" ]] && wget -c "$link" -O "$tmp_file"
            # Rename the file after completion
            [[ $? == 0 ]] && mv "$tmp_file" "${files[$index]}"
            # Print fail if the file does not exist
            [[ ! -f "${files[$index]}" ]] && print_message_and_exit "Download '${files[$index]}'"
            # Check sha256 sum
            check_sha256 "${files[$index]}" ${sha256sums[$index]}
            [[ $? != 0 ]] && print_message_and_exit "'${files[$index]}' sha256sum does not match!!"
        fi
    done
}

#######################################
# Install the generated files with symbolic links
# Globals:
#   file_name  -> path of file relative to $BUILD_DIR
#   [new_name] -> (optional) path of file to be installed/renamed relative to $INSTALL_DIR
# Arguments:
#   None
# Returns:
#   succeed:0 / failed:1
#######################################
function install_binary() {
    local file_name="$1"
    local new_name="$2"

    [[ "$file_name" == "" ]] && return 1
    # Overwrite if and only if it's not a regular file for safety
    if [[ -f "${INSTALL_DIR}/${new_name}" ]]; then
        echo -e "File ${COLOR_RED}${INSTALL_DIR}/${new_name}${NC} exists and not a symbolic file"
        return 1
    else
        ln -sf "$BUILD_DIR/${file_name}" "${INSTALL_DIR}/${new_name}"
    fi
}

#######################################
# Install the generated files with symbolic links
# Globals:
#   FAKEROOT_ENV  -> path of file relative to store fakeroot env
# Arguments:
#   None
# Returns:
#   None
#######################################
function enter_fake_root() {
    # Prepare to enter the last step
    echo -e "${COLOR_GREEN}Entering faked root env${NC}"
    touch "${BUILD_DIR}/${FAKEROOT_ENV}"
    # Do not load env here. If the script touches real root files, it might cause some problems.
    cd "$SCRIPT_DIR" && fakeroot -s $FAKEROOT_ENV -- $BUILD_SCRIPT "$@"
    echo -e "${COLOR_GREEN}Done${NC}"
}

#######################################
# The main function of the simple build system
# Globals:
# pre_install   -> a function to prepare all the files and sources for latter use
# prepare       -> a function to config and prepare source codes
# build         -> a function to build the source codes
# post_install  -> a function to generate/install the files (will be run in root user)
# Arguments:
#   None
# Returns:
#   None
#######################################
function build_system_main() {
    # Change the root directory first
    cd "$SCRIPT_DIR"
    echo -e "Creating build directory: ${COLOR_GREEN}${BUILD_DIR}${NC}"
    mkdir -p "$BUILD_DIR"

    if [[ "$(whoami)" == "root" ]]; then
        # Runs post system only when we are in fakeroot environment
        cd "$BUILD_DIR" && invoke post_install
    else
        if [[ -z "$1" ]]; then
            cd "$BUILD_DIR" && invoke sources_auto_download
            cd "$BUILD_DIR" && invoke pre_install
            cd "$BUILD_DIR" && invoke prepare
            cd "$BUILD_DIR" && invoke build
            cd "$BUILD_DIR" && enter_fake_root
        else
            cd "$BUILD_DIR"
            # User defined build stage
            [[ "$1" == "sources_auto_download" ]] && invoke sources_auto_download
            [[ "$1" == "pre_install" ]] && invoke pre_install
            [[ "$1" == "prepare" ]] && invoke prepare
            [[ "$1" == "build" ]] && invoke build
            [[ "$1" == "post_install" ]] && enter_fake_root
        fi
    fi
}
