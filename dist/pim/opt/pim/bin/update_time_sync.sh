#!/usr/bin/env bash

JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
FILE_JSON=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$FILE_JSON" ] || [ "$f" -nt "$FILE_JSON" ]; then
        FILE_JSON="$f"
    fi
done


ntp_svr=$(jq -r '.NTP_SERVER' "$FILE_JSON")
if [ "$ntp_svr" == "null" ]; then
    ntp_svr=""
fi

dst="/etc/systemd/timesyncd.conf"
if [ -z "$ntp_svr" ]; then
    #echo "disable ntp_server"
    ori=/opt/pim/etc/systemd/timesyncd.conf
    if ! cmp -s -- "$ori" "$dst" 2>/dev/null; then
        cp $ori $dst
    fi
    status=$(timedatectl |grep NTP|awk '{print $3}')
    if [ "$status" != "inactive" ]; then
      timedatectl set-ntp false
    fi
else
    #echo "enable ntp_server"
    change_flag=0
    temp="/tmp/timesyncd.conf"
    cp /opt/pim/etc/systemd/timesyncd.conf $temp
    sed -i "s/^#NTP=.*/NTP=$ntp_svr/" $temp
    sed -i 's/^#RootDistanceMaxSec=.*/RootDistanceMaxSec=10000000/' $temp
    sed -i 's/^#PollIntervalMinSec=.*/PollIntervalMinSec=32/' $temp
    sed -i 's/^#PollIntervalMaxSec=.*/PollIntervalMaxSec=2048/' $temp
    if ! cmp -s -- "$temp" "$dst" 2>/dev/null; then
        cp $temp $dst
        change_flag=1
    fi
    status=$(timedatectl |grep NTP|awk '{print $3}')
    if [ "$change_flag" -ne 0 ] || [ "$status" == "inactive" ]; then
        systemctl restart systemd-timesyncd
        timedatectl set-ntp true
    fi
fi
