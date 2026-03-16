#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY_SCRIPT="$SCRIPT_DIR/cam_ap1302_dma_verify.sh"
CHANNEL_HELPER="$SCRIPT_DIR/cam_channel_resolve.sh"

show_help() {
    echo "Usage: $tag <channel> [port]"
    echo "  channel    : 0, 1, 2, or 3"
    echo "  port       : default 0"
    echo
    echo "Dumps AR0234 clock / serial-format related registers through AP1302 DMA access."
    echo
    echo "Examples:"
    echo "  $tag 0"
    echo "  $tag 3 0"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

read_value() {
    local reg=$1
    local output value

    output=$("$VERIFY_SCRIPT" "$CHANNEL" "$reg" "" "$PORT" 2>&1) ||
        die "read failed for reg=$reg"

    value=$(printf "%s\n" "$output" | grep 'read-before' | sed -E 's/.*value=(0x[0-9a-fA-F]+).*/\1/' | tail -n 1)
    [[ -n "$value" ]] || die "failed to parse value for reg=$reg"
    printf "%s\n" "$value"
}

if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" ]]; then
    show_help
    exit 0
fi

[[ -x "$VERIFY_SCRIPT" ]] || die "missing helper: $VERIFY_SCRIPT"
[[ -f "$CHANNEL_HELPER" ]] || die "missing helper: $CHANNEL_HELPER"

source "$CHANNEL_HELPER"

CHANNEL=$1
PORT=${2:-0}

resolve_channel_context "$CHANNEL"

echo "[$tag] channel=$CHANNEL i2c_line=$BUS ap1302=$AP_ADDR mode=$MODE source=$RESOLVE_SOURCE port=$PORT"

printf "%-24s %-8s %s\n" "NAME" "REG" "VALUE"
printf "%-24s %-8s %s\n" "SERIAL_FORMAT" "0x31ae" "$(read_value 0x31ae)"
printf "%-24s %-8s %s\n" "VT_PIX_CLK_DIV" "0x302a" "$(read_value 0x302a)"
printf "%-24s %-8s %s\n" "VT_SYS_CLK_DIV" "0x302c" "$(read_value 0x302c)"
printf "%-24s %-8s %s\n" "PRE_PLL_CLK_DIV" "0x302e" "$(read_value 0x302e)"
printf "%-24s %-8s %s\n" "PLL_MULTIPLIER" "0x3030" "$(read_value 0x3030)"
printf "%-24s %-8s %s\n" "OP_PIX_CLK_DIV" "0x3036" "$(read_value 0x3036)"
printf "%-24s %-8s %s\n" "OP_SYS_CLK_DIV" "0x3038" "$(read_value 0x3038)"
printf "%-24s %-8s %s\n" "REG_30BA" "0x30ba" "$(read_value 0x30ba)"
