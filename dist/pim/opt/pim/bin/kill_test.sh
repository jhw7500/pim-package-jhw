#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
service=vcm
tag=$(basename "$0")
logger -p local0.notice -t $tag kill_test.sh start
status=0
if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		#pid=$(ps -C $service |grep $service |awk '{print $1}')
		#echo $service" pid:":${pid}
		logger -p local0.notice -t $tag [SYS] killall $service
		#sudo kill -9 $pid
		sudo killall -s KILL $service
	fi
fi

service=streamApp
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                #pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
                #sudo kill -9 $pid
		logger -p local0.notice -t $tag [SYS] killall $service
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
		logger -p local0.notice -t $tag [SYS] killall $service
		sudo killall -s KILL $service
        fi
fi

#/opt/pim/bin/vcm &
exit "$status"
