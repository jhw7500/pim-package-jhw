#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
I2C_READ="$SCRIPT_DIR/i2cread.sh"
CHANNEL_HELPER="$SCRIPT_DIR/cam_channel_resolve.sh"

show_help() {
    echo "Usage: $tag <channel>"
    echo "  channel     : 0, 1, 2, or 3"
    echo
    echo "Reads AP1302 diagnostic registers used to validate sensor indirect access setup."
    echo "Bus and AP1302 address are auto-resolved from channel + edgeconf/i2cdetect."
    echo
    echo "Registers:"
    echo "  0x0014 : SIPM_ERR_0 (2 bytes)"
    echo "  0x0016 : SIPM_ERR_1 (2 bytes)"
    echo "  0x600c : SENSOR_SELECT (2 bytes)"
    echo "  0x604a : PRIMARY_SENSOR_SIP (2 bytes)"
    echo "  0x604c : SECONDARY_SENSOR_SIP (4 bytes)"
    echo
    echo "Examples:"
    echo "  $tag 0"
    echo "  $tag 3"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

read_reg() {
    local reg=$1
    local bytes=$2
    local label=$3
    local output

    output=$("$I2C_READ" "$BUS" "$AP_ADDR" "$reg" "$bytes") ||
        die "read failed: $label reg=$reg bytes=$bytes bus=$BUS ap1302=$AP_ADDR"

    echo "[$tag] $label ($reg, ${bytes}B): $output"
}

if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" ]]; then
    show_help
    exit 0
fi

[[ -x "$I2C_READ" ]] || die "missing helper: $I2C_READ"
[[ -f "$CHANNEL_HELPER" ]] || die "missing helper: $CHANNEL_HELPER"

source "$CHANNEL_HELPER"

CHANNEL=$1
resolve_channel_context "$CHANNEL"

echo "[$tag] channel=$CHANNEL i2c_line=$BUS ap1302=$AP_ADDR mode=$MODE source=$RESOLVE_SOURCE"

read_reg 0x0014 2 "SIPM_ERR_0"
read_reg 0x0016 2 "SIPM_ERR_1"
read_reg 0x600c 2 "SENSOR_SELECT"
read_reg 0x604a 2 "PRIMARY_SENSOR_SIP"
read_reg 0x604c 4 "SECONDARY_SENSOR_SIP"
