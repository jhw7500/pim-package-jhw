#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY_SCRIPT="$SCRIPT_DIR/cam_ap1302_dma_verify.sh"
CHANNEL_HELPER="$SCRIPT_DIR/cam_channel_resolve.sh"
FLASH_REG=0x3270
FLASH_MASK=0x01ff

show_help() {
    echo "Usage: $tag <channel> [port]"
    echo "  channel    : 0, 1, 2, or 3"
    echo "  port       : default 0"
    echo
    echo "Reads AR0234 LED_FLASH_CONTROL (0x3270) through AP1302 DMA access."
    echo "Prints raw value plus decoded enable/delay fields."
    echo
    echo "Examples:"
    echo "  $tag 0"
    echo "  $tag 3 0"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

parse_value() {
    local output=$1
    local value

    value=$(printf "%s\n" "$output" | grep 'read-before' | sed -E 's/.*value=(0x[0-9a-fA-F]+).*/\1/' | tail -n 1)
    [[ -n "$value" ]] || return 1
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

echo "[$tag] channel=$CHANNEL i2c_line=$BUS ap1302=$AP_ADDR mode=$MODE source=$RESOLVE_SOURCE port=$PORT reg=$FLASH_REG"

OUTPUT=$("$VERIFY_SCRIPT" "$CHANNEL" "$FLASH_REG" "" "$PORT" 2>&1) ||
    die "read failed"

RAW_HEX=$(parse_value "$OUTPUT") || die "failed to parse read value"
RAW=$((RAW_HEX))
MASKED=$(( RAW & FLASH_MASK ))
ENABLE=$(( (RAW >> 8) & 1 ))
DELAY=$(( RAW & 0xff ))
EXTRA=$(( RAW & ~FLASH_MASK ))

printf '[%s] raw=%s masked=0x%04x enable=%d delay=%d extra=0x%04x\n' \
    "$tag" "$RAW_HEX" "$MASKED" "$ENABLE" "$DELAY" "$EXTRA"
