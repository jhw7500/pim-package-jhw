#!/bin/sh

service=$1
status=0
status2=0
while [ 1 ]; do 
	if [ ! -z "$service" ]; then
		pgrep "$service" >/dev/null; status=$?
		if [ "$status" -eq 0 ]; then
			echo "ok" > /dev/null
		else
			while [ 1 ]; do 
				pgrep streamApp >/dev/null; status2=$?
				if [ "$status2" -eq 0 ]; then
					echo "Not yet" > /dev/null
				else
					break
				fi
				sleep 1
			done
			/opt/pim/bin/vcm &
			/usr/bin/PIMCAM -j /root/shared_v/edgeconf_pim.json &
		fi
	fi
	sleep 1;
done

exit "$status"

