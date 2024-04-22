#!/bin/bash

### BEGIN INIT INFO
# Provides: cis
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Start/Stop CISM
### END INIT INFO

start() {
    pid=`ps -ef | grep 'cism' | grep -v 'grep' | grep -v '/usr/local/bin/cism' | awk '{print $2}'`    
    if [ -z $pid ]
    then
        /opt/cis/bin/cism > /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z `ps -ef | grep 'cism' | grep -v 'grep' | grep -v '/usr/local/bin/cism' | awk '{print $2}'` ]
            then
                echo "RETRY" 
            else
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "cism cannot be execute!"
        else
            echo "success"
        fi
    else
        echo "cism is already running"
    fi
}

stop() {
    pid=`ps -ef | grep 'cism' | grep -v 'grep' | grep -v '/usr/local/bin/cism' | awk '{print $2}'`
    if [ -z $pid ]
    then
        echo "cism is not running"
    else
        echo "quit" > /var/run/cism.pipe
        for ((i=0;i<3;i++)); do
            if [ -z `ps -ef | grep 'cism' | grep -v 'grep' | grep -v '/usr/local/bin/cism' | awk '{print $2}'` ]
            then
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "cism cannot be closed normally."
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
