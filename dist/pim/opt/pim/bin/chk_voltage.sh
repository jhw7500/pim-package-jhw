#!/bin/bash
FLAG_PATH="/opt/pim/bin/bg_chk_flag"
LOG_PATH="/var/log"
timestamp=`date +"%Y-%m-%d %T,%3N"`
volt_min=20.4
volt_max=27.6

function LogWrite() {
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	if [ $# -eq 1 ]; then
		echo "${timestamp} $1" >> "${LOG_PATH}/bg_chk.log"				
	fi
}

volt_data=$(/opt/pim/bin/mcp_trust_test | grep voltage | cut -d':' -f2| tr -d ' ')
if [ $(echo "$volt_min < $volt_data" | bc) -eq 1 ]; then
	if [ $(echo "$volt_max > $volt_data" | bc) -eq 1 ] ; then
        	exit 0
	else
		LogWrite "Voltage High error : $volt_data"
		echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_volt.log
        	exit 1
	fi
else
	LogWrite "Voltage Low error : $volt_data"
	echo "${timestamp} CPU TEMP ERR" >> ${FLAG_PATH}/err_volt.log
	exit 1
fi

