#!/bin/bash
tag=$(basename "$0")
KEY=DSK

logger -p local0.notice "[$KEY][$tag:$LINENO] start"
#LOGFILE="disk_io_monitor.log"
INTERVAL=3

while true; do
    #iostat_output=$(iostat -x 1 2 | awk '$1 ~ /^[a-zA-Z0-9]/ && $NF ~ /^[0-9.]+$/ {print $1, $NF}')
    #iostat_output=$(iostat -x 1 2 | awk '/^Device:/ {getline} {if ($1 != "" && $NF != "") print $1, $NF}')
    #iostat_ouput=$(iostat -x 1 2 | awk '$1 ~ /^mmcblk/ {print $1, $NF}')
    iostat_output=$(iostat -x 1 2 | awk 'NR>7' | awk '$1 ~ /^mmcblk/ {print $1, $NF}') 
    echo "$iostat_output" | while read -r device util; do
        if [[ "$util" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            if (( $(echo "$util >= 100" | bc -l) )); then
                #echo "$(date) - Disk I/O utilization for $device is $util%."
                logger -p local0.warn "[$KEY][$tag:$LINENO] Disk I/O utilization for $device is $util%"
            fi
        fi
    done
    sleep $INTERVAL
done

logger -p local0.notice "[$KEY][$tag:$LINENO] exit"
