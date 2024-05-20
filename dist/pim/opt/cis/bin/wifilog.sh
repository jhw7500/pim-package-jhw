#!/bin/bash
_root_path="/var/log/cantops"
_dev_wlan=$(python3 /opt/cis/bin/getconfval.py dev_wlan | tr -d '\r\n')
prevmac="none"

function LogWrite() {
	logger -p local1.info "WiFiLOG|$1"
}

function LogWrite_WiFiRegion() {
	local otp_dmesg=`dmesg | grep "Firmware OTP region"`
	local otp_code=`echo $otp_dmesg | cut -d':' -f3 | cut -d',' -f1 | tr -d ' '`
	local otp_region=""
	
	case $otp_code in
	10) otp_region="FCC";;
	20) otp_region="IC";;
	30) otp_region="ETSI";;
	31) otp_region="KCC";;
	32) otp_region="AU";;
	40) otp_region="JP";;
	50) otp_region="CN";;
	FF|ff) otp_region="WW";;
	*) otp_region="??";;
	esac
	
	LogWrite "Firmware OTP region code:${otp_code} ( ${otp_region} )"
	
	return 1
}

function LogWrite_WiFiParameters() {
	local siso_mode=""
	local ant_gain_adjust=""
	if [ -d "/sys/module/lrdmwl/parameters" ]; then 
		siso_mode=`cat /sys/module/lrdmwl/parameters/SISO_mode`
		ant_gain_adjust=`cat /sys/module/lrdmwl/parameters/ant_gain_adjust`
		LogWrite "SISO_mode=${siso_mode}, ant_gain_adjust=${ant_gain_adjust}"
		return 1
	fi;
	
	return 0
}

function LogWrite_WiFiChangeAP() {
    local str=`iw $_dev_wlan link`
    local mac=`echo $str | awk '/Connected to/{print $3}'`
    
    if [ -z $mac ]
    then
        mac="none"
        if [ $prevmac != $mac ]
        then
            LogWrite "disconnected"
            prevmac="none"
            return 0
        fi
    else
        ssid=`echo $str | awk '{print $7}'`
        dbm=`echo $str | awk '{print $21}'`
        txbr=`echo $str | awk '{print $25, $26, $27, $28, $29, $30, $31, $32, $33}'`
        if [ $prevmac != $mac ]
        then
            LogWrite "connect to ${ssid} ${mac} ${dbm} dBm ${txbr}"
            prevmac=$mac
            return 1
        fi
    fi
    
    return 0
}

function LogWrite_WiFiSignalPol() {
	local str=`wpa_cli -i $_dev_wlan signal_pol`
	local rssi=`echo $str | cut -d' ' -f1 | cut -d'=' -f2`
	local noise=`echo $str | cut -d' ' -f3 | cut -d'=' -f2`
	local snr
	
	if [ -n ${noise} ]; then
		noise=`echo $noise | tr -d '-'`
		snr=`expr $rssi + $noise`
		LogWrite "RSSI ${rssi} NOISE -${noise} SNR ${snr}"
		return 1
	fi

	return 0
}

function LogWrite_WiFiInfo() {
	local str=`iw $_dev_wlan info`
	local str_ch
	local str_tx
	local channel
	local txpower
	
	if [[ ${str} =~ "txpower" ]]; then
		if [[ ${str} =~ "channel" ]]; then
			str=`echo "${str#*channel }"`
			str_ch=`echo "${str%%txpower*}"`
			str_tx=`echo "${str#*txpower }"`
			
			channel=`echo $str_ch | awk '{print "channel " $1, $2, $3, $4, $5, $6, $7, $8, $9}'`
			txpower=`echo $str_tx | awk '{print "txpower " $1, $2}'`
			LogWrite "${txpower} ${channel}"
		else
			str_tx=`echo "${str#*txpower }"`
			txpower=`echo $str_tx | awk '{print "txpower " $1, $2}'`
			LogWrite "${txpower}"
		fi
		
		return 1
	fi
	
	return 0
}

sleep 0.5
while true; do
	WLAN0_FIND=$(iw dev | \grep -o "${_dev_wlan}")
	if [ "${WLAN0_FIND}" = "${_dev_wlan}" ]; then
		break;
	fi
    sleep 0.5
done

LogWrite_WiFiRegion;
wifi_region_flag_=$?

LogWrite_WiFiParameters;
wifi_parameter_flag_=$?;

while true; do
    LogWrite_WiFiChangeAP;
    if [ $? -eq 1 ]; then
        LogWrite_WiFiSignalPol;
        LogWrite_WiFiInfo;
    fi
    sleep 0.1
done
