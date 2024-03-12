#!/bin/bash

tag=$(basename "$0")

show_help() {
    echo "Usage: $tag [options]"
    echo "Options:"
    echo "arg1 : i2c line number"
    echo "arg2 : device address(hex)"
    echo "arg3 : register address(hex)"
    echo "arg4 : data(hex)"
    echo "arg5 : delay(msec)"
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

val_len=$(expr length "$4")
#echo $val_len
val0=$(($4>>24&0xff))
val1=$(($4>>16&0xff))
val2=$(($4>>8&0xff))
val3=$(($4&0xff))
val0=$(printf "0x%02x\n" $val0)
val1=$(printf "0x%02x\n" $val1)
val2=$(printf "0x%02x\n" $val2)
val3=$(printf "0x%02x\n" $val3)

if [[ $ad_len == 4 ]]; then
    if [[ $val_len == 4 ]]; then
        echo "i2ctransfer -f -y -a $1 w2@$2 $ad1 $val3"
        i2ctransfer -f -y -a $1 w2@$2 $ad1 $val3
    elif [[ $val_len == 6 ]]; then
        echo "i2ctransfer -f -y -a $1 w3@$2 $ad1 $val2 $val3"
        i2ctransfer -f -y -a $1 w3@$2 $ad1 $val2 $val3
    fi
elif [[ $ad_len == 6 ]]; then
    if [[ $val_len == 4 ]]; then
        echo "i2ctransfer -f -y -a $1 w3@$2 $ad0 $ad1 $val3"
        i2ctransfer -f -y -a $1 w3@$2 $ad0 $ad1 $val3
    elif [[ $val_len == 6 ]]; then
        echo "i2ctransfer -f -y -a $1 w4@$2 $ad0 $ad1 $val2 $val3"
        i2ctransfer -f -y -a $1 w4@$2 $ad0 $ad1 $val2 $val3
    elif [[ $val_len == 10 ]]; then
        echo "i2ctransfer -f -y -a $1 w6@$2 $ad0 $ad1 $val0 $val1 $val2 $val3"
        i2ctransfer -f -y -a $1 w6@$2 $ad0 $ad1 $val0 $val1 $val2 $val3
    fi
fi

if [[ -n $5 ]]; then
    sec=$(expr $5 / 1000)
    msec=$(expr $5 % 1000)
    #echo "sleep $sec.$msec"
    sleep $sec.$msec
fi

