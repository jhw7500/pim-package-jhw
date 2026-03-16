#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY_SCRIPT="$SCRIPT_DIR/cam_ap1302_dma_verify.sh"
FLASH_REG=0x3270
FLASH_MASK=0x01ff

show_help() {
    echo "Usage: $tag [channel] [ap1302_addr] [port]"
    echo "  channel    : default 0"
    echo "  ap1302_addr: optional override"
    echo "  port       : default 0"
    echo
    echo "Reads AR0234 LED_FLASH_CONTROL (0x3270) through AP1302 DMA access."
    echo "Prints raw value plus decoded enable/delay fields."
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

parse_value() {
    local output=$1
    local value

    value=$(printf "%s\n" "$output" | grep 'read-before' | sed -E 's/.*value=(0x[0-9a-fA-F]+).*/\1/' | tail -n 1)
    [[ -n "$value" ]] || return 1
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

echo "[$tag] channel=$CHANNEL ap1302=${AP_ADDR:-default} port=$PORT reg=$FLASH_REG"

if [[ -n "$AP_ADDR" ]]; then
    OUTPUT=$("$VERIFY_SCRIPT" "$CHANNEL" "$FLASH_REG" "" "$AP_ADDR" "$PORT" 2>&1) ||
        die "read failed"
else
    OUTPUT=$("$VERIFY_SCRIPT" "$CHANNEL" "$FLASH_REG" 2>&1) ||
        die "read failed"
fi

RAW_HEX=$(parse_value "$OUTPUT") || die "failed to parse read value"
RAW=$((RAW_HEX))
MASKED=$(( RAW & FLASH_MASK ))
ENABLE=$(( (RAW >> 8) & 1 ))
DELAY=$(( RAW & 0xff ))
EXTRA=$(( RAW & ~FLASH_MASK ))

printf '[%s] raw=%s masked=0x%04x enable=%d delay=%d extra=0x%04x\n' \
    "$tag" "$RAW_HEX" "$MASKED" "$ENABLE" "$DELAY" "$EXTRA"
