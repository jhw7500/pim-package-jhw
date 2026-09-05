#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
tag=$(basename "$0")
KEY=RST

BG_FLAG_FILE="/tmp/bg_chk_flag.bin"

get_cam_disconnect_flag() {
    local v
    v=$(cat "$BG_FLAG_FILE" 2>/dev/null | tr -d '\n')
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        echo 0
        return 0
    fi
    echo $((v & 0xf))
}

is_cam_disconnected() {
    local f
    f=$(get_cam_disconnect_flag)
    (( f != 0 ))
}

#logger -p local0.notice "[$KEY][$tag:$LINENO] kill_test.sh start"

if [ -f /tmp/restart_flag ]; then
    logger -p local0.notice "[RST][$tag:$LINENO] exit because already kill app..."
    exit 0
fi

logger -p local0.notice "[$KEY][$tag:$LINENO] set restart_flag"
touch /tmp/restart_flag
#touch /tmp/kill_flag
pid=0
cnt=0
service=0
limitcnt=5
rebootcnt=30
defunct=0

#FILE_CHECK="/tmp/file_check"
#echo "ING" > $FILE_CHECK

#list="BG_Check_for_pim.sh vcm streamApp PIMCAM"
#list="BG_Check_for_pim.sh vcm gstApp"
list="BG_Check_for_pim.sh"

JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
list+=" gstApp streamApp PIMCAM"
:<<'END'
app=$(jq -r '.VHL_CAM.app' "$FILE_JSON")
cap_en=$(jq -r '.VHL_CAM.capture.enable' "$FILE_JSON")
if [ "$cap_en" == "true" ]; then
    list+=" gstApp"
elif [ "$app" == "streamApp" ]; then
    list+=" streamApp PIMCAM"
elif [ "$app" == "gstApp" ]; then
    list+=" gstApp"
else
    logger -p local0.err "[$KEY][$tag:$LINENO] app : $app"
    logger -p local0.err "[$KEY][$tag:$LINENO] please update json"
    list+=" streamApp PIMCAM gstApp"
    #exit 0
fi
END

logger -p local0.info "[$KEY][$tag:$LINENO] service : $list"
:<<'END'
for service in $list; do
#logger -p local0.notice [$KEY][$tag:$LINENO] $service 
if [ ! -z "$service" ]; then
	#pgrep "$service" >/dev/null; status=$?
	#echo $service:$status
	#if [ "$status" -eq 0 ]; then
		#pid=$(ps -C $service |grep $service |awk '{print $1}')
		#echo $service" pid:":${pid}
		logger -p local0.notice "[$KEY][$tag:$LINENO] kill $service"
		#sudo kill -9 $pid
		sudo killall -s KILL $service
	#fi
fi
done
END

