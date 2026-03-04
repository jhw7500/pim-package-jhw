#!/bin/bash
FLAG_PATH="/tmp"
tag=$(basename "$0")
timestamp=$(date +"%Y-%m-%d %T,%3N")
volt_min=20.4
volt_max=27.6

volt_data=$(/opt/pim/bin/mcp_trust_test | grep voltage | cut -d':' -f2 | tr -d ' ')
is_over_min=$(echo "$volt_min < $volt_data" | bc)
if [ "$is_over_min" -eq 1 ]; then
	is_under_max=$(echo "$volt_max > $volt_data" | bc)
	if [ "$is_under_max" -eq 1 ] ; then
        	exit 0
	else
		logger -p local0.error "[CHK][${tag}:${LINENO}] Voltage High error : ${volt_data}"
		echo "${timestamp} VOLTAGE ERR" >> "${FLAG_PATH}/err_voltage.log"
        exit 1
	fi
else
logger -p local0.error "[CHK][${tag}:${LINENO}] Voltage Low error : ${volt_data}"
echo "${timestamp} VOLTAGE ERR" >> "${FLAG_PATH}/err_voltage.log"
	exit 1
fi
