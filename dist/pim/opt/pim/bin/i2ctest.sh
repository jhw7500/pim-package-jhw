#!/bin/bash

tag=$(basename "$0")

show_help() {
    echo "Usage: $tag [options]"
    echo "Options:"
    echo "arg1 : i2c line number"
    echo "arg2 : des address(hex)"
    echo "arg3 : mode select(single:0, dual:1)"
    echo "arg4 : write delay(sec)"
}

if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" ]]; then
    show_help
    exit 0
fi
des0=$(printf "0x%02x\n" $2)
if [[ $des0 = 0x40 ]]; then
    des1=$(printf "0x%02x\n" 0x60)
else
    des1=$(printf "0x%02x\n" 0x40)
fi
echo "ser:0x48, des0:$des0, des1:$des1"
delay=$4

if [[ $3 == 0 ]]; then
i2cwrite $1 0x48 0x10 0x31
sleep $delay
i2cwrite $1 $des0 0x10 0x21
sleep $delay
i2cwrite $1 0x48 0x313 0x0
sleep $delay
i2cwrite $1 0x48 0x330 0x4
sleep $delay
i2cwrite $1 0x48 0x51 0x2
sleep $delay
i2cwrite $1 $des0 0x55 0x1
sleep $delay
i2cwrite $1 0x48 0x333 0x4e
sleep $delay
i2cwrite $1 0x48 0x334 0xe4
sleep $delay
i2cwrite $1 0x48 0x44a 0xc0
sleep $delay
i2cwrite $1 0x48 0x332 0x30
sleep $delay
i2cwrite $1 0x48 0x320 0x24
sleep $delay
i2cwrite $1 $des0 0x1 0x4
sleep $delay
i2cwrite $1 0x48 0x1 0x1
sleep $delay
i2cwrite $1 0x48 0x10 0x31
sleep $delay
i2cwrite $1 $des0 0x10 0x21
sleep $delay

elif [[ $3 == 1 ]]; then
i2cwrite $1 0x48 0x313 0x0
sleep $delay
#i2cwrite $1 0x48 0x10 0x31
i2cwrite $1 0x48 0x10 0x22
sleep $delay
i2cwrite $1 $des0 0x311 0xf0
sleep $delay
i2cwrite $1 $des0 0x308 0x7f
sleep $delay
i2cwrite $1 $des0 0x318 0x5e
sleep $delay
i2cwrite $1 $des0 0x2 0x43
sleep $delay
i2cwrite $1 $des0 0x10 0x21
sleep $delay
i2cwrite $1 0x48 0x332 0x30
sleep $delay
i2cwrite $1 0x48 0x331 0xf0
sleep $delay
i2cwrite $1 $des0 0x10 0x21
sleep $delay
#i2cwrite $1 0x48 0x10 0x32
#sleep $delay
#echo 5
i2cwrite $1 $des0 0x00 0xc0
sleep $delay
#echo 6

i2cwrite $1 0x48 0x10 0x32
sleep $delay
i2cwrite $1 $des1 0x10 0x31
sleep $delay
i2cwrite $1 $des1 0x6b 0x12
sleep $delay
i2cwrite $1 $des1 0x73 0x13
sleep $delay
i2cwrite $1 $des1 0x7b 0x32
sleep $delay
i2cwrite $1 $des1 0x83 0x32
sleep $delay
i2cwrite $1 $des1 0x93 0x32
sleep $delay
i2cwrite $1 $des1 0x9b 0x32
sleep $delay
i2cwrite $1 $des1 0xa3 0x32
sleep $delay
i2cwrite $1 $des1 0xab 0x32
sleep $delay
i2cwrite $1 $des1 0x8b 0x32
sleep $delay
i2cwrite $1 0x48 0x10 0x23
fi

