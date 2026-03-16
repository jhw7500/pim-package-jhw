#!/bin/bash

tag=$(basename "$0")

show_help() {
    echo "Usage: $tag <channel> <reg_hex>"
    echo "  channel : 0~3 (ch0/1→subdev2, ch2/3→subdev3)"
    echo "  reg_hex : AR0234 register address (e.g. 0x3000)"
    echo
    echo "Examples:"
    echo "  $tag 0 0x3000     # chip ID"
    echo "  $tag 0 0x3070     # test pattern"
    echo "  $tag 2 0x3000     # ch2 chip ID"
}

if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" || -z "$2" ]]; then
    show_help
    exit 0
fi

CH=$1
REG_HEX=$2

case "$CH" in
    0) DEV=/dev/v4l-subdev2; CTRL=dma_reg_read_ch0 ;;
    1) DEV=/dev/v4l-subdev2; CTRL=dma_reg_read_ch1 ;;
    2) DEV=/dev/v4l-subdev3; CTRL=dma_reg_read_ch2 ;;
    3) DEV=/dev/v4l-subdev3; CTRL=dma_reg_read_ch3 ;;
    *) echo "[$tag] invalid channel: $CH (expected 0..3)" >&2; exit 1 ;;
esac

REG=$(printf "%d" "$REG_HEX" 2>/dev/null) || { echo "[$tag] invalid reg: $REG_HEX" >&2; exit 1; }
SET_VAL=$(( REG << 16 ))

v4l2-ctl -d "$DEV" -c "${CTRL}=${SET_VAL}" || exit 1

RAW_DEC=$(v4l2-ctl -d "$DEV" -C "$CTRL" | sed 's/.*: //')
RAW=$((RAW_DEC))
REG_OUT=$(( (RAW >> 16) & 0xffff ))
VAL_OUT=$(( RAW & 0xffff ))

printf '[%s] ch%d %s reg=0x%04x val=0x%04x (raw=0x%08x)\n' \
    "$tag" "$CH" "$DEV" "$REG_OUT" "$VAL_OUT" "$RAW"
