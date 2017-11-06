#!/bin/bash
SCRIPT_PATH="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"

# These are preset of this image
QEMU_ARGS=()
QEMU_ARGS+=(-M arm-generic-fdt-7series)
QEMU_ARGS+=(-machine linux=on)
QEMU_ARGS+=(-kernel "$SCRIPT_PATH/zImage")
QEMU_ARGS+=(-dtb "$SCRIPT_PATH/devicetree.dtb")
QEMU_ARGS+=(-append "root=/dev/mmcblk0p2 ro rootwait rootfstype=ext4")
QEMU_ARGS+=(-drive "if=sd,format=raw,index=0,file=$SCRIPT_PATH/rootfs.img")
QEMU_ARGS+=(-boot mode=5)

QEMU_ARGS+=(-m 1024)
QEMU_ARGS+=(--nographic)
QEMU_ARGS+=(-serial /dev/null)
QEMU_ARGS+=(-serial mon:stdio)
QEMU_ARGS+=(-chardev socket,server,nowait,path=qemu.monitor,id=monsock)
QEMU_ARGS+=(-mon chardev=monsock,mode=readline)

QEMU=qemu-system-aarch64
# Running QEMU with custom arguments and arguments passed to this script
# echo "Running command: $(which ${QEMU}) ${QEMU_ARGS[*]} $@"
${RUN_WITH_GDB} ${QEMU} "${QEMU_ARGS[@]}" "$@"
