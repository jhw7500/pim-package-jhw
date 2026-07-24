#!/bin/bash

#!/bin/bash
IMAGENAME="192.168.10.10:48136/ctsiotbe-event"
start() {
    CFG_FILE="/root/shared_v/ctsiotbe.json"
    evtmod_enable=$(jq -r '.evtmod_enable // empty' "$CFG_FILE" 2>/dev/null)
    if [ -z "$evtmod_enable" ]; then
        evtmod_enable="true"
    fi
    
    if [[ ${evtmod_enable} != "true" ]]; then
        echo "evtmod_enable=$evtmod_enable"
        exit 0
    fi
    if ! docker image inspect "$IMAGENAME" >/dev/null 2>&1; then
        echo "Docker image not found: $IMAGENAME"
        exit 0
    fi

    PIM_CFG_FILE="/root/shared_v/pim_gate/pim_manager.json"
    PIM_ID=$(jq -r '.base.id_conf.pim_id // empty' "$PIM_CFG_FILE" 2>/dev/null)
    APP_CONF_FILE="/root/shared_v/event_module/config.json"
    mkdir -p "/root/shared_v/event_module/"
    if [ -d "$APP_CONF_FILE" ]; then
        rm -rf "$APP_CONF_FILE"
    fi
    if [ ! -e "$APP_CONF_FILE" ]; then
        echo "{}" > "$APP_CONF_FILE"
    fi

    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || \
        readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    [ -z "$tz" ] && tz="Asia/Seoul"
    echo "timezone: $tz"
    docker rm -f ctsiotbe_event 2>/dev/null
    if [ -z "$PIM_ID" ]; then
        docker run --rm -d --name=ctsiotbe_event \
        --network host \
        -e TZ="$tz" \
        -v /mnt/sd_cam:/mnt/sd_cam \
        -v /dev/shm/be_share:/dev/shm/be_share \
        -v $APP_CONF_FILE:/app/config.json \
        ${IMAGENAME}
    else
        echo "PIM_ID=$PIM_ID"
        docker run --rm -d --name=ctsiotbe_event \
        --network host \
        -e TZ="$tz" \
        -e PIM_ID=$PIM_ID \
        -v /mnt/sd_cam:/mnt/sd_cam \
        -v /dev/shm/be_share:/dev/shm/be_share \
        -v $APP_CONF_FILE:/app/config.json \
        ${IMAGENAME}
    fi
}

stop() {
    st=$(/usr/bin/docker inspect -f "{{.State.Running}}" ctsiotbe_event 2>/dev/null || true); 
    if [[ "$st" == "true" ]] ; then
        docker stop -t 3 ctsiotbe_event
        docker rm -f ctsiotbe_event 2>/dev/null
    fi
}

log() {
    docker logs -f --tail 100 ctsiotbe_event
}

case $1 in
    start|stop|log) $1;;
    restart) stop; start;;
    *) echo "Run as $0 <start|stop|restart|log>"; exit 1;;
esac