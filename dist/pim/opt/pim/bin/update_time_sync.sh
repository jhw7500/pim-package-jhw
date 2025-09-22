#!/usr/bin/env bash

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')


ntp_svr=$(jq -r '.NTP_SERVER' "$FILE_JSON")
if [ "$ntp_svr" == "null" ]; then
    ntp_svr=""
fi

a="/opt/pim/etc/systemd/timesyncd.conf" 
b="/etc/systemd/timesyncd.conf"
if ! cmp -s -- "$a" "$b" 2>/dev/null; then
    cp /opt/pim/etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf
fi

if [ -z "$ntp_svr" ]; then
    #echo "disable ntp_server"
    status=$(timedatectl |grep NTP|awk '{print $3}')
    if [ "$status" != "inactive" ]; then
      timedatectl set-ntp false
    fi
else
    #echo "enable ntp_server"
    sed -i "s/^#NTP=.*/NTP=$ntp_svr/" $b
    sed -i 's/^#RootDistanceMaxSec=.*/RootDistanceMaxSec=10000000/' $b
    sed -i 's/^#PollIntervalMinSec=.*/PollIntervalMinSec=32/' $b
    sed -i 's/^#PollIntervalMaxSec=.*/PollIntervalMaxSec=2048/' $b

    systemctl restart systemd-timesyncd
    timedatectl set-ntp true
fi
