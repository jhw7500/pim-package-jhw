#!/bin/bash
# wlan_watchdog.sh ? wlp1s0 링크 + 호스트 ping 주기 체크, 끊김 시 update_network.py 자동 호출

IFACE=wlp1s0
PEER_IP=192.168.0.2
CHECK_INTERVAL=30
FAIL_THRESHOLD=2
RECOVERY_COOLDOWN=120
RECOVERY_CMD='python3 /opt/cis/bin/update_network.py'
LOG_TAG=wlan-watchdog

fail_count=0
last_recovery=0

iface_ok() {
    ip -br link show "$IFACE" 2>/dev/null | grep -qE 'UP|UNKNOWN' &&     ip -br addr show "$IFACE" 2>/dev/null | grep -qE [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+
}

peer_ok() {
    ping -c 1 -W 2 "$PEER_IP" >/dev/null 2>&1
}

logger -t $LOG_TAG "started iface=$IFACE peer=$PEER_IP interval=${CHECK_INTERVAL}s threshold=$FAIL_THRESHOLD cooldown=${RECOVERY_COOLDOWN}s"

while true; do
    if iface_ok && peer_ok; then
        if [ $fail_count -gt 0 ]; then
            logger -t $LOG_TAG "link recovered after $fail_count fail(s)"
        fi
        fail_count=0
    else
        fail_count=$((fail_count + 1))
        logger -t $LOG_TAG "link check FAIL ($fail_count/$FAIL_THRESHOLD) iface_ok=$(iface_ok && echo y || echo n) peer_ok=$(peer_ok && echo y || echo n)"
        if [ $fail_count -ge $FAIL_THRESHOLD ]; then
            NOW=$(date +%s)
            if [ $((NOW - last_recovery)) -lt $RECOVERY_COOLDOWN ]; then
                logger -t $LOG_TAG "recovery skipped (cooldown $((NOW - last_recovery))s < ${RECOVERY_COOLDOWN}s)"
            else
                last_recovery=$NOW
                logger -t $LOG_TAG "running recovery: $RECOVERY_CMD"
                $RECOVERY_CMD 2>&1 | logger -t $LOG_TAG
                logger -t $LOG_TAG "recovery exit=$?"
            fi
            fail_count=0
        fi
    fi
    sleep $CHECK_INTERVAL
done
