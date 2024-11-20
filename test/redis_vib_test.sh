#!/bin/bash
while true; do
    if (( RANDOM % 10 < 1 )); then
        #echo "true"
        redis-cli set VIB:trig_event '{ "trigger": true, "time": 1719190800123456, "rms": 1.3, "threshold": 0.8 }' 1> /dev/null
    else
        #echo "false"
        redis-cli set VIB:trig_event '{ "trigger": false, "time": 1719190800123456, "rms": 1.3, "threshold": 0.8 }' 1> /dev/null
    fi
    sleep 1
done
