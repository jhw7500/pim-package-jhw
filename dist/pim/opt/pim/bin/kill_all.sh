#!/bin/sh

#service=$1
service=streamApp
status=0
if [ ! -z "$service" ]; then
	pgrep "$service" >/dev/null; status=$?
	if [ "$status" -eq 0 ]; then
		sudo killall $service
	fi
fi

service=PIMCAM
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                sudo killall $service
        fi
fi

service=vcm
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                sudo killall $service
        fi
fi

service=ord
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                sudo killall $service
        fi
fi

service=vsd
status=0
if [ ! -z "$service" ]; then
        pgrep "$service" >/dev/null; status=$?
        if [ "$status" -eq 0 ]; then
                sudo killall $service
        fi
fi

#sleep 1
/opt/pim/bin/vcm &
/opt/pim/bin/ord &
/opt/pim/bin/vsd &

exit "$status"

