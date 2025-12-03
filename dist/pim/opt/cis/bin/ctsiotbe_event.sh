#!/bin/bash
IMAGENAME="192.168.10.10:48136/ctsiotbe-event"
start() {
    docker run --rm -d --name=ctsiotbe_event \
    -p 5001:5001 \
    -v /root/shared_v/event_module/config.json:/app/config.json \
    ${IMAGENAME}
}

stop() {
    docker stop ctsiotbe_event
}

log() {
    docker logs -f --tail 100 ctsiotbe_event
}

case $1 in
    start|stop|log) $1;;
    restart) stop; start;;
    *) echo "Run as $0 "; exit 1;;
esac