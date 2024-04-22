#!/bin/bash

### BEGIN INIT INFO
# Provides: cis
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Start/Stop CIS
### END INIT INFO

fn_LogWrite() {
    logger -p local1.info "$1"
}

start() {
    pid=`ps -ef | grep 'wifilog' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'`
    if [ -z $pid ]
    then
        /opt/cis/bin/wifilog.sh 2> /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z `ps -ef | grep 'wifilog' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'` ]
            then
                echo "RETRY" 
            else
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "wifilog cannot be execute!"
        else
            fn_LogWrite "WiFiLOG|start"
            echo "success"
        fi
    else
        echo "wifilog is already running"
    fi

    pid=`ps -ef | grep 'wifi_checker' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'`
    if [ -z $pid ]
    then
        /opt/cis/bin/wifi_checker.sh 2> /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z `ps -ef | grep 'wifi_checker' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'` ]
            then
                echo "RETRY" 
            else
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "wifi_checker cannot be execute!"
        else
            fn_LogWrite "WiFiCHK|start"
            echo "success"
        fi
    else
        echo "wifi_checker is already running"
    fi
}

stop() {
    pid=`ps -ef | grep 'wifilog' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'`
    if [ -z $pid ]
    then
        echo "wifilog is not running"
    else
        kill $pid
        fn_LogWrite "WiFiLOG|stop"
        for ((i=0;i<3;i++)); do
            if [ -z `ps -ef | grep 'wifilog' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'` ]
            then
                break
            fi
            sleep .1
        done
        if [ $i == 3 ]
        then
            echo "wifilog cannot be closed normally."
        else
            echo "success"
        fi
    fi

    pid=`ps -ef | grep 'wifi_checker' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'`
    if [ -z $pid ]
    then
        echo "wifi_checker is not running"
    else
        kill $pid
        fn_LogWrite "WiFiCHK|stop"
        for ((i=0;i<3;i++)); do
            if [ -z `ps -ef | grep 'wifi_checker' | grep -v 'grep' | grep -v '/usr/local/bin/wifim' | awk '{print $2}'` ]
            then
                break
            fi
            sleep 1
        done
        if [ $i == 3 ]
        then
            echo "wifi_checker cannot be closed normally."
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
