#!/bin/bash
LOG_PATH="/opt/pim/bin/chk_log"
_success_value=" 0% packet loss"
timestamp=`date +"%Y-%m-%d %T,%3N"`
result=1;

ETH0_PING=$(ping 199.10.100.20 -c 3 -W 3 -s 1000)

if [[ $ETH0_PING != *"$_success_value"* ]]; then
	echo "${timestamp} ETH0 ERR" 	
	result=1;
else 
	echo "ETH0 pass"
	result=0;
fi		

if [ $result -eq 1 ]
then
	exit 1
	touch ${FLAG_PATH}/err_eth0.log
else
	exit 0
fi