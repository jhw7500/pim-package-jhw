#!/bin/sh

service=$1
status=0
if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		sudo killall $service
	fi
fi

exit "$status"

