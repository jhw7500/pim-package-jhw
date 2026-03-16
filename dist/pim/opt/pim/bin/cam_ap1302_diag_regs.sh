#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
I2C_READ="$SCRIPT_DIR/i2cread.sh"

show_help() {
    echo "Usage: $tag [channel] [ap1302_addr]"
    echo "  channel     : default 0"
    echo "  ap1302_addr : optional override (example: 0x3c)"
    echo
    echo "Reads AP1302 diagnostic registers used to validate sensor indirect access setup."
    echo "Default AP1302 address comes from the channel mapping below:"
    echo "  ch0 -> bus2, 0x11"
    echo "  ch1 -> bus2, 0x12"
    echo "  ch2 -> bus1, 0x11"
    echo "  ch3 -> bus1, 0x12"
    echo
    echo "Registers:"
    echo "  0x0014 : SIPM_ERR_0 (2 bytes)"
    echo "  0x0016 : SIPM_ERR_1 (2 bytes)"
    echo "  0x600c : SENSOR_SELECT (2 bytes)"
    echo "  0x604a : PRIMARY_SENSOR_SIP (2 bytes)"
    echo "  0x604c : SECONDARY_SENSOR_SIP (4 bytes)"
    echo
    echo "Examples:"
    echo "  $tag"
    echo "  $tag 0"
    echo "  $tag 0 0x3c"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

get_bus_and_ap() {
    case "$1" in
        0) BUS=2; AP_ADDR=0x11 ;;
        1) BUS=2; AP_ADDR=0x12 ;;
        2) BUS=1; AP_ADDR=0x11 ;;
        3) BUS=1; AP_ADDR=0x12 ;;
        *) die "invalid channel: $1 (expected 0..3)" ;;
    esac
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

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

[[ -x "$I2C_READ" ]] || die "missing helper: $I2C_READ"

CHANNEL=${1:-0}
get_bus_and_ap "$CHANNEL"

if [[ -n "${2:-}" ]]; then
    AP_ADDR=${2,,}
fi

echo "[$tag] channel=$CHANNEL bus=$BUS ap1302=$AP_ADDR"

read_reg 0x0014 2 "SIPM_ERR_0"
read_reg 0x0016 2 "SIPM_ERR_1"
read_reg 0x600c 2 "SENSOR_SELECT"
read_reg 0x604a 2 "PRIMARY_SENSOR_SIP"
read_reg 0x604c 4 "SECONDARY_SENSOR_SIP"
