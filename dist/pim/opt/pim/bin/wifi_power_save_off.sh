#!/bin/bash
tag=$(basename "$0")
KEY=RST
IFACE=wlp1s0
TIMEOUT=30
INTERVAL=2

elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
	if iw dev "$IFACE" info >/dev/null 2>&1; then
		iw "$IFACE" set power_save off
		logger -p local0.info "[$KEY][$tag:$LINENO] $IFACE power_save off success"
		exit 0
	fi
	sleep $INTERVAL
	elapsed=$((elapsed + INTERVAL))
done

logger -p local0.err "[$KEY][$tag:$LINENO] $IFACE not found after ${TIMEOUT}s, skip power_save off"
