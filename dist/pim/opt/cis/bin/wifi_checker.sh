#!/bin/bash
_version="wifi checker v0.0.1"
_reboot_cnt_file="/mnt/sd/data/rebootcount.conf"
_TAG="WiFiCHK"
_root_path="/var/log/cantops"
_dev_wlan=$(python3 /opt/cis/bin/getconfval.py dev_wlan | tr -d '\r\n')
_cur_date_=""
_log_path_=""

_n1_max=3
_n2_max=2
_n3_max=2

_true="true"
_false="false"
_on=1
_off=0
_is_loop=1
_n1_cnt=0
_n2_cnt=0
_n3_cnt=0
_debuglvl=1
_infolvl=2
_errorlvl=3
_loglvl=$_infolvl

_result=$_false
_reboot_cnt=0
_n1_cnt=0
_n2_cnt=0
_n3_cnt=0
_ping_fail_cnt=0
_ping_dest=""
_wlan_used=$_true
_debug=1

_dur_time=180
_time_cnt=0
_start_time=""
_next_time=""

_reboot_fail=$_false
_d_systemd_cnt=0
_d_systemd_max=20
_d_chk_result=$_false
_ro_flag=$_false

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
			logger -p local1.error "WiFiCHK|$2"
		elif [ $1 -eq $_infolvl ]; then
			logger -p local1.info "WiFiCHK|$2"
		else
			logger -p local1.debug "WiFiCHK|$2"
		fi
	fi
}

sigterm() {
	fn_LogWrite $_debuglvl "end (signal TERM)"
	exit 0
}

sigquit() {
	fn_LogWrite $_debuglvl "end (signal QUIT)"
	exit 0
}

sigint() {
	fn_LogWrite $_debuglvl "end (signal INT)"
	exit 0
}

fn_reboot_cnt_clear() {
	local _is_mount=$(mount | grep '/mnt/sd\b')
	_reboot_cnt=0

	if [ -z "$_is_mount" -o "$_is_mount" == " " -o "$_is_mount" == "" ]; then
		_reboot_cnt=0
	else
		echo $_reboot_cnt > $_reboot_cnt_file
	fi

	fn_LogWrite $_debuglvl "reboot_cnt=$_reboot_cnt"
}

fn_reboot_cnt_inc() {
	local _is_mount=$(mount | grep '/mnt/sd\b')
	if [ -z "$_is_mount" -o "$_is_mount" == " " -o "$_is_mount" == "" ]; then
		_reboot_cnt=0
	else
		_reboot_cnt=$(cat $_reboot_cnt_file 2>/dev/null | tr -d '\r\n')
		if ! [[ $_reboot_cnt =~ ^-?[0-9]+$ ]]; then
			_reboot_cnt=0
		fi
		_reboot_cnt=`expr $_reboot_cnt + 1`
		echo $_reboot_cnt > $_reboot_cnt_file
	fi
	fn_LogWrite $_debuglvl "reboot_cnt=$_reboot_cnt"
}

fn_n1_cnt_clear() {
	_n1_cnt=0
}

fn_n1_cnt_inc() {
	_n1_cnt=`expr $_n1_cnt + 1`
}

fn_n2_cnt_clear() {
	_n2_cnt=0
}

fn_n2_cnt_inc() {
	_n2_cnt=`expr $_n2_cnt + 1`
}

fn_n3_cnt_clear() {
	_n3_cnt=0
}

fn_n3_cnt_inc() {
	_n3_cnt=`expr $_n3_cnt + 1`
}

fn_wifiscan() {
	iw $_dev_wlan scan > /dev/null 2> /dev/null
	fn_LogWrite $_infolvl "Done wifi_scan"
}

fn_network_update() {
	python3 /opt/cis/bin/update_network.py --force
	fn_LogWrite $_infolvl "Done network update"
}

fn_reboot() {
	reboot
	_reboot_fail=$_true
}

fn_force_reboot() {
	echo 1 > /proc/sys/kernel/sysrq
	echo b > /proc/sysrq-trigger
}

fn_check_systemd() {
	ps -eo stat,comm,pid,wchan:32 | grep 'systemd ' | grep "^D" | while read line;
	do
	local pid=`echo $line | cut -d' ' -f3`
	if [[ ${pid} == "1" ]]; then
		echo $line
		break;
	fi
	done
}

fn_check_d_state() {
	local val=$(fn_check_systemd)
	if [[ -n $val ]]; then
		_d_systemd_cnt=`expr $_d_systemd_cnt + 1`
		fn_LogWrite $_infolvl "systemd is D state : $_d_systemd_cnt"
		if [ $_d_systemd_cnt -ge $_d_systemd_max ]; then
			_d_chk_result=$_true
			_d_systemd_cnt=0
		fi
	else
		_d_systemd_cnt=0
	fi
}

