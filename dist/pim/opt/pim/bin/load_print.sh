#!/bin/bash 
function load_print() { 
        _cpu_load=$(mpstat | tail -1 | awk '{print 100-$NF}')
        mem_tot=`cat /proc/meminfo | grep ^MemTotal| grep -Po '[0-9.]+ kB' | awk '{print $1}'` 
        mem_avail=`cat /proc/meminfo | grep ^MemAvailable | grep -Po '[0-9.]+ kB' | awk '{print $1}'` 
        _ram_load=`echo "$mem_tot $mem_avail"|awk '{printf "%.1f", ($1 - $2)/$1*100}'` 
        echo -e "cpu_load:$_cpu_load\tram_load:$_ram_load" 
}

while : 
do 
	load_print
	sleep 1
done
