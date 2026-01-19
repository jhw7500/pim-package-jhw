#!/bin/bash
IMAGENAME="192.168.10.10:48136/ctsiotbe-event"
start() {
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || \
        readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    [ -z "$tz" ] && tz="Asia/Seoul"
    echo "timezone: $tz"
    docker rm -f ctsiotbe_event 2>/dev/null
    docker run --rm -d --name=ctsiotbe_event \
    --network host \
    -e TZ="$tz" \
    -v /mnt/sd_cam:/mnt/sd_cam \
    -v /dev/shm/be_share:/dev/shm/be_share \
    -v /root/shared_v/event_module/config.json:/app/config.json \
    ${IMAGENAME}
}

stop() {
    docker stop ctsiotbe_event
    docker rm -f ctsiotbe_event 2>/dev/null
}

log() {
    docker logs -f --tail 100 ctsiotbe_event
}

case $1 in
    start|stop|log) $1;;
    restart) stop; start;;
    *) echo "Run as $0 <start|stop|restart|log>"; exit 1;;
esac