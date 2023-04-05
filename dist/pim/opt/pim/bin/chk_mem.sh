#!/bin/sh

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
status=0
while :
do
service=streamApp
cpu=$(mpstat |tail -1 | awk '{print 100-$NF}')
mem=$(sar -r 0 |tail -1 | awk '{print $5}')
logger -p local0.notice -t $service [CPU] total cpu ${cpu}% memory ${mem}%

if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		pid=$(ps -C $service |grep $service |awk '{print $1}')		
		#echo $service" pid:":${pid}
		mem=$(pmap -x $pid |tail -1 |awk '{print "Kbytes:"$3" RSS:"$4" Dirty:"$5}')
		logger -p local0.info -t $service [MEM] ${mem}
	fi
fi
service=vcm
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
                mem=$(pmap -x $pid |tail -1 |awk '{print "Kbytes:"$3" RSS:"$4" Dirty:"$5}')
		logger -p local0.info -t $service [MEM] ${mem}
        fi
fi
service=ord
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
                mem=$(pmap -x $pid |tail -1 |awk '{print "Kbytes:"$3" RSS:"$4" Dirty:"$5}')
		logger -p local0.info -t $service [MEM] ${mem}
        fi
fi

service=vsd
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
                mem=$(pmap -x $pid |tail -1 |awk '{print "Kbytes:"$3" RSS:"$4" Dirty:"$5}')
		logger -p local0.info -t $service [MEM] ${mem}
        fi
fi

sleep 60
done

