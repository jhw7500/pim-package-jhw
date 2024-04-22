#!/bin/bash

### BEGIN INIT INFO
# Provides: cis
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: 
### END INIT INFO

_dev_wlan=$(python3 /opt/cis/bin/getconfval.py dev_wlan | tr -d '\r\n')
_daughterboard_type=$(python3 /opt/cis/bin/getconfval.py _daughterboard_type | tr -d '\r\n')

start() {
    /opt/cis/bin/automnt.sh start
    for var in {1..120}; do
        WLAN0_FIND=$(iw dev | \grep -o "${_dev_wlan}")
        if [ "${WLAN0_FIND}" = "${_dev_wlan}" ]; then
            break;
        fi
        sleep 0.5
    done
    WLAN0_FIND=$(iw dev | \grep -o "${_dev_wlan}")
    
    if [ -n "${WLAN0_FIND}" ] && [ "${WLAN0_FIND}" = "${_dev_wlan}" ]; then
        mkdir /var/run/sea
        python3 /opt/cis/bin/auto_fwupgrade.py > /dev/null 2> /dev/null
        python3 /opt/cis/bin/init.py power_on > /dev/null 2> /dev/null
        python3 /opt/cis/bin/update_network.py > /dev/null 2> /dev/null
        
        cism start
        wifim start
        if [ "${_daughterboard_type}" != "none" ]; then
            adab start > /dev/null 2> /dev/null
            dbmon start
        fi
        
        longrun service_start
    else
        reboot
    fi
}

stop() {
    fwdriver stop
    cism stop
    dbmon stop
    wifim stop
    longrun stop
    /opt/cis/bin/automnt.sh stop
}

case $1 in
        start|stop) $1;;
        restart) stop; start;;
        *) echo "Run as $0"; exit 1;;
esac