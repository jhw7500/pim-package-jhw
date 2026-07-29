#!/bin/bash
source /opt/pim/lib/cam_state.sh

tag=$(basename "$0")
key=RST
JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json

# [1단계] 녹화 확장자 고아 파일 삭제
# gstApp이 죽은 상태이므로 tmp_path의 녹화 파일은 모두 고아
cleanup_recording_orphans() {
    local dir="${1%/}"
    [ -d "$dir" ] || return 0
    local count=0
    local f
    for f in "$dir"/*.mp4 "$dir"/*.ts "$dir"/*.srt "$dir"/*-vib.bin \
             "$dir"/*.mp4.part "$dir"/*.ts.part "$dir"/*.srt.part; do
        [ -f "$f" ] || continue
        logger -p local0.debug "[$key][$tag:$LINENO] orphan rm: $(basename "$f")"
        rm -f "$f"
        count=$((count + 1))
    done
    rm -f /tmp/session_*.video_done /tmp/session_*.srt_done 2>/dev/null
    if [ $count -gt 0 ]; then
        logger -p local0.warning "[$key][$tag:$LINENO] cleaned $count orphan recording files in $dir"
    fi
}

# [2단계] /dev/shm 용량 임계값 초과 시 비상 정리
# 보호 대상(디렉터리, 시스템 플래그)을 제외하고 mtime 오래된 파일부터 삭제
SHM_CRIT_PCT_DEFAULT=70

cleanup_shm_overflow() {
    local shm_dir="/dev/shm"
    local crit_pct=${SHM_CRIT_PCT:-$SHM_CRIT_PCT_DEFAULT}
    local usage

    usage=$(df -P "$shm_dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    [ -n "$usage" ] || return 0
    if [ "$usage" -lt "$crit_pct" ]; then
        return 0
    fi

    logger -p local0.emerg "[$key][$tag:$LINENO] /dev/shm usage ${usage}% >= ${crit_pct}%: emergency cleanup"

    local f
    for f in $(ls -tr "$shm_dir" 2>/dev/null); do
        local path="$shm_dir/$f"
        # 디렉터리 스킵 (recordings, capture 등)
        [ -f "$path" ] || continue
        # 시스템 플래그 보호
        case "$f" in
            sd_mount_flag|sd_write_disabled) continue ;;
        esac

        logger -p local0.warning "[$key][$tag:$LINENO] shm overflow rm: $f"
        rm -f "$path"

        usage=$(df -P "$shm_dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
        [ -n "$usage" ] || break
        [ "$usage" -ge "$crit_pct" ] || break
    done
}

rm -f /tmp/gst_err
printf '0' > /tmp/cam_state/streak 2>/dev/null
if [ -f /tmp/init_cam_flag ]; then
    logger -p local0.notice "[RST][$tag:$LINENO] exit because already module reset..."
    exit 0
fi

logger -p local0.notice "[RST][$tag:$LINENO] set init_cam_flag"
touch /tmp/init_cam_flag
date +%s > /tmp/last_init_cam_ts 2>/dev/null
cam_state_init
cam_record_init
/opt/pim/bin/kill_test.sh

#sleep 3
logger -p local0.notice "[RST][$tag:$LINENO] rmmod imx8-media-dev, max9296"
rmmod imx8-media-dev
#sleep 3
rmmod max9296
#rmmod imx8-media-dev
#rmmod max9296

sleep 0.2
logger -p local0.notice "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
modprobe max9296
rc1=$?
sleep 0.1
modprobe imx8-media-dev
rc2=$?

if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    logger -p local0.emerg "[RST][$tag:$LINENO] modprobe failed (max9296:$rc1 imx8-media-dev:$rc2)"
    logger -p local0.notice "[RST][$tag:$LINENO] reset init_cam_flag"
    rm -f /tmp/init_cam_flag
    exit 1
fi
#PIMCAM -m 0 -c 3 &
FILE_JSON=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$FILE_JSON" ] || [ "$f" -nt "$FILE_JSON" ]; then
        FILE_JSON="$f"
    fi
done
if [ -z "$FILE_JSON" ] || [ ! -f "$FILE_JSON" ]; then
    logger -p local0.emerg "[$key][$tag:$LINENO] edgeconf json not found under /root/shared_v (${JSON_PREFIX}*${JSON_SUFFIX})"
    logger -p local0.notice "[$key][$tag:$LINENO] reset init_cam_flag"
    rm -f /tmp/init_cam_flag
    exit 1
fi
#cam_ch0=$(jq '.VHL_CAM.i2c2.ch0.enable' "$FILE_JSON")
#cam_ch1=$(jq '.VHL_CAM.i2c2.ch1.enable' "$FILE_JSON")
#cam_ch2=$(jq '.VHL_CAM.i2c1.ch2.enable' "$FILE_JSON")
#cam_ch3=$(jq '.VHL_CAM.i2c1.ch3.enable' "$FILE_JSON")
IFS=$'\t' read -r \
    cam_ch0 cam_ch1 cam_ch2 cam_ch3 tmp_path < <(
    jq -r '[
        (.VHL_CAM.i2c2.ch0.enable // false),
        (.VHL_CAM.i2c2.ch1.enable // false),
        (.VHL_CAM.i2c1.ch2.enable // false),
        (.VHL_CAM.i2c1.ch3.enable // false),
        (.VHL_CAM.tmp_path // "/dev/shm")
    ] | @tsv' "$FILE_JSON"
)
unset IFS

csi1_en=0
if [[ "$cam_ch0" == "true" ]] || [[ "$cam_ch1" == "true" ]]; then
    csi1_en=1
fi
csi2_en=0
if [[ "$cam_ch2" == "true" ]] || [[ "$cam_ch3" == "true" ]]; then
    csi2_en=1
fi

#echo "csi1_en:$csi1_en, csi2_en:$csi2_en"

if [[ "$csi1_en" -eq 1 ]] && [[ "$csi2_en" -eq 1 ]]; then
    rst_time=22
else
    rst_time=11
fi

logger -p local0.notice "[RST][$tag:$LINENO] reset init_cam_flag and clear recovery requests"
rm -f /tmp/init_cam_flag
rm -f /tmp/recover_req_init_cam
cam_clear_recovery

# gstApp 기동 전 tmp_path 고아 파일 정리
cleanup_recording_orphans "$tmp_path"
cleanup_shm_overflow

/opt/pim/bin/start_cam.sh $rst_time

#/opt/pim/bin/restart_app.sh &
#systemctl start cam-operate
#/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