fn_check_read_only() {
    local ro=$(grep ' / ' /proc/mounts | grep ' ro,' | wc -l)
    if [ ${ro} -gt 0 ]; then
        _ro_flag=$_true
    else
        _ro_flag=$_false
    fi
}

fn_ping() {
	_ping_result=$(ping -c 3 -W 3 $_ping_dest 2>/dev/null | grep transmitted | cut -d',' -f3)
	_success_value=" 0% packet loss"

	if [[ $_ping_result = *"$_success_value"* ]]; then
		_result=$_true
		_ping_fail_cnt=0
		fn_LogWrite $_debuglvl "ping [$_ping_dest] ok"
	else
		_result=$_false
		_ping_fail_cnt=`expr $_ping_fail_cnt + 1`
		fn_LogWrite $_infolvl "ping [$_ping_dest] packet loss $_ping_fail_cnt"
	fi
}

fn_get_ping_dest() {
	_ping_dest=$(python3 /opt/cis/bin/getconfval.py PING_IP | tr -d '\r\n')
}

fn_get_wlan_used() {
	local val=$(python3 /opt/cis/bin/getconfval.py NETWORK_USED | tr -d '\r\n')
	if [ -z "$val" -o "$val" == " " -o "$val" == "" ]; then
		_wlan_used=$_false
	elif [ "$val" == "WLAN0" ]; then
		_wlan_used=$_true
	else
		_wlan_used=$_false
	fi
}

fn_do_wifi_check() {
	fn_n1_cnt_clear
	fn_n2_cnt_clear
	fn_n3_cnt_clear
	
	_start_time=$(date +%s.%3N)
	_next_time=`echo "$_start_time $_dur_time"|awk '{printf "%.3f", ($1 + $2)}'`

	while [ $_is_loop -ne 0 ]
	do
		fn_mysleep 1
		
		_time_cnt=`expr $_time_cnt + 1`
		if [ ${_time_cnt} -ge ${_dur_time} ]; then
			_time_cnt=0
			fn_get_wlan_used
			if [ $_wlan_used == $_true ]; then
				fn_get_ping_dest
				fn_ping
				if [ $_result == $_false ]; then
					fn_n1_cnt_inc
					if [ $_n1_cnt -ge $_n1_max ]; then
						fn_n1_cnt_clear
						fn_n2_cnt_inc
						if [ $_n2_cnt -ge $_n2_max ]; then
							fn_n1_cnt_clear
							fn_n2_cnt_clear
							fn_n3_cnt_inc
							if [ $_n3_cnt -ge $_n3_max ]; then
								fn_LogWrite $_infolvl "ping fail, reboot()"
								fn_reboot
								fn_n1_cnt_clear
								fn_n2_cnt_clear
								fn_n3_cnt_clear
							fi

							if [ $_reboot_fail == $_false ]; then
								fn_network_update
							fi
						fi

						if [ $_reboot_fail == $_false ]; then
							fn_wifiscan
						fi
					fi
				else
					fn_n1_cnt_clear
					fn_n2_cnt_clear
					fn_n3_cnt_clear
				fi
			else
				fn_LogWrite $_debuglvl "ping skip"		#for test
				fn_n1_cnt_clear
				fn_n2_cnt_clear
				fn_n3_cnt_clear
			fi

			fn_check_d_state
			if [ $_d_chk_result == $_true ]; then
				fn_LogWrite $_infolvl "systemd is D state for 1 hour, reboot()"
				fn_reboot
			fi

			if [ $_reboot_fail == $_true ]; then
				fn_LogWrite $_errorlvl "reboot fail, force reboot()"
				timeout -s 9 60s /opt/cis/bin/capture_syslog.sh
				sleep 1
				fn_force_reboot
			fi
		fi

		fn_check_read_only
		if [ $_ro_flag == $_true ]; then
			fn_LogWrite $_errorlvl "rootfs read only, change emergency mode"
			systemctl emergency
			fn_LogWrite $_errorlvl "change emergency fail, force reboot()"
			sleep 1
			fn_force_reboot
		fi
	done
}

fn_boot_up_ping_check() {
	for var in {1..15}
	do
		sleep 1
	done
	fn_get_ping_dest
	fn_ping
}

fn_main() {
	#fn_boot_up_ping_check
	fn_do_wifi_check
}

if [ -z "$_loglvl" -o "$_loglvl" == " " ]; then
	_loglvl=$_infolvl;
fi

trap 'sigquit' QUIT
trap 'sigint'  INT
trap 'sigterm'  TERM

fn_main

