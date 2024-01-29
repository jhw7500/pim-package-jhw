#!/bin/bash

tag=$(basename "$0")

show_help() {
    echo "Usage: $tag [options]"
    echo "Options:"
    echo "arg1 : i2c line number"
    echo "arg2 : device address(hex)"
    echo "arg3 : register address(hex)"
    echo "arg4 : read byte number(int)"
}

if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" ]]; then
    show_help
    exit 0
fi

ad_len=$(expr length "$3")
ad0=$(($3>>8&0xff))
ad1=$(($3&0xff))
ad0=$(printf "0x%02x\n" $ad0)
ad1=$(printf "0x%02x\n" $ad1)

if [[ $ad_len == 4 ]]; then
    i2ctransfer -f -y -a $1 w1@$2 $ad1 r$4
elif [[ $ad_len == 6 ]]; then
    i2ctransfer -f -y -a $1 w2@$2 $ad0 $ad1 r$4
fi
