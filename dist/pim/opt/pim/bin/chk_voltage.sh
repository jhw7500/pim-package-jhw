#!/bin/bash
LOG_PATH="/opt/pim/bin/chk_log"
volt_min=20.4
volt_max=27.6

volt_data=$(/opt/pim/bin/mcp_trust_test | grep voltage | cut -d':' -f2| tr -d ' ')
if [ $(echo "$volt_min < $volt_data" | bc) -eq 1 ]; then
	if [ $(echo "$volt_max > $volt_data" | bc) -eq 1 ] ; then
		echo "Voltage Normal : $volt_data"
        exit 0
	else
		echo "Voltage High error : $volt_data"
        touch ${FLAG_PATH}/err_volt.log
        exit 1
	fi
else
	echo "Voltage Low error : $volt_data"
    touch ${FLAG_PATH}/err_volt.log
    exit 1
fi