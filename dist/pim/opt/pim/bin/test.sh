#!/bin/bash

FLAG_PATH=/tmp
function MAKE_RESULT_FLAG() {
    result=0
    if [[ -e ${FLAG_PATH}/err_cam0.log ]]; then
        result=$(echo "$result + 1" | bc)
        #echo "bg_chk_flag : $result"
    fi
    if [[ -e ${FLAG_PATH}/err_cam1.log ]]; then
        result=$(echo "$result + 2" | bc)
        #echo "bg_chk_flag : $result"
    fi
    if [[ -e ${FLAG_PATH}/err_cam2.log ]]; then
        result=$(echo "$result + 4" | bc)
        #echo "bg_chk_flag : $result"
    fi
    if [[ -e ${FLAG_PATH}/err_cam3.log ]]; then
        result=$(echo "$result + 8" | bc)
        #echo "bg_chk_flag : $result"
    fi
    if [[ -e ${FLAG_PATH}/err_wifi.log ]]; then
        result=$(echo "$result + 16" | bc)
        #echo "bg_chk_flag : $result"
    fi
    if [[ -e ${FLAG_PATH}/err_sdcard.log ]]; then
        result=$(echo "$result + 32" | bc)
        #echo "bg_chk_flag : $result"
    fi
    if [[ -e ${FLAG_PATH}/err_cpu_temp.log ]]; then
        result=$(echo "$result + 64" | bc)
        #echo "bg_chk_flag : $result"
    fi
    if [[ -e ${FLAG_PATH}/err_voltage.log ]]; then
        result=$(echo "$result + 128" | bc)
        #echo "bg_chk_flag : $result"
    fi
    #echo "$result" >> ${FLAG_PATH}/bg_chk_flag.bin

    printf "%d" $result > ${FLAG_PATH}/bg_chk_flag.bin
}

MAKE_RESULT_FLAG
value=$(cat $FLAG_PATH/bg_chk_flag.bin)
lower=$((value&0xf))
echo $lower
