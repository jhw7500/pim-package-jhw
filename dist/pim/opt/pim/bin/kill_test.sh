#!/bin/sh

#service=$1
logger -s -t 'sh   ' streamApp PIMCAM vcm 
service=vcm
status=0
if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		pid=$(ps -C $service |grep $service |awk '{print $1}')
		echo $service" pid:":${pid}
		sudo kill -9 $pid
	fi
fi

service=streamApp
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                echo $service" pid:":${pid}
                sudo kill -9 $pid
        fi
fi

service=PIMCAM
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                echo $service" pid:":$pid
                sudo kill -9 $pid
        fi
fi

/opt/pim/bin/vcm &

exit "$status"
