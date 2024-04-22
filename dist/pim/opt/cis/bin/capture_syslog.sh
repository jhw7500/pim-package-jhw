#!/bin/bash

_timestamp=`date +"%Y%m%d-%H%M%S"`
_root_path="/var/log/cantops/backup_syslog"
_full_path="$_root_path/syslog-$_timestamp.txt"
_cnt=0

function LogWrite() {
	echo "$1" >> "${_full_path}"
}

fn_log_d_lsof() {
	ps -eo stat,comm,pid,wchan:32 | grep ^[D] | while read line;
	do
	if [ $_cnt -ge 1 ]; then
		local pid=`echo $line | cut -d' ' -f3`
		if [[ -n ${pid} ]]; then
			LogWrite "$line"
			LogWrite ""
			LogWrite "# lsof -p $pid"
			lsof -p $pid >> "${_full_path}"
			LogWrite ""
		fi
	fi
	_cnt=`expr $_cnt + 1`
	done
}

logger -p local1.info "capture_syslog|start file=${_full_path}"

mkdir -p $_root_path

##default: MAX 10 MB
python3 /opt/cis/bin/delete_oldfile.py $_root_path

LogWrite "===================================="
LogWrite " system log $_timestamp"
LogWrite "===================================="
LogWrite "### cat /proc/meminfo"
cat /proc/meminfo >> "${_full_path}"
LogWrite ""

LogWrite "### df"
df >> "${_full_path}"
LogWrite ""

LogWrite "### ip a"
ip a >> "${_full_path}"
LogWrite ""

LogWrite "### top -b -n1"
top -b -n1 >> "${_full_path}"
LogWrite ""

LogWrite "### ps -ef"
ps -ef >> "${_full_path}"
LogWrite ""

LogWrite "#### ps -eo stat,comm,pid,wchan:32 | grep ^[D]"
fn_log_d_lsof
LogWrite ""

LogWrite "### journalctl --no-pager --since ""2 hour ago"""
echo w > /proc/sysrq-trigger
journalctl --no-pager --since "2 hour ago" >> "${_full_path}"
LogWrite ""
logger -p local1.info "capture_syslog|end"
sync
