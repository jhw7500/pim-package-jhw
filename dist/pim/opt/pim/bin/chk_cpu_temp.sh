#!/bin/bash

LOG_PATH="/opt/pim/bin/chk_log"
CPU_TMP_VAL=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)
CPU_TEMP=$(echo "$CPU_TMP_VAL/1000" | bc)
timestamp=`date +"%Y-%m-%d %T,%3N"`
MAX_CPU_TEMP=85


echo "CPU Temperature : "

if [ $(echo "$CPU_TEMP < $MAX_CPU_TEMP" | bc) -eq 1 ]
then
    echo "CPU TEMP : $CPU_TEMP℃ - Normal"
    exit 0
else
    echo "CPU TEMP : $CPU_TEMP℃ - Error"
	echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_cpu_temp.log
    exit 1
fi


    