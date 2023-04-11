#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
group="streamApp ord vcm vsd"
status=0
tag=$(basename "$0")

while :
do
#service=streamApp
cpu=$(mpstat |tail -1 | awk '{print 100-$NF}')
mem=$(sar -r 0 |tail -1 | awk '{print $5}')
logger -p local0.notice -t $tag [CHK] total cpu ${cpu}% memory ${mem}%

for service in $group; do
if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		pid=$(ps -C $service |grep $service |awk '{print $1}')		
		#echo $service" pid:":${pid}
		mem=$(pmap -x $pid |tail -1 |awk '{print "Kbytes:"$3" RSS:"$4" Dirty:"$5}')
		logger -p local0.info -t $tag [CHK] $service ${mem}
	fi
fi
done

sleep 300
done

