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
    temp=$(cat /tmp/temp)
    if [ $CPU_TEMP -gt 90 ]; then
        if [ "$temp" != "$CPU_TEMP" ]; then
            logger -p local0.err [CHK][$tag:$LINENO] CPU TEMP ERR : $CPU_TEMP
        fi
    else
        if [ "$temp" != "$CPU_TEMP" ]; then
            logger -p local0.warn [CHK][$tag:$LINENO] CPU TEMP : $CPU_TEMP
        fi
    fi
    echo $CPU_TEMP > /tmp/temp
	exit 1
fi

