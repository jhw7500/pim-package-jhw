#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
group="streamApp ord vcm vsd"
status=0
tag=$(basename "$0")
KEY=cpu
delay=60
if [[ -n "$1" ]]; then
    delay=$1
fi

logger -p local0.notice "[$KEY][$tag:$LINENO] cpu info check delay : $delay"
CPU_TEMP_MAX0=0
CPU_TEMP_MIN0=100
CPU_TEMP_MAX1=0
CPU_TEMP_MIN1=100

while :
do
    #service=streamApp
    cpu=$(mpstat 1 1|tail -1 | awk '{print 100-$NF}')
    mem=$(sar -r 0 |tail -1 | awk '{print $5}')
    logger -p local0.notice "[$KEY][$tag:$LINENO] total cpu :${cpu}%, memory : ${mem}%"

:<<'END'
    for service in $group; do
        if [ ! -z "$service" ]; then
	        pgrep "$service" >/dev/null; status=$?
	        if [ "$status" -eq 0 ]; then
		        pid=$(ps -C $service |grep $service |awk '{print $1}')		
		        #echo $service" pid:":${pid}
		        mem=$(pmap -x $pid |tail -1 |awk '{print "Kbytes:"$3" RSS:"$4" Dirty:"$5}')
		        logger -p local0.info "[$KEY][$tag:$LINENO] $service : ${mem}"
	        fi
        fi
    done
END

    CPU_TMP_VAL0=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp)
    CPU_TMP_VAL1=$(cat /sys/devices/virtual/thermal/thermal_zone1/temp)
    CPU_TEMP0=$(echo "$CPU_TMP_VAL0/1000" | bc)
    CPU_TEMP1=$(echo "$CPU_TMP_VAL1/1000" | bc)

    logger -p local0.notice "[$KEY][$tag:$LINENO] cpu0 temp : $CPU_TEMP0, cpu1 temp : $CPU_TEMP1"

    if [ "$CPU_TEMP0" -gt "$CPU_TEMP_MAX0" ]; then
        CPU_TEMP_MAX0=$((CPU_TEMP0))
        logger -p local0.info "[$KEY][$tag:$LINENO] cpu0 temp max : $CPU_TEMP_MAX0"
    fi

    if [ "$CPU_TEMP0" -lt "$CPU_TEMP_MIN0" ]; then
        CPU_TEMP_MIN0=$((CPU_TEMP0))
        logger -p local0.info "[$KEY][$tag:$LINENO] cpu0 temp min : $CPU_TEMP_MIN0"
    fi


    if [ "$CPU_TEMP1" -gt "$CPU_TEMP_MAX1" ]; then
        CPU_TEMP_MAX1=$((CPU_TEMP1))
        logger -p local0.info "[$KEY][$tag:$LINENO] cpu1 temp max : $CPU_TEMP_MAX1"
    fi

    if [ "$CPU_TEMP1" -lt "$CPU_TEMP_MIN1" ]; then
        CPU_TEMP_MIN1=$((CPU_TEMP1))
        logger -p local0.info "[$KEY][$tag:$LINENO] cpu1 temp min : $CPU_TEMP_MIN1"
    fi

    clk0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu0 clock : $clk"
    clk1=$(cat /sys/devices/system/cpu/cpu1/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu1 clock : $clk"
    clk2=$(cat /sys/devices/system/cpu/cpu2/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu2 clock : $clk"
    clk3=$(cat /sys/devices/system/cpu/cpu3/cpufreq/cpuinfo_cur_freq)
    #logger -p local0.notice "[$KEY][$tag:$LINENO] cpu3 clock : $clk"
    logger -p local0.notice "[$KEY][$tag:$LINENO] cpu0 clk : $clk0, cpu1 clk : $clk1, cpu2 clk : $clk2, cpu3 clk : $clk3"

    sleep $delay
done

