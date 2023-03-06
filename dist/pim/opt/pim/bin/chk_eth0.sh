#!/bin/bash
FLAG_PATH="/opt/pim/bin/bg_chk_flag"
LOG_PATH="/var/log"
_success_value=" 0% packet loss"
timestamp=`date +"%Y-%m-%d %T,%3N"`
result=1;

ETH0_PING=$(ping 199.10.100.20 -c 3 -W 3 -s 1000)

function LogWrite() {
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	if [ $# -eq 1 ]; then
		echo "${timestamp} $1" >> "${LOG_PATH}/bg_chk.log"				
	fi
}

if [[ $ETH0_PING != *"$_success_value"* ]]; then
	LogWrite "ETH0 ping error" 	
	echo "${timestamp} ETH0 ERR" >> ${FLAG_PATH}/err_eth0.log	
	result=1;
else 
	result=0;
fi		

if [ $result -eq 1 ]
then
	exit 1	
else
	exit 0
fi
