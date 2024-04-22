#!/bin/bash

### BEGIN INIT INFO
# Provides: cis
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Start/Stop CIS
### END INIT INFO

start() {
    pid=`ps -ef | grep 'adab' | grep -v 'grep' | grep -v 'adab.' | grep -v '/usr/local/bin/adab' | awk '{print $2}'`    
    if [ -z $pid ]
    then
        /opt/cis/bin/adab > /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z `ps -ef | grep 'adab' | grep -v 'grep' | grep -v 'adab.' | grep -v '/usr/local/bin/adab' | awk '{print $2}'` ]
            then
                echo "RETRY"
            else
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "adab cannot be execute!"
        else
            echo "success"
        fi
    else
        echo "adab is already running"
    fi
}

stop() {
    pid=`ps -ef | grep 'adab' | grep -v 'grep' | grep -v 'adab.' | grep -v '/usr/local/bin/adab' | awk '{print $2}'`    
    if [ -z $pid ]
    then
        echo "adab is not running"
    else
        echo "quit" > /var/run/adab.pipe
        for ((i=0;i<3;i++)); do
            if [ -z `ps -ef | grep 'adab' | grep -v 'grep' | grep -v 'adab.' | grep -v '/usr/local/bin/adab' | awk '{print $2}'` ]
            then
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "adab cannot be closed normally."
        else
            echo "success"
        fi
    fi
}

log() {
    cat /var/log/cantops/local1.log-*_* 2> /dev/null
    cat /var/log/cantops/local1.log 2> /dev/null
}

logclear() {
    rm /var/log/cantops/local1.log* 2> /dev/null
}

reload() {
    echo "reload" > /var/run/adab.pipe
}

gyrocal() {
    STATE_FILE="/tmp/gyrocal_state"
    echo 2 > $STATE_FILE
    echo "gyrocal" > /var/run/adab.pipe

    while true; do
        sleep .2
        if [ $(<${STATE_FILE}) == "1" ]; then
            break;
        fi
    done
    
    while true; do
        sleep .2
        if [ $(<${STATE_FILE}) == "0" ]; then
            break;
        fi
    done
}

csv() {
    echo $1 $2 > /var/run/adab.pipe
}

case $1 in
    start|stop|reload|gyrocal|log|logclear) $1;;
    csv) csv $1 $2;;
    restart) stop; start;;
    *) echo "Run as $0 "; exit 1;;
esac
