#!/bin/bash

SCRIPT_NAME=$(basename "$0")

usage() {
    echo "Usage: $SCRIPT_NAME <channel> <command> [value]"
    echo "  channel: 0, 1, 2, 3"
    echo "  command: on, off, set, get"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME 0 on        # Enable channel 0"
    echo "  $SCRIPT_NAME 0 off       # Disable channel 0"
    echo "  $SCRIPT_NAME 0 set 0x10  # Set MCP4018 wiper value"
    echo "  $SCRIPT_NAME 0 get       # Get MCP4018 wiper value"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

CHANNEL=$1
COMMAND=$2

case "$CHANNEL" in
    0) I2C_BUS=2; I2C_ADDR=0x40 ;;
    1) I2C_BUS=2; I2C_ADDR=0x60 ;;
    2) I2C_BUS=1; I2C_ADDR=0x40 ;;
    3) I2C_BUS=1; I2C_ADDR=0x60 ;;
    *)
        echo "Error: Invalid channel '$CHANNEL'. Must be 0, 1, 2, or 3."
        exit 1
        ;;
esac

MCP4018_ADDR=0x2f

case "$COMMAND" in
    on)
        echo "Channel $CHANNEL ON: i2ctransfer -f -y -a $I2C_BUS w3@$I2C_ADDR 0x02 0xca 0x90"
        i2ctransfer -f -y -a "$I2C_BUS" w3@"$I2C_ADDR" 0x02 0xca 0x90
        ;;
    off)
        echo "Channel $CHANNEL OFF: i2ctransfer -f -y -a $I2C_BUS w3@$I2C_ADDR 0x02 0xca 0x80"
        i2ctransfer -f -y -a "$I2C_BUS" w3@"$I2C_ADDR" 0x02 0xca 0x80
        ;;
    set)
        if [ -z "$3" ]; then
            echo "Error: 'set' command requires a value argument."
            usage
        fi
        VALUE=$3
        echo "Channel $CHANNEL SET: i2cset -y $I2C_BUS $MCP4018_ADDR $VALUE"
        i2cset -y "$I2C_BUS" "$MCP4018_ADDR" "$VALUE"
        ;;
    get)
        echo "Channel $CHANNEL GET: i2cget -y $I2C_BUS $MCP4018_ADDR"
        i2cget -y "$I2C_BUS" "$MCP4018_ADDR"
        ;;
    *)
        echo "Error: Invalid command '$COMMAND'. Must be on, off, set, or get."
        exit 1
        ;;
esac
