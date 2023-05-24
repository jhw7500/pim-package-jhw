#!/bin/bash

tag=$(basename "$0")

CPU_TEMP_MAX0=0
CPU_TEMP_MIN0=100
CPU_TEMP_MAX1=0
CPU_TEMP_MIN1=100

while :
do

CPU_TMP_VAL0=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)
CPU_TMP_VAL1=$(cat /sys/devices/virtual/thermal/thermal_zone1/temp)
CPU_TEMP0=$(echo "$CPU_TMP_VAL0/1000" | bc)
CPU_TEMP1=$(echo "$CPU_TMP_VAL1/1000" | bc)

logger -p local0.info "[CHK][$tag:$LINENO] CPU_TMP_VAL0:$CPU_TEMP_VAL0"
logger -p local0.info "[CHK][$tag:$LINENO] CPU_TMP_VAL1:$CPU_TEMP_VAL0"

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

sleep 60

done


exit 1
