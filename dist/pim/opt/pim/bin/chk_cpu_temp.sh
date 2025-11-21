#!/bin/bash

FLAG_PATH="/tmp"
tag=$(basename "$0")

CPU_TMP_VAL=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)
CPU_TEMP=$(echo "$CPU_TMP_VAL/1000" | bc)
timestamp=`date +"%Y-%m-%d %T,%3N"`
MAX_CPU_TEMP=85

if [ $(echo "$CPU_TEMP < $MAX_CPU_TEMP" | bc) -eq 1 ]
then
	exit 0
else
	echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_cpu_temp.log
    if [ $CPU_TEMP -ge 90 ]; then
        logger -p local0.error [CHK][$tag:$LINENO] CPU TEMP ERR : $CPU_TEMP
    else
        logger -p local0.info [CHK][$tag:$LINENO] CPU TEMP ERR : $CPU_TEM
    fi
	exit 1
fi

