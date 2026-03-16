#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY_SCRIPT="$SCRIPT_DIR/cam_ap1302_dma_verify.sh"

show_help() {
    echo "Usage: $tag [channel] [ap1302_addr] [port]"
    echo "  channel    : default 0"
    echo "  ap1302_addr: optional override"
    echo "  port       : default 0"
    echo
    echo "Dumps AR0234 clock / serial-format related registers through AP1302 DMA access."
    echo
    echo "Examples:"
    echo "  $tag"
    echo "  $tag 0"
    echo "  $tag 0 0x3c 0"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

read_value() {
    local reg=$1
    local output value

    if [[ -n "$AP_ADDR" ]]; then
        output=$("$VERIFY_SCRIPT" "$CHANNEL" "$reg" "" "$AP_ADDR" "$PORT" 2>&1) ||
            die "read failed for reg=$reg"
    else
        output=$("$VERIFY_SCRIPT" "$CHANNEL" "$reg" 2>&1) ||
            die "read failed for reg=$reg"
    fi

    value=$(printf "%s\n" "$output" | grep 'read-before' | sed -E 's/.*value=(0x[0-9a-fA-F]+).*/\1/' | tail -n 1)
    [[ -n "$value" ]] || die "failed to parse value for reg=$reg"
    printf "%s\n" "$value"
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

[[ -x "$VERIFY_SCRIPT" ]] || die "missing helper: $VERIFY_SCRIPT"

CHANNEL=${1:-0}
AP_ADDR=${2:-}
PORT=${3:-0}

echo "[$tag] channel=$CHANNEL ap1302=${AP_ADDR:-default} port=$PORT"

printf "%-24s %-8s %s\n" "NAME" "REG" "VALUE"
printf "%-24s %-8s %s\n" "SERIAL_FORMAT" "0x31ae" "$(read_value 0x31ae)"
printf "%-24s %-8s %s\n" "VT_PIX_CLK_DIV" "0x302a" "$(read_value 0x302a)"
printf "%-24s %-8s %s\n" "VT_SYS_CLK_DIV" "0x302c" "$(read_value 0x302c)"
printf "%-24s %-8s %s\n" "PRE_PLL_CLK_DIV" "0x302e" "$(read_value 0x302e)"
printf "%-24s %-8s %s\n" "PLL_MULTIPLIER" "0x3030" "$(read_value 0x3030)"
printf "%-24s %-8s %s\n" "OP_PIX_CLK_DIV" "0x3036" "$(read_value 0x3036)"
printf "%-24s %-8s %s\n" "OP_SYS_CLK_DIV" "0x3038" "$(read_value 0x3038)"
printf "%-24s %-8s %s\n" "REG_30BA" "0x30ba" "$(read_value 0x30ba)"
