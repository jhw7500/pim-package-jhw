#!/bin/sh

#service=$1
logger -s -t 'sh   ' streamApp PIMCAM vcm 
service=vcm
status=0
while :
do
service=streamApp
if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		pid=$(ps -C $service |grep $service |awk '{print $1}')		
		#echo $service" pid:":${pid}
		mem=$(pmap -x ${pid} | tail -1)
		logger -p local0.info -t $service" [MEM]"${mem}
	fi
fi
service=vcm
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
		mem=$(pmap -x ${pid} | tail -1)
		logger -p local0.info -t $service" [MEM] "${mem}
        fi
fi
service=ord
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
		pmap -x ${pid} | tail -1
		mem=$(pmap -x ${pid} | tail -1)
		logger -p local0.info -t $service" [MEM] "${mem}
        fi
fi
service=vsd
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
		pmap -x ${pid} | tail -1
		mem=$(pmap -x ${pid} | tail -1)
		logger -p local0.info -t $service" [MEM] "${mem}
        fi
fi
sleep 60
done

