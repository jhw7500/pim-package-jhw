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
    pid=`ps -ef | grep 'db_monitor' | grep -v 'grep' | grep -v '/usr/local/bin/dbmon' | awk '{print $2}'`
    if [ -z "$pid" ]
    then
        /opt/cis/bin/db_monitor.sh 2> /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z "$(ps -ef | grep 'db_monitor' | grep -v 'grep' | grep -v '/usr/local/bin/dbmon' | awk '{print $2}')" ]
            then
                echo "RETRY" 
            else
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "db_monitor cannot be execute!"
        else
            echo "success"
        fi
    else
        echo "db_monitor is already running"
    fi
}

stop() {
    pid=`ps -ef | grep 'db_monitor' | grep -v 'grep' | grep -v '/usr/local/bin/dbmon' | awk '{print $2}'`
    if [ -z "$pid" ]
    then
        echo "db_monitor is not running"
    else
        kill $pid
        for ((i=0;i<3;i++)); do
            if [ -z "$(ps -ef | grep 'db_monitor' | grep -v 'grep' | grep -v '/usr/local/bin/dbmon' | awk '{print $2}')" ]
            then
                break
            fi
            sleep 1
        done
        if [ $i == 3 ]
        then
            echo "db_monitor cannot be closed normally."
        else
            echo "success"
        fi
    fi    
}

case $1 in
    start|stop) $1;;
    restart) stop; start;;
    *) echo "Run as $0 "; exit 1;;
esac
