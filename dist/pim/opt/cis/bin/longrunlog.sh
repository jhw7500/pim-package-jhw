#!/bin/bash
_root_path="/shared/longrun.csv"

_start_time=$(date +%s)
_next_time=""
_sleep_time=""
_cpu_load="0"
_ram_load="0"
_cpu_temp="0"
_soc_temp="0"
_adab_err="0,0,0,0"
_wifilink="0"
_linked_mac="NONE"

_dev_wlan=$(python3 /opt/cis/bin/getconfval.py dev_wlan | tr -d '\r\n')

function LogWrite() {
	local timestamp=`date +"%Y-%m-%d %T.%3N"`
    #echo "${timestamp}|$1" 
	echo "${timestamp},$1" >> "${_root_path}"
}

function round()
{
    echo $(printf %.0f $(echo "scale=0;(($1)+0.5)" | bc))
}

function HeaderWrite() {
    echo "time,cpu_load_core,cpu_load_avr,ram_load,cpu_temp,soc_temp,adab_err,time_err,adc_err,gyro_err,wifilink,linked_mac" >> "${_root_path}"
}

function DataWrite() {	#unused
    local cur_time=$(date +%s)
    local tt=$(($cur_time - $_start_time))
    echo "$tt,$_cpu_load,$_ram_load,$_cpu_temp,$_soc_temp,$_adab_err,$_wifilink,$_linked_mac" >> "${_root_path}"
}

function GetCpuLoad() {
	all_laod=""
	cpu_load=""
	mpstat -P ALL 1 1 | while read line;
	do
		if [[ -n $(echo $line | grep "Average:") ]]; then
			tag=$(echo $line | cut -d' ' -f2)
			case $tag in
			"all")
				load=$(echo $line | awk '{print 100-$NF}')
				all_laod=$(round $load)
				;;
			"0"|"1"|"2")
				load=$(echo $line | awk '{print 100-$NF}')
				load=$(round $load)
				cpu_load=$(echo $cpu_load$load/)
				;;
			"3")
				load=$(echo $line | awk '{print 100-$NF}')
				load=$(round $load)
				cpu_load=$(echo $cpu_load$load,$all_laod)
				echo $cpu_load
				;;
			esac
		fi
	done
}

function GetRamLoad() {
    local mem_tot=`cat /proc/meminfo | grep ^MemTotal| grep -Po '[0-9.]+ kB' | awk '{print $1}'`
    local mem_avail=`cat /proc/meminfo | grep ^MemAvailable | grep -Po '[0-9.]+ kB' | awk '{print $1}'`
    _ram_load=`echo "$mem_tot $mem_avail"|awk '{printf "%.1f", ($1 - $2)/$1*100}'`
}

function GetCpuTemp() {
    _cpu_temp=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp | awk '{print $NF/1000}')
    if [ -f '/sys/devices/virtual/thermal/thermal_zone1/temp' ]; then
        _soc_temp=$(cat /sys/devices/virtual/thermal/thermal_zone1/temp | awk '{print $NF/1000}')
    else
        _soc_temp="0"
    fi
}

function GetAdabError() {
	if [ ! -f "/dev/shm/adab_status" ]; then
		_adab_err="0,0,0,0"
	else
		local error=""
		local time_error=""
		local adc_error=""
		local gyro_error=""
		
		error=`cat /dev/shm/adab_status | grep ERROR | cut -d':' -f2 | tr -d '\r\n'`
		time_error=`cat /dev/shm/adab_status | grep data_time_err | cut -d':' -f2 | tr -d '\r\n'`
		adc_error=`cat /dev/shm/adab_status | grep data_adc_err | cut -d':' -f2 | tr -d '\r\n'`
		gyro_error=`cat /dev/shm/adab_status | grep data_gyro_err | cut -d':' -f2 | tr -d '\r\n'`
		
		_adab_err="$error,$time_error,$adc_error,$gyro_error"
	fi
}

function GetWifiLink() {
    local macval=`iw $_dev_wlan link 2> /dev/null | head -1 | awk '/Connected to/{print $3}'`
    if [ -z "$macval" -o "$macval" == " " -o "$macval" == "" ]; then
        _wifilink="0"
        _linked_mac="NONE"
    else
        _wifilink="1"
        _linked_mac=$macval
    fi
}

sleep 0.5
while true; do
    WLAN0_FIND=$(iw dev | \grep -o "${_dev_wlan}")
    if [ "$WLAN0_FIND" = "${_dev_wlan}" ]; then
       break;
    fi
    sleep 0.5
done

LogWrite "START_LONGRUNLOG"
_start_time=$(date +%s)

HeaderWrite
while true; do
    _cpu_load=$(GetCpuLoad)
    GetRamLoad
    GetCpuTemp
    GetAdabError
    GetWifiLink
    LogWrite "$_cpu_load,$_ram_load,$_cpu_temp,$_soc_temp,$_adab_err,$_wifilink,$_linked_mac"
    sleep 0
done
