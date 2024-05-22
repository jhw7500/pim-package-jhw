#!/bin/bash

_root_path="/var/log/cantops"
_mainboard_type=$(python3 /opt/cis/bin/getconfval.py mainboard_type | tr -d '\r\n')
_daughterboard_type=$(python3 /opt/cis/bin/getconfval.py daughterboard_type | tr -d '\r\n')

fn_LogWrite() {
    logger -p local1.info "$1"
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

run() {
    fn_LogWrite "===================================="
    fn_LogWrite "===================================="
    if [ "${_mainboard_type}" == "mini" ]; then
        fn_LogWrite "WDT_CHECK|run mode"

        en=$(fn_GETUARTMON)
        if [[ $en != '1' ]]; then
            fn_SETUARTMON 1
            fn_LogWrite "WDT_CHECK|DB UARTMON 1"
        fi
        /opt/cis/bin/wdt_check 70 10 0 &
    fi
}

shutdown() {
    if [ "${_mainboard_type}" == "mini" ]; then
        killall wdt_check
    fi

    sleep 0
    if [ "${_daughterboard_type}" != "none" ]; then
        en=$(fn_GETUARTMON)
        if [[ $en != '1' ]]; then
            fn_SETUARTMON 1
            fn_LogWrite "WDT_CHECK|DB UARTMON 1"
        fi
    fi

    if [ "${_mainboard_type}" == "mini" ]; then
        fn_LogWrite "WDT_CHECK|shutdown mode"
        /opt/cis/bin/wdt_check 120 240 0 &
    fi
    
    for var in {1..120}
    do
            fn_GETUARTMON
            if [[ $(systemctl is-active umount.target) != "inactive" ]]; then
                    exit 0
            fi
            sleep 1
    done
}

case $1 in
    run|shutdown) $1;;
    *) echo "Run as $0 "; exit 1;;
esac

exit 0