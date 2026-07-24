#!/bin/bash
IMAGENAME="192.168.10.10:48136/ctsiotbe"
start() {
    CFG_FILE="/root/shared_v/ctsiotbe.json"
    ctsiotbe_enable=$(/usr/bin/jq -r '.ctsiotbe_enable // empty' "$CFG_FILE" 2>/dev/null)
    if [ -z "$ctsiotbe_enable" ]; then
        ctsiotbe_enable="true"
    fi
    if [ "$ctsiotbe_enable" != "true" ]; then
        echo "ctsiotbe_enable=$ctsiotbe_enable"
        exit 0
    fi
    if ! docker image inspect "$IMAGENAME" >/dev/null 2>&1; then
        echo "Docker image not found: $IMAGENAME"
        exit 0
    fi
    EVENT_STORAGE_LIMIT_MB=$(/usr/bin/python3 /opt/pim_gate/bin/v1/pimconf.py pimconf.record_event_max_mb | tr -d '\r\n')
    EVENT_CLEANUP_BATCH_SIZE=${EVENT_CLEANUP_BATCH_SIZE:-10}
    logger -p local2.info "CTSIOTBE|storage limit ${EVENT_STORAGE_LIMIT_MB} MB"
    mkdir -p /mnt/sd_cam/event


    run_container() {
        docker rm -f ctsiotbe 2>/dev/null

        docker run --rm -d --name=ctsiotbe \
            -p 5000:5000 \
            -e EVENT_STORAGE_LIMIT_MB=${EVENT_STORAGE_LIMIT_MB} \
            -e EVENT_CLEANUP_BATCH_SIZE=${EVENT_CLEANUP_BATCH_SIZE} \
            -v /dev/shm/be_share:/data/share \
            -v /mnt/sd_cam/event:/data/db \
            ${IMAGENAME}
    }

    for retry in 0 1; do
        run_container
        sleep 3

        st=$(/usr/bin/docker inspect -f "{{.State.Running}}" ctsiotbe 2>/dev/null || true)

        if [ "$st" = "true" ]; then
            logger -p local2.info "CTSIOTBE|container started"
            return 0
        fi

        logger -p local2.warning "CTSIOTBE|container start failed retry=$retry"

        docker logs --tail 50 ctsiotbe 2>&1 | logger -p local2.warning -t CTSIOTBE
        docker rm -f ctsiotbe 2>/dev/null
    done

    logger -p local2.err "CTSIOTBE|container start failed after retry"
    return 1
}

stop() {
    st=$(/usr/bin/docker inspect -f "{{.State.Running}}" ctsiotbe 2>/dev/null || true)
    [ "$st" != "true" ] && exit 0
    docker stop ctsiotbe
    docker rm -f ctsiotbe 2>/dev/null
}

log() {
    docker logs -f --tail 100 ctsiotbe
}

case $1 in
    start|stop|log) $1;;
    restart) stop; start;;
    *) echo "Run as $0 <start|stop|restart|log>"; exit 1;;
esac