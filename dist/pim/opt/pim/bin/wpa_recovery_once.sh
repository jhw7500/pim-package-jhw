#!/bin/bash
WLAN=$(python3 /opt/cis/bin/getconfval.py dev_wlan 2>/dev/null | tr -d '\r\n')
[ -z "$WLAN" ] && WLAN=wlp1s0
TAG=wpa-recovery

log() {
    logger -p local0.notice -t "$TAG" "[WPA][wpa_recovery_once.sh:${BASH_LINENO[0]}] $1"
}

log "start (dev=$WLAN)"

state=""
for i in 1 2 3 4 5; do
    sleep 2
    state=$(wpa_cli -i "$WLAN" status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')
    if [ "$state" = "COMPLETED" ]; then
        log "connected (poll $i/5)"
        exit 0
    fi
    log "waiting (poll $i/5 state=$state)"
done

log "not connected after 10s (state=$state), forcing reassociate"
out=$(wpa_cli -i "$WLAN" reassociate 2>&1)
rc=$?
log "reassociate rc=$rc out=$out"
sleep 3
final=$(wpa_cli -i "$WLAN" status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')
log "final state after reassociate: $final"
exit 0
