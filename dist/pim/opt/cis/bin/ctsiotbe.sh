#!/bin/bash
IMAGENAME="192.168.10.10:48136/ctsiotbe"
start() {
    mkdir -p /mnt/sd_cam/event
    docker run --rm -d --name=ctsiotbe \
    -p 5000:5000 \
    -v /dev/shm/be_share:/data/share \
    -v /mnt/sd_cam/event:/data/db \
    ${IMAGENAME}
}

stop() {
    docker stop ctsiotbe
}

log() {
    docker logs -f --tail 100 ctsiotbe
}

case $1 in
    start|stop|log) $1;;
    restart) stop; start;;
    *) echo "Run as $0 "; exit 1;;
esac