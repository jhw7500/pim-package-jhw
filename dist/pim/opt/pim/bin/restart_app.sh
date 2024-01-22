#!/bin/bash

tag=$(basename "$0")
KEY=RST

#list="BG_Check_for_pim.sh restart_app.sh vcm ord vsd"
list="BG_Check_for_pim.sh vsd ord vcm"
pid=0
service=0

sleep 1

while [ 1 ]; do
    #sleep 2
    pid=$(ps -ef |grep streamApp |grep -v grep |awk '{print $2}')
    if [ -z "$pid" ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] streamApp killed"
        pid=$(ps -ef |grep PIMCAM |grep -v grep |awk '{print $2}')
        if [ -z "$pid" ]; then
            logger -p local0.emerg "[$KEY][$tag:$LINENO] PIMCAM streamApp start"
            #export GST_DEBUG_DUMP_DOT_DIR=/tmp/
	        #/usr/bin/PIMCAM -d 8 -m 0 &
            #/usr/bin/PIMCAM -d 3 -m 0 &
            /opt/pim/bin/start_cam.sh 1
            pid=$(ps -ef |grep BG_Check_for_pim.sh |grep -v grep |awk '{print $2}')
            if [ -z "$pid" ]; then
                logger -p local0.emerg "[$KEY][$tag:$LINENO] BG_Check_for_pim.sh start"
                /opt/pim/bin/BG_Check_for_pim.sh & 2>/dev/null
            fi
        else
            logger -p local0.notice  "[$KEY][$tag:$LINENO] PIMCAM($pid) kill not yet"
            killall -s KILL PIMCAM
        fi
    fi

    for service in $list; do
        if [ ! -z "$service" ]; then
            #pgrep $service >/dev/null; status=$?
            #sleep 1
            pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
            if [ ! -n "$pid" ]; then
                #echo "no" >/dev/null
                #sleep 0.5
                logger -p local0.emerg "[$KEY][$tag:$LINENO] $service start"
                /opt/pim/bin/$service &
            fi
        fi
    done

	sleep 2
done

exit 0

