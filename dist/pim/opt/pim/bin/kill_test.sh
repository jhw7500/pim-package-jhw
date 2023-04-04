#!/bin/sh

#service=$1
logger -s -t 'sh   ' streamApp PIMCAM vcm 
service=vcm
status=0
if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		pid=$(ps -C $service |grep $service |awk '{print $1}')
		#echo $service" pid:":${pid}
		logger -s -p local0.alret -t $service [SYS] kill -9 $service
		sudo kill -9 $pid
	fi
fi

service=streamApp
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
                #sudo kill -9 $pid
		logger -s -p local0.alret -t $service [SYS] killall -s KILL $service
		sudo killall -s KILL $service
        fi
fi

service=PIMCAM
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":$pid
                #sudo kill -9 $pid
		logger -s -p local0.alret -t $service [SYS] killall -s KILL $service
		sudo killall -s KILL $service
        fi
fi

/opt/pim/bin/vcm &

exit "$status"
