#!/bin/bash

function GET_RTC() {
    RTC_CUR_TIME=`hwclock -r`
    rtime=`date --date  "$RTC_CUR_TIME" +"%Y-%m-%d %T"`    
    rtime=`echo $rtime | tr '-' '/' | tr ' ' '/' | tr ':' '/'`
    echo "DATA:$rtime"
}

function SET_RTC() {
    if [ -z $1 ]; then
        echo "ERROR:bad param"
		exit 1
    else
        stime=$1
		if [[ "$stime" =~ "/" ]]; then
			t1=`echo $stime | cut -d '/' -f1`
			t2=`echo $stime | cut -d '/' -f2`
			t3=`echo $stime | cut -d '/' -f3`
			t4=`echo $stime | cut -d '/' -f4`
			t5=`echo $stime | cut -d '/' -f5`
			t6=`echo $stime | cut -d '/' -f6`
			if [ -z $t6 ]; then
				echo "ERROR:bad param"
				exit 1
			else
				local ntp_en=$(systemctl is-active systemd-timesyncd.service | tr -d '\r\n')
				if [ $ntp_en == "active" ]; then
					timedatectl set-ntp 0
					echo "timedatectl set-ntp 0"
				fi

				date -s "$t1-$t2-$t3 $t4:$t5:$t6" > /dev/null
				hwclock -w
				RTC_CUR_TIME=`hwclock -r`
				rtime=`date --date  "$RTC_CUR_TIME" +"%Y-%m-%d %T"`
				rtime=`echo $rtime | tr '-' '/' | tr ' ' '/' | tr ':' '/'`
				if [ $ntp_en == "active" ]; then
					timedatectl set-ntp 1
					echo "timedatectl set-ntp 1"
				fi

				echo "DATA:$rtime"
			fi
		else
			echo "ERROR:bad param"
			exit 1
		fi
    fi
}

case $1 in
    GET_RTC ) $1 ;;
    SET_RTC ) $1 $2 ;;
    *) echo "ERROR:Bad Command"; exit 1;;
esac