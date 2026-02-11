#!/bin/bash
var=$1

echo "CAM exposure time set $var us"

hex_input=$(printf "%X" "$var")

while [ ${#hex_input} -lt 8 ]; do
    hex_input="0$hex_input"
done

echo "converted hex value: 0x$hex_input"

part1=${hex_input:0:2}
part2=${hex_input:2:2}
part3=${hex_input:4:2}
part4=${hex_input:6:2}

echo "0x50 0x0c 0x$part1 0x$part2 0x$part3 0x$part4"

i2ctransfer -f -y -a 2 w6@0x3c 0x50 0x0c 0x$part1 0x$part2 0x$part3 0x$part4
i2ctransfer -f -y -a 1 w6@0x3c 0x50 0x0c 0x$part1 0x$part2 0x$part3 0x$part4
	

