#!/bin/bash
_ping_dest=""
_true="true"
_false="false"
_result=$_false
_cmd=$(/sbin/hwclock -w)

fn_get_ping_dest() {
	_ping_dest=$(python3 /opt/cis/bin/getconfval.py PING_IP | tr -d '\r\n')
}

fn_ping() {
	_ping_result=$(ping -c 3 -W 3 $_ping_dest 2>/dev/null | grep transmitted | cut -d',' -f3)
	_success_value=" 0% packet loss"

	if [[ $_ping_result = *"$_success_value"* ]]; then
		_result=$_true
		echo "ping-check to $_ping_dest succeeded"
	else
		_result=$_false
		echo "ping-check to $_ping_dest failed"
	fi
}

fn_main() {
	local _timestamp=`date +"%Y-%m-%d %T,%3N"`
	echo $_timestamp

	fn_get_ping_dest
	fn_ping
	if [ $_result == $_true ]; then
		echo "RTC update succeeded"
		echo $_cmd 
	else
		echo "RTC update failed due to ping-check failure"
	fi
}

fn_main