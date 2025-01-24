#!/bin/bash

### BEGIN INIT INFO
# Provides: cis
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Start/Stop CIS
### END INIT INFO

_longrun_en="0"

start() {
    pid=`ps -ef | grep 'longrunlog.sh' | grep -v 'grep' | grep -v '/usr/local/bin/longrun' | awk '{print $2}'`
    if [ -z $pid ]
    then
        /opt/cis/bin/longrunlog.sh > /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z "$(ps -ef | grep 'longrunlog.sh' | grep -v 'grep' | grep -v '/usr/local/bin/longrun' | awk '{print $2}')" ]
            then
                echo "RETRY" 
            else
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "longrun cannot be execute!"
        else
            echo "success"
        fi
    else
        echo "longrun is already running"
    fi
}

stop() {
    pid=`ps -ef | grep 'longrunlog.sh' | grep -v 'grep' | grep -v '/usr/local/bin/longrun' | awk '{print $2}'`    
    if [ -z $pid ]
    then
        echo "longrun is not running"
    else
        kill $pid
        for ((i=0;i<3;i++)); do
            if [ -z "$(ps -ef | grep 'longrunlog.sh' | grep -v 'grep' | grep -v '/usr/local/bin/longrun' | awk '{print $2}')" ]
            then
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "longrun cannot be closed normally."
        else
            echo "success"
        fi
    fi
}

log() {
    cat /shared/longrun.csv 2> /dev/null
}

logclear() {
    rm /shared/longrun.csv 2> /dev/null
}

read_en_longrun() {
    local val=$(python3 /opt/cis/bin/getconfval.py iot_longrun_en | tr -d '\r\n')
	if [ -z "$val" -o "$val" == " " -o "$val" == "" ]; then
		_longrun_en="0"
	elif [ "$val" == "True" ]; then
		_longrun_en="1"
	else
		_longrun_en="0"
	fi
}

service_start() {
    read_en_longrun
    if [ "$_longrun_en" == "1" ]; then
        start
    else
        echo "longrun not start"
    fi
}

case $1 in
    start|stop|log|logclear|service_start) $1;;
    restart) stop; start;;
    *) echo "Run as $0 "; exit 1;;
esac
