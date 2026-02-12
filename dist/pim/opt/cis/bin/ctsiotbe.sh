#!/bin/bash
IMAGENAME="192.168.10.10:48136/ctsiotbe"

# 환경변수 기본값 (256GB 디스크 기준)
EVENT_STORAGE_LIMIT_MB=${EVENT_STORAGE_LIMIT_MB:-204800}
EVENT_CLEANUP_BATCH_SIZE=${EVENT_CLEANUP_BATCH_SIZE:-10}

start() {
    mkdir -p /mnt/sd_cam/event
    docker rm -f ctsiotbe 2>/dev/null
    docker run --rm -d --name=ctsiotbe \
    -p 5000:5000 \
    -e EVENT_STORAGE_LIMIT_MB=${EVENT_STORAGE_LIMIT_MB} \
    -e EVENT_CLEANUP_BATCH_SIZE=${EVENT_CLEANUP_BATCH_SIZE} \
    -v /dev/shm/be_share:/data/share \
    -v /mnt/sd_cam/event:/data/db \
    ${IMAGENAME}
}

stop() {
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