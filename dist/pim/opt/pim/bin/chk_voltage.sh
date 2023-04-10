#!/bin/bash
FLAG_PATH="/opt/pim/bin/bg_chk_flag"
tag=$(basename "$0")
timestamp=`date +"%Y-%m-%d %T,%3N"`
volt_min=20.4
volt_max=27.6

volt_data=$(/opt/pim/bin/mcp_trust_test | grep voltage | cut -d':' -f2| tr -d ' ')
if [ $(echo "$volt_min < $volt_data" | bc) -eq 1 ]; then
	if [ $(echo "$volt_max > $volt_data" | bc) -eq 1 ] ; then
        	exit 0
	else
		logger -p local0.priority -t $tag [CHK] Voltage High error : $volt_data
		echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_volt.log
        	exit 1
	fi
else
	logger -p local0.priority -t $tag [CHK] Voltage Low error : $volt_data
	echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_volt.log
	exit 1
fi

