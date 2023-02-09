#!/bin/bash
_success_value=" 0% packet loss"
timestamp=`date +"%Y-%m-%d %T,%3N"`
result=1;

ETH1_PING=$(ping 199.10.100.123 -c 3 -W 3 -s 1000) 

if [[ $ETH1_PING != *"$_success_value"* ]]; then
	echo "${timestamp} ETH0 ERR" 
	ping 199.10.100.123 -c 3 -W 3 -s 1000 
	echo "   ETH0 fail"
	result=1;
else 
	echo "   ETH0 pass"
	result=0;
fi		

if [ $result -eq 1 ]
then
	exit 1
else
	exit 0
fi
