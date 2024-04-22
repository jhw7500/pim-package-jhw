#!/bin/bash
_version="db monitor v0.0.1"
_root_path="/var/log/cantops"

_true="true"
_false="false"
_on=1
_off=0
_is_loop=1
_debuglvl=1
_infolvl=2
_errorlvl=3
_loglvl=$_infolvl


_dur_time=5
_result=$_false
_dback=""
_dbstarted=$_off

fn_mysleep() {
	local sleep_cnt=$1
	sleep_cnt=`echo "$sleep_cnt"|awk '{printf "%d", $1 + 0.5}'`
	for ((i=0;i<sleep_cnt;i++))
	do
		sleep 1
	done
}

fn_LogWrite() {
	if [ $1 -ge $_loglvl ]; then
		if [ $1 -eq $_errorlvl ]; then
			logger -p local1.error "DBMON|$2"
		elif [ $1 -eq $_infolvl ]; then
			logger -p local1.info "DBMON|$2"
		else
			logger -p local1.debug "DBMON|$2"
		fi
	fi
}

sigterm() {
	fn_LogWrite $_infolvl "stop (signal TERM)"
	exit 0
}

sigquit() {
	fn_LogWrite $_infolvl "stop (signal QUIT)"
	exit 0
}

sigint() {
	fn_LogWrite $_infolvl "stop (signal INT)"
	exit 0
}

fn_get_dbstatus() {
	_dback=`python3 /opt/cis/bin/dbuart.py "<SGS>"`
	if [ -z "$_dback" -o "$_dback" == " " ]; then
		_result=$_false
	else
		fn_LogWrite $_debuglvl "status $_dback"
		if [ `echo $_dback|cut -d',' -f1` == "[SGS" ];then
			dbstarted=`echo $_dback|cut -d',' -f3`
			if [ -z "$dbstarted" -o "$dbstarted" == " " ]; then
				_result=$_false
			else
				if [ "$dbstarted" == "1" ]; then
					_dbstarted=$_on
				else
					_dbstarted=$_off
				fi
				_result=$_true
			fi
		fi
	fi
}

fn_do_dbmon() {
	while [ $_is_loop -ne 0 ]
	do
		pid=`ps -ef | grep 'adab' | grep -v 'grep' | grep -v 'adab.' | grep -v '/usr/local/bin/adab' | awk '{print $2}'`
		if [ -z $pid ]; then
			fn_get_dbstatus
			if [ $_result == $_true ]; then
				if [ "$_dbstarted" == $_on ]; then
					dbstop=`python3 /opt/cis/bin/dbuart.py "<SFP>"`
					fn_LogWrite $_infolvl "db stop $dbstop"
				fi
			fi
		fi
		
		fn_mysleep $_dur_time
	done
}

fn_main() {
	fn_LogWrite $_infolvl "start"
	fn_do_dbmon
}

if [ -z "$_loglvl" -o "$_loglvl" == " " ]; then
	_loglvl=$_infolvl;
fi

trap 'sigquit' QUIT
trap 'sigint'  INT
trap 'sigterm'  TERM

fn_main

