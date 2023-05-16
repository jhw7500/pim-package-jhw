#!/bin/bash

service=$1
status=0
status2=0
tag=$(basename "$0")
KEY=RST

while [ 1 ]; do
	if [ ! -z "$service" ]; then
		pgrep "$service" >/dev/null; status=$?
		if [ "$status" -eq 0 ]; then
			echo "ok" > /dev/null
		else
			while [ 1 ]; do 
				pgrep streamApp >/dev/null; status2=$?
				if [ "$status2" -eq 0 ]; then
					#echo "Not yet" > /dev/null
					logger -p local0.notice [$KEY][$tag:$LINENO] streamApp exit not yet
				else
					pgrep BG_Check_for_pim.sh >/dev/null; status2=$?
					if [ "$status2" -eq 0 ]; then
						logger -p local0.notice [$KEY][$tag:$LINENO] BG_Check_for_pim not yet
					else
						break
					fi
				fi
				sleep 1
			done
			logger -p local0.notice [$KEY][$tag:$LINENO] PIMCAM, streamApp, BG_Check_for_pim start 
			/opt/pim/bin/vcm &
			/usr/bin/PIMCAM -j /root/shared_v/edgeconf_pim.json &
			/opt/pim/bin/BG_Check_for_pim.sh & 2>/dev/null
	                #systemctl restart cam-operate
		fi
	fi
	sleep 1
done
exit "$status"

