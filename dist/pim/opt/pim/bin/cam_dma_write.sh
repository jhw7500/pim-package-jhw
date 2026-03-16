#!/bin/bash

tag=$(basename "$0")

show_help() {
    echo "Usage: $tag <channel> <reg_hex> <val_hex>"
    echo "  channel : 0~3 (ch0/1→subdev2, ch2/3→subdev3)"
    echo "  reg_hex : AR0234 register address (e.g. 0x3070)"
    echo "  val_hex : value to write (e.g. 0x0001)"
    echo
    echo "Examples:"
    echo "  $tag 0 0x3070 0x0001   # test pattern on"
    echo "  $tag 0 0x3070 0x0000   # test pattern off"
    echo "  $tag 0 0x3270 0x0103   # LED flash enable"
}

if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" || -z "$2" || -z "$3" ]]; then
    show_help
    exit 0
fi

CH=$1
REG_HEX=$2
VAL_HEX=$3

case "$CH" in
    0) DEV=/dev/v4l-subdev2; CTRL=dma_reg_write_ch0 ;;
    1) DEV=/dev/v4l-subdev2; CTRL=dma_reg_write_ch1 ;;
    2) DEV=/dev/v4l-subdev3; CTRL=dma_reg_write_ch2 ;;
    3) DEV=/dev/v4l-subdev3; CTRL=dma_reg_write_ch3 ;;
    *) echo "[$tag] invalid channel: $CH (expected 0..3)" >&2; exit 1 ;;
esac

REG=$(printf "%d" "$REG_HEX" 2>/dev/null) || { echo "[$tag] invalid reg: $REG_HEX" >&2; exit 1; }
VAL=$(printf "%d" "$VAL_HEX" 2>/dev/null) || { echo "[$tag] invalid val: $VAL_HEX" >&2; exit 1; }
SET_VAL=$(( (REG << 16) | (VAL & 0xffff) ))

v4l2-ctl -d "$DEV" -c "${CTRL}=${SET_VAL}" || exit 1

printf '[%s] ch%d %s reg=0x%04x val=0x%04x\n' \
    "$tag" "$CH" "$DEV" "$REG" "$VAL"
