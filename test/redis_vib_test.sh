#!/bin/bash
tag=$(basename "$0")
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
vhl_name=$(jq -r '.VHL_CAM.vhl_name' "$FILE_JSON")
file_dir="/mnt/sd_cam"
file_date=""
while true; do
    file_date=$(date +"%Y%m%d_%H%M00")
    touch "${file_dir}/${vhl_name}_${file_date}-vib.bin"

    if (( RANDOM % 2 < 1 )); then
        #echo "true"
        redis-cli set VIB:trig_event '{ "trigger": true, "time": 1719190800123456, "rms": 1.3, "threshold": 0.8 }' 1> /dev/null
    else
        #echo "false"
        redis-cli set VIB:trig_event '{ "trigger": false, "time": 1719190800123456, "rms": 1.3, "threshold": 0.8 }' 1> /dev/null
    fi
    sleep 0.1
    if (( RANDOM % 2 < 1 )); then
        #echo "true"
        redis-cli set VIB:trig_event '{ "trigger": true, "time": 1719190800123456, "rms": 1.3, "threshold": 0.8 }' 1> /dev/null
    else
        #echo "false"
        redis-cli set VIB:trig_event '{ "trigger": false, "time": 1719190800123456, "rms": 1.3, "threshold": 0.8 }' 1> /dev/null
    fi
    sleep 60
done
