#!/bin/bash

_root_path="/var/log/cantops"
_true=1
_false=0
_ro_flag=$_false
_uartmon='0'
_mainboard_type=$(python3 /opt/cis/bin/getconfval.py mainboard_type | tr -d '\r\n')

fn_LogWrite() {
    local timestamp=`date +"%Y-%m-%d %T.%3N"`
    echo "${timestamp}|$1" >> "/tmp/my_emg_log"
}

fn_GETUARTMON() {
    str=`/usr/local/bin/dbuart '<GETUARTMON>' | grep 'GETUARTMON'`
    if [ -z $str ]; then
        return
    else
        echo $str | tr -d '[]' | cut -d',' -f3 | tr -d ' '
    fi
}

fn_SETUARTMON() {
    if [ ! -z "$1" ] ;then
        /usr/local/bin/dbuart "<SETUARTMON,$1>" > /dev/null 2>&1
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

fn_LogWrite "INFO| EMERGENCY|enter emergency mode"

if [ "${_mainboard_type}" == "mini" ]; then
    killall wdt_check > /dev/null 2>&1
fi

sleep 0
_uartmon=$(fn_GETUARTMON)
if [[ $_uartmon != '0' ]]; then
    fn_SETUARTMON 0
fi

if [ "${_mainboard_type}" == "mini" ]; then
    /opt/cis/bin/wdt_check 120 240 0 > /dev/null 2>&1 &
fi

fn_check_read_only
if [ $_ro_flag != $_true ]; then
    mount -o remount,ro /dev/mmcblk2p2
else
    fn_LogWrite "INFO| EMERGENCY|rootfs read only mode"
fi

e2fsck -pf /dev/mmcblk2p2 > /dev/null 2>&1
mount -o remount,rw /dev/mmcblk2p2

fn_LogWrite "INFO| EMERGENCY|done e2fsck rootfs"

#cp /etc/backup_fstab /etc/fstab

fn_SETUARTMON 1

fn_LogWrite "INFO| EMERGENCY|reboot"

cat /tmp/my_emg_log >> "${_root_path}/local1.log"
sync
reboot