# Copyright (c) 2017, MIT Licensed, Medicine Yeh

# NOTE: ${BASH_SOURCE[0]} is 'utils.sh' while $0 is 'build.sh'
SCRIPT_DIR=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")
BUILD_DIR="${SCRIPT_DIR}/build"
INSTALL_DIR="${SCRIPT_DIR}"
BUILD_SCRIPT=$(readlink -f "$0")

COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'
COLOR_GREEN='\033[1;32m'
NC='\033[0m'

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
# A simple wrapper to remove and create a directory
# Globals:
#   None
# Arguments:
#   <DIR PATH>
# Returns:
#   None
#######################################
function rm_and_mkdir() {
    cd "${SCRIPT_DIR}" # This is a safety in case someone gives a relative path
    rm -rf $1
    mkdir -p $1
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
# Creating a image with partition table
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
        [[ ! -f "${files[$index]}" ]] && wget -c "${sources[$index]}" -O "$tmp_file"
        [[ $? == 0 ]] && mv "$tmp_file" "${files[$index]}"
        [[ ! -f "${files[$index]}" ]] && print_message_and_exit "Download '${files[$index]}'"
        check_sha256 "${files[$index]}" ${sha256sums[$index]}
        [[ $? != 0 ]] && print_message_and_exit "'${files[$index]}' sha256sum does not match!!"
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
        echo -e "Running ${COLOR_GREEN}post_install${NC}"
        cd "$BUILD_DIR" && post_install
    else
        # Change the root directory on every function call for consistent working directory
        echo -e "Running ${COLOR_GREEN}sources_auto_download${NC}"
        cd "$BUILD_DIR" && sources_auto_download
        echo -e "Running ${COLOR_GREEN}pre_install${NC}"
        cd "$BUILD_DIR" && pre_install
        echo -e "Running ${COLOR_GREEN}prepare${NC}"
        cd "$BUILD_DIR" && prepare
        echo -e "Running ${COLOR_GREEN}build${NC}"
        cd "$BUILD_DIR" && build
        echo -e "${COLOR_GREEN}Entering faked root env${NC}"
        cd "$SCRIPT_DIR" && fakeroot $BUILD_SCRIPT "$@"
    fi
}
