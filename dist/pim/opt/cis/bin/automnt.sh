#!/bin/bash

### BEGIN INIT INFO
# Provides: cis
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Start/Stop CIS
### END INIT INFO

_root_path="/var/log/cantops"

fn_LogWrite() {
    logger -p local1.info "AUTOMNT|$1"
}

start() {
    pid=`ps -ef | grep 'automnt_sd' | grep -v 'grep' | grep -v '/usr/local/bin/automnt' | awk '{print $2}'`
    if [ -z $pid ]
    then
        /opt/cis/bin/automnt_sd 2> /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z `ps -ef | grep 'automnt_sd' | grep -v 'grep' | grep -v '/usr/local/bin/automnt' | awk '{print $2}'` ]
            then
                echo "RETRY"
            else
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "automnt cannot be execute!"
        else
            echo "success"
        fi
    else
        echo "automnt is already running"
    fi
}

stop() {
    pid=`ps -ef | grep 'automnt_sd' | grep -v 'grep' | grep -v '/usr/local/bin/automnt' | awk '{print $2}'`
    if [ -z $pid ]
    then
        echo "automnt is not running"
    else
        kill $pid
        for ((i=0;i<3;i++)); do
            if [ -z `ps -ef | grep 'automnt_sd' | grep -v 'grep' | grep -v '/usr/local/bin/automnt' | awk '{print $2}'` ]
            then
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "automnt cannot be closed normally."
        else
            echo "success"
        fi
    fi

    mout_dev=`df | grep '/mnt/sd\b' | awk '{print $1}'`
    if [ ! -z "$mout_dev" ]; then
        umount /mnt/sd > /dev/null 2>&1
        fn_LogWrite "INFO|AUTOMNT|umount /mnt/sd"
    fi
}



case $1 in
    start|stop|log) $1;;
    restart) stop; start;;
    *) echo "Run as $0 "; exit 1;;
esac