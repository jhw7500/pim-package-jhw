#!/bin/bash

start() {
    pid=`ps -ef | grep 'disco_react.py' | grep -v 'grep' | awk '{print $2}'`
    if [ -z "$pid" ]
    then
        python3 /opt/cis/bin/disco_react.py 1> /dev/null 2> /dev/null &
        for ((i=0;i<10;i++)); do
            if [ -z `ps -ef | grep 'disco_react.py' | grep -v 'grep' | awk '{print $2}'` ]
            then
                echo "RETRY" 
            else
                break
            fi
            sleep .1
        done
        if [ $i == 10 ]
        then
            echo "disco_react cannot be execute!"
        else
            echo "success"
        fi
    else
        echo "disco_react is already running"
    fi
}

stop() {
    pid=`ps -ef | grep 'disco_react.py' | grep -v 'grep' | awk '{print $2}'`
    if [ -z "$pid" ]
    then
        echo "disco_react is not running"
    else
        kill $pid
        for ((i=0;i<3;i++)); do
            if [ -z `ps -ef | grep 'disco_react.py' | grep -v 'grep' | awk '{print $2}'` ]
            then
                break
            fi
            sleep 1
        done
        if [ $i == 3 ]
        then
            echo "disco_react cannot be closed normally."
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