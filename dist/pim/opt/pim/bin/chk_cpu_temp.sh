#!/bin/bash

FLAG_PATH="/opt/pim/bin/bg_chk_flag"
tag=$(basename "$0")

CPU_TMP_VAL=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)
CPU_TEMP=$(echo "$CPU_TMP_VAL/1000" | bc)
timestamp=`date +"%Y-%m-%d %T,%3N"`
MAX_CPU_TEMP=85

if [ $(echo "$CPU_TEMP < $MAX_CPU_TEMP" | bc) -eq 1 ]
then
	exit 0
else
	logger -p local0.error -t $tag [CHK] CPU TEMP ERR : $CPU_TEMP 
	echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_cpu_temp.log
	exit 1
fi

