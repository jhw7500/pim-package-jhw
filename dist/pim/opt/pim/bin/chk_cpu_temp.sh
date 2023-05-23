#!/bin/bash

FLAG_PATH="/tmp"
tag=$(basename "$0")

CPU_TMP_VAL0=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)
CPU_TMP_VAL1=$(cat /sys/devices/virtual/thermal/thermal_zone1/temp)
CPU_TEMP0=$(echo "$CPU_TMP_VAL0/1000" | bc)
CPU_TEMP1=$(echo "$CPU_TMP_VAL1/1000" | bc)
timestamp=`date +"%Y-%m-%d %T,%3N"`
CPU_TEMP_LIMIT=85
CPU_TEMP_MAX0=0
CPU_TEMP_MIN0=100
CPU_TEMP_MAX1=0
CPU_TEMP_MIN1=100

if [ $(echo "$CPU_TEMP0 < $CPU_TEMP_LIMIT" | bc) -eq 1 ]
then
	#exit 0
    echo ok > /dev/null
else
	logger -p local0.error "[CHK][$tag:$LINENO] CPU TEMP0 ERR : $CPU_TEMP0"
	echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_cpu_temp.log
	#exit 1
fi

if [ $(echo "$CPU_TEMP1 < $CPU_TEMP_LIMIT" | bc) -eq 1 ]
then
    echo ok > /dev/null
    #exit 0
else
    logger -p local0.error "[CHK][$tag:$LINENO] CPU TEMP1 ERR : $CPU_TEMP1"
    #echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_cpu_temp.log
    #exit 1
fi


if [ "$CPU_TEMP0" -gt "$CPU_TEMP_MAX0" ]; then
    CPU_TEMP_MAX0=$((CPU_TEMP0))
    logger -p local0.notice "[CHK][$tag:$LINENO] CPU_TEMP_MAX0:$CPU_TEMP_MAX0"
fi

if [ "$CPU_TEMP0" -lt "$CPU_TEMP_MIN0" ]; then
    CPU_TEMP_MIN0=$((CPU_TEMP0))
    logger -p local0.notice "[CHK][$tag:$LINENO] CPU_TEMP_MIN0:$CPU_TEMP_MIN0"
fi


if [ "$CPU_TEMP1" -gt "$CPU_TEMP_MAX1" ]; then
    CPU_TEMP_MAX1=$((CPU_TEMP1))
    logger -p local0.notice "[CHK][$tag:$LINENO] CPU_TEMP_MAX1:$CPU_TEMP_MAX1"
fi

if [ "$CPU_TEMP1" -lt "$CPU_TEMP_MIN1" ]; then
    CPU_TEMP_MIN1=$((CPU_TEMP1))
    logger -p local0.notice "[CHK][$tag:$LINENO] CPU_TEMP_MIN1:$CPU_TEMP_MIN1"
fi

exit 1
