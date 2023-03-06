#!/bin/bash

FLAG_PATH="/opt/pim/bin/bg_chk_flag"
LOG_PATH="/var/log"
CPU_TMP_VAL=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)
CPU_TEMP=$(echo "$CPU_TMP_VAL/1000" | bc)
timestamp=`date +"%Y-%m-%d %T,%3N"`
MAX_CPU_TEMP=85

function LogWrite() {
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	if [ $# -eq 1 ]; then
		echo "${timestamp} $1" >> "${LOG_PATH}/bg_chk.log"						
	fi
}

if [ $(echo "$CPU_TEMP < $MAX_CPU_TEMP" | bc) -eq 1 ]
then
	exit 0
else
	LogWrite  "CPU TEMP error : $CPU_TEMP degree"
	echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_cpu_temp.log
	exit 1
fi

