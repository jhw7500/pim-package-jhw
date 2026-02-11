#!/bin/bash
var=$1

echo "CAM exposure time set $var us"

hex_input=$(printf "%X" "$var")

while [ ${#hex_input} -lt 4 ]; do
    hex_input="0$hex_input"
done

echo "converted hex value: 0x$hex_input"

part1=${hex_input:0:2}
part2=${hex_input:2:2}

echo "0x50 0x06 0x$part1 0x$part2"

i2ctransfer -f -y -a 2 w4@0x3c 0x50 0x06 0x$part1 0x$part2 
i2ctransfer -f -y -a 1 w4@0x3c 0x50 0x06 0x$part1 0x$part2