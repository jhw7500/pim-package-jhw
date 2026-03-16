#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY_SCRIPT="$SCRIPT_DIR/cam_ap1302_dma_verify.sh"
CHANNEL_HELPER="$SCRIPT_DIR/cam_channel_resolve.sh"
FLASH_REG=0x3270
FLASH_MASK=0x01ff

show_help() {
    echo "Usage: $tag <channel> <value_hex> [port]"
    echo "  channel    : 0, 1, 2, or 3"
    echo "  value_hex  : target LED_FLASH_CONTROL value (example: 0x0103)"
    echo "  port       : default 0"
    echo
    echo "1) Reads current AR0234 LED_FLASH_CONTROL (0x3270)"
    echo "2) Writes the requested value through AP1302 DMA access"
    echo "3) Verifies enable/delay fields with mask 0x01ff"
    echo
    echo "Examples:"
    echo "  $tag 0 0x0100"
    echo "  $tag 0 0x0103"
    echo "  $tag 3 0x0000 0"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

parse_value() {
    local output=$1
    local label=$2
    local value

    value=$(printf "%s\n" "$output" | grep "$label" | sed -E 's/.*value=(0x[0-9a-fA-F]+).*/\1/' | tail -n 1)
    [[ -n "$value" ]] || return 1
    printf "%s\n" "$value"
}

decode_value() {
    local hex=$1
    local raw=$((hex))
    local masked=$(( raw & FLASH_MASK ))
    local enable=$(( (raw >> 8) & 1 ))
    local delay=$(( raw & 0xff ))
    local extra=$(( raw & ~FLASH_MASK ))

    printf 'raw=%s masked=0x%04x enable=%d delay=%d extra=0x%04x' \
        "$hex" "$masked" "$enable" "$delay" "$extra"
}

if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" || -z "$2" ]]; then
    show_help
    exit 0
fi

[[ -x "$VERIFY_SCRIPT" ]] || die "missing helper: $VERIFY_SCRIPT"
[[ -f "$CHANNEL_HELPER" ]] || die "missing helper: $CHANNEL_HELPER"

source "$CHANNEL_HELPER"

CHANNEL=$1
VALUE_HEX=$2
PORT=${3:-0}

resolve_channel_context "$CHANNEL"

VALUE=$((VALUE_HEX)) || die "invalid value_hex: $VALUE_HEX"
EXPECTED=$(( VALUE & FLASH_MASK ))

echo "[$tag] channel=$CHANNEL i2c_line=$BUS ap1302=$AP_ADDR mode=$MODE source=$RESOLVE_SOURCE port=$PORT reg=$FLASH_REG target=$VALUE_HEX"

OUTPUT=$("$VERIFY_SCRIPT" "$CHANNEL" "$FLASH_REG" "$VALUE_HEX" "$PORT" 2>&1)

BEFORE_HEX=$(parse_value "$OUTPUT" 'read-before') || die "failed to parse read-before"
AFTER_HEX=$(parse_value "$OUTPUT" 'read-after') || die "failed to parse read-after"

printf '[%s] before %s\n' "$tag" "$(decode_value "$BEFORE_HEX")"
printf '[%s] after  %s\n' "$tag" "$(decode_value "$AFTER_HEX")"

AFTER=$((AFTER_HEX))
if (( (AFTER & FLASH_MASK) == EXPECTED )); then
    echo "[$tag] verify: PASS (mask=0x01ff)"
    exit 0
fi

echo "[$tag] verify: FAIL expected_masked=$(printf '0x%04x' "$EXPECTED") actual_masked=$(printf '0x%04x' "$(( AFTER & FLASH_MASK ))")" >&2
exit 1