# 프로세스 검색은 '실행 대상' 으로 한정한다.
# `ps -ef | grep $service` 는 명령줄 전체를 보므로 그 문자열이 인자·경로에 들어간
# 무관한 프로세스까지 죽인다 — tail -f .../gstApp.log, 편집기, 빌드·시험 스크립트 등.
# `grep -v grep` 은 grep 자신만 제외할 뿐 이 문제를 막지 못한다.
# `pgrep -x` 는 comm 이 15자로 잘려 BG_Check_for_pim.sh 를 놓치므로 쓸 수 없다
# (실측: -x 는 0건). `(^|/)name( |$)` 는 실행 경로의 마지막 성분으로만 맞춘다.
# 실측(2026-09-05 pim-camera-v016): gstApp / BG_Check_for_pim.sh 각각 정확히 1건 매칭,
# 유인 프로세스(.../gstApp.fix87 인자, 메모 문자열) 모두 배제. (#80)
for service in $list; do
    cnt=0
    if [ ! -z "$service" ]; then
        logger -p local0.info "[$KEY][$tag:$LINENO] kill $service"
        pid=$(pgrep -f "(^|/)${service}( |\$)")
        #sudo pkill $service
        if [ -n "$pid" ]; then
            kill $pid
        else
            continue
        fi

        while :
        do
            #sudo killall $service
            pid=$(pgrep -f "(^|/)${service}( |\$)")
            if [ -n "$pid" ]; then
                if [ "$cnt" -ge "$rebootcnt" ]; then
                    if is_cam_disconnected; then
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] skip reboot because cam is disconnect"
                        break
                    fi
                    logger -p local0.emerg "[$KEY][$tag:$LINENO] reboot because doesn't kill"
                    sleep 1
                    #creboot
                    reboot
                elif [ "$cnt" -ge "$limitcnt" ]; then
                    logger -p local0.notice "[$KEY][$tag:$LINENO] $limitcnt sec($cnt) over!"
                    #defunct=$(ps -ef |grep defunct | grep -v grep)
                    #logger -p local0.notice [$KEY][$tag:$LINENO] $defunct
                    #umount /mnt/sd_cam
                    #defunct=$(ps -ef | grep defunct | grep -v grep | awk '{print $3}' | xargs -t -I % sh -c '{ cat /proc/%/status |grep Name; }')
                    defunct=$(ps -o stat=,comm= -p $pid 2>/dev/null | awk '$1 ~ /Z/ {print $2}')
                    #logger -p local0.err "[$KEY][$tag:$LINENO] defunct : $defunct"
                    if [ -z "$defunct" ]; then
                        logger -p local0.notice "[$KEY][$tag:$LINENO] no defunct"
                        #sleep 1
                        #reboot
                        #logger -p local0.err "[$KEY][$tag:$LINENO] killall $service"
                        #killall -s KILL $service
                        if [ "$cnt" -ge 15 ]; then
                            logger -p local0.notice "[$KEY][$tag:$LINENO] kill -9 $pid($service)"
                            kill -9 $pid
                        fi
                    else
                        logger -p local0.err "[$KEY][$tag:$LINENO] defunct : $defunct"
                        logger -p local0.notice "[$KEY][$tag:$LINENO] kill -9 $pid($service)"
                        kill -9 $pid
                    fi
                fi

                sleep 1
                ((cnt++))
                #pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
                logger -s -p local0.notice "[$KEY][$tag:$LINENO] $cnt wait for killing $service..."
                #sudo kill -9 $pid
                #sudo killall -s KILL $service
                #sleep 1
                #((cnt++))
            else
                break
            fi
        done
    fi
done

vhl_name=$(jq -r '(.VHL_CAM.vhl_name // "VD3001")' "$FILE_JSON")
tmp_path=$(jq -r '(.VHL_CAM.tmp_path // "/dev/shm")' "$FILE_JSON")
final_path=$(jq -r '(.VHL_CAM.final_path // "/mnt/sd_cam")' "$FILE_JSON")
mnt_path="/mnt/sd_cam"

# Delete only the current session/minute files to avoid wiping old recordings when paths are equal.
# Prefer using the same start time marker used by chk_cam_operate.sh.
START_TIME_FILE="/tmp/start_video_time_chk"
start_time=$(cat "$START_TIME_FILE" 2>/dev/null | tr -d '\n')
if [ -n "$start_time" ]; then
    datetime_min=$(date -d "$start_time" "+%Y%m%d_%H%M" 2>/dev/null)
else
    datetime_min=$(date "+%Y%m%d_%H%M")
fi

if [ -z "$tmp_path" ] || [ "$tmp_path" = "/" ]; then
    logger -p local0.error "[$KEY][$tag:$LINENO] invalid tmp_path: '$tmp_path' (skip rm)"
elif [ -z "$vhl_name" ] || [ "$vhl_name" = "null" ]; then
    logger -p local0.error "[$KEY][$tag:$LINENO] invalid vhl_name: '$vhl_name' (skip rm)"
else
    # If tmp_path is the same as final_path (or SD root), never wipe everything.
    if [ "$tmp_path" = "$final_path" ] || [ "$tmp_path" = "$mnt_path" ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] rm ${tmp_path}/${vhl_name}_${datetime_min}*"
        rm -f ${tmp_path}/${vhl_name}_${datetime_min}* 2>/dev/null
    else
        # tmp buffer directory: keep behavior but limit to the minute to avoid deleting older sessions.
        logger -p local0.notice "[$KEY][$tag:$LINENO] rm ${tmp_path}/${vhl_name}_${datetime_min}*"
        rm -f ${tmp_path}/${vhl_name}_${datetime_min}* 2>/dev/null
    fi
fi

rm -f "$START_TIME_FILE" 2>/dev/null

logger -p local0.notice "[$KEY][$tag:$LINENO] set kill_flag, reset restart_flag"
touch /tmp/kill_flag
rm /tmp/restart_flag

#logger -p local0.notice "[$KEY][$tag:$LINENO] kill_test.sh end"
#/opt/pim/bin/vcm &
exit 0
