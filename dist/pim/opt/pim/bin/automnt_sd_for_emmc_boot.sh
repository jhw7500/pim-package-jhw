#!/bin/bash
TAG=$(basename "$0")
KEY=MNT
DEVICE=/dev/mmcblk1p1
DIR=/mnt/sd_cam
mnt_state=0
mnt_cnt=0
mnt_folder=0
mnt_dev=0
daemon_name=""
status=""
mnt_flag="/dev/shm/sd_mount_flag"
fsck_cnt=0
reinsert_fail_cnt=0
REINSERT_FAIL_MAX=5
REINSERT_BACKOFF_SEC=60
LOCKFILE="/tmp/automnt_sd_for_emmc_boot.lock"
exec 200>"$LOCKFILE"
flock -n 200 || exit 1

# 공통 함수: tmp_path를 /dev/shm으로 fallback
fallback_to_shm() {
    local config_file="$1"
    local tmp_path
    tmp_path=$(jq -r '.VHL_CAM.tmp_path' "$config_file")
    if [ "$tmp_path" != "/dev/shm" ]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] fallback tmp_path : $tmp_path -> /dev/shm"
        local _tmpf
        _tmpf=$(mktemp "${config_file}.XXXXXX") && \
          jq --arg prev "$tmp_path" '.VHL_CAM.prev_tmp_path_before_fallback = $prev | .VHL_CAM.tmp_path_fallback_active = true | .VHL_CAM.tmp_path = "/dev/shm"' "$config_file" > "$_tmpf" && \
          mv -f "$_tmpf" "$config_file" || rm -f "$_tmpf"
        systemctl restart cam-operate
    fi
}

# SD 재삽입 시 tmp_path를 SD 경로로 복구
restore_to_sd() {
    local config_file="$1"
    local current_tmp
    current_tmp=$(jq -r '.VHL_CAM.tmp_path' "$config_file")

    if [ "$current_tmp" == "/dev/shm" ]; then
        local fallback_active
        fallback_active=$(jq -r '(.VHL_CAM.tmp_path_fallback_active // false)' "$config_file")
        if [ "$fallback_active" != "true" ]; then
            logger -p local0.notice "[$KEY][$TAG:$LINENO] tmp_path is /dev/shm by configuration. skip auto-restore"
            return 0
        fi

        local target_tmp=""
        target_tmp=$(jq -r '(.VHL_CAM.prev_tmp_path_before_fallback // empty)' "$config_file")

        if [ -z "$target_tmp" ] || [ "$target_tmp" = "null" ] || [ "$target_tmp" = "/dev/shm" ]; then
            logger -p local0.warning "[$KEY][$TAG:$LINENO] skip tmp_path restore: previous path unavailable"
            local _tmpf
            _tmpf=$(mktemp "${config_file}.XXXXXX") && \
              jq '.VHL_CAM.tmp_path_fallback_active = false | del(.VHL_CAM.prev_tmp_path_before_fallback)' "$config_file" > "$_tmpf" && \
              mv -f "$_tmpf" "$config_file" || rm -f "$_tmpf"
            return 0
        fi

        logger -p local0.notice "[$KEY][$TAG:$LINENO] restoring tmp_path : /dev/shm -> $target_tmp"
        local _tmpf
        _tmpf=$(mktemp "${config_file}.XXXXXX") && \
          jq --arg target "$target_tmp" '.VHL_CAM.tmp_path = $target | .VHL_CAM.tmp_path_fallback_active = false | del(.VHL_CAM.prev_tmp_path_before_fallback)' "$config_file" > "$_tmpf" && \
          mv -f "$_tmpf" "$config_file" || rm -f "$_tmpf"
        systemctl restart cam-operate
    fi
}

JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
FILE_JSON=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -f "$f" ] && FILE_JSON="$f"
done

if [ -z "$FILE_JSON" ] || [ ! -f "$FILE_JSON" ]; then
    logger -p local0.emerg "[$KEY][$TAG:$LINENO] config file not found: /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}"
    exit 1
fi
tmp_path=$(jq -r '.VHL_CAM.tmp_path' "$FILE_JSON")

FSTYPE="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null)"
if [ -z "$FSTYPE" ]; then
    FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null)"
fi

logger -p local0.notice "[$KEY][$TAG:$LINENO] dev : $DEVICE, dir : $DIR, fstype : $FSTYPE, tmp_path : $tmp_path"

while true; do
    case $mnt_state in
        0)
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                logger -p local0.info "[$KEY][$TAG:$LINENO] umount -l $DIR (prep for re-mount)"
                # 이전 마운트 상태가 남아있을 수 있으므로 lazy unmount 수행
                umount -l "$DIR" 2>/dev/null
                
                mnt_dev=$(awk -v dev="$DEVICE" '$1 == dev {print $1}' /proc/mounts)
                if [ -z "$mnt_dev" ]; then
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : rm -rf /mnt/*"
                    rm -rf "$DIR"

                    if [ ! -d "$DIR" ]; then
                        logger -p local0.info "[$KEY][$TAG:$LINENO] mkdir -p $DIR"
                        mkdir -p "$DIR"
                    fi

                    FSTYPE="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null)"
                    if [ -z "$FSTYPE" ]; then
                        FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null)"
                    fi

                    logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE fstype : $FSTYPE, mounting to $DIR"
                    case "$FSTYPE" in
                        vfat|fat|fat32|msdos)
                            mount -t vfat -o noatime,nodiratime,flush,dirsync,utf8=1,shortname=mixed "$DEVICE" "$DIR"
                            ;;
                        ext4)
                            mount -t ext4 -o noatime,nodiratime,commit=60,data=ordered,barrier=1,errors=remount-ro "$DEVICE" "$DIR"
                            ;;
                        exfat)
                            mount -t exfat -o noatime,nodiratime "$DEVICE" "$DIR"
                            ;;
                        *)
                            logger -p local0.crit "[$KEY][$TAG:$LINENO] $DEVICE fstype is undefined : $FSTYPE"
                            ((reinsert_fail_cnt++))
                            if [ $reinsert_fail_cnt -ge $REINSERT_FAIL_MAX ]; then
                                logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE fstype detection failed $reinsert_fail_cnt times. SD card may be damaged. Waiting ${REINSERT_BACKOFF_SEC}s before retry."
                                fallback_to_shm "$FILE_JSON"
                                mnt_state=2
                                sleep $REINSERT_BACKOFF_SEC
                                continue
                            fi
                            mount "$DEVICE" "$DIR"
                            ;;
                    esac

                    mnt_folder=$(awk -v dev="$DEVICE" '$1 == dev {print $2}' /proc/mounts)
                    if [ "$mnt_folder" == "$DIR" ]; then
                        if awk -v dev="$DEVICE" '$1 == dev && $4 ~ /^rw/ {found=1} END {exit !found}' /proc/mounts; then
                            shopt -s nocaseglob
                            FILES=("$DIR"/FSCK*)
                            if [ -e "${FILES[0]}" ]; then
                                rm -f "$DIR"/FSCK*
                            fi
                            shopt -u nocaseglob

                            logger -p local0.notice "[$KEY][$TAG:$LINENO] sd_mount_flag set"
                            echo '1' > "$mnt_flag"
                            mnt_state=1
                            mnt_cnt=0
                            fsck_cnt=0
                            reinsert_fail_cnt=0

                            sd_tmp_path_cfg=$(jq -r '(.VHL_CAM.sd_tmp_path // "'"$DIR"'/tmp")' "$FILE_JSON" 2>/dev/null)
                            cleanup_dirs=("$DIR/tmp")
                            if [ -n "$sd_tmp_path_cfg" ] && [ "$sd_tmp_path_cfg" != "$DIR/tmp" ]; then
                                case "$sd_tmp_path_cfg" in
                                    "$DIR"/*)
                                        cleanup_dirs+=("$sd_tmp_path_cfg")
                                        ;;
                                    *)
                                        logger -p local0.warning "[$KEY][$TAG:$LINENO] sd_tmp_path outside $DIR, skip cleanup: $sd_tmp_path_cfg"
                                        ;;
                                esac
                            fi

                            for d in "${cleanup_dirs[@]}"; do
                                if [ ! -d "$d" ]; then
                                    mkdir -p "$d"
                                    logger -p local0.notice "[$KEY][$TAG:$LINENO] created $d"
                                fi

                                part_count=$(find "$d" -name "*.part" 2>/dev/null | wc -l)
                                if [ "$part_count" -gt 0 ]; then
                                    logger -p local0.notice "[$KEY][$TAG:$LINENO] cleaning up $part_count .part files in $d"
                                    find "$d" -name "*.part" -delete 2>/dev/null
                                fi
                            done

                            rm -f /tmp/session_*.all_done 2>/dev/null

                            daemon_name=cam-operate
                            status=$(systemctl is-enabled "$daemon_name" 2>/dev/null)
                            if [ "$status" == "enabled" ]; then
                                status=$(systemctl is-active "$daemon_name" 2>/dev/null)
                                if [ "$status" != "active" ]; then
                                    systemctl start "$daemon_name"
                                fi
                            fi

                            # /dev/shm으로 전환된 설정을 다시 SD 경로로 복구
                            restore_to_sd "$FILE_JSON"
                        else
                            logger -p local0.err "[$KEY][$TAG:$LINENO] mounted not r/w"
                            mnt_state=1
                        fi
                    else
                        logger -p local0.err "[$KEY][$TAG:$LINENO] sd mount failed, fallback to /dev/shm"
                        fallback_to_shm "$FILE_JSON"
                        mnt_state=1
                    fi
                elif [ "$mnt_dev" != "$DEVICE" ]; then
                    logger -p local0.err "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev != $DEVICE"
                    mnt_state=1
                elif [ "$(cat /sys/block/mmcblk1/ro)" = "1" ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] mmcblk1 h/w read only"
                    echo '0' > "$mnt_flag"
                    mnt_state=1
                elif awk -v dev="$DEVICE" '$1 == dev && $4 ~ /^ro/ {found=1} END {exit !found}' /proc/mounts; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] mmcblk1 s/w read only"
                    echo '0' > "$mnt_flag"
                    mnt_state=1
                else
                    mnt_state=1
                fi
            else
                # SD 물리적으로 없음 — 재삽입 대기 상태로 전환
                fallback_to_shm "$FILE_JSON"
                mnt_state=2
            fi
        ;;
        1)
            if [ ! -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                ((mnt_cnt++))
                if [ $mnt_cnt -gt 3 ]; then
                    echo '0' > "$mnt_flag"
                    logger -p local0.emerg "[$KEY][$TAG:$LINENO] please insert sd card!!"
                    # 점유 프로세스에 SIGTERM 전송 (SIGKILL 대신, 로그인 쉘 보호)
                    sd_pids=$(fuser -m "$DIR" 2>/dev/null)
                    if [ -n "$sd_pids" ]; then
                        logger -p local0.warning "[$KEY][$TAG:$LINENO] processes using $DIR:$sd_pids"
                        fuser -TERM -km "$DIR" 2>/dev/null
                        sleep 1
                    fi
                    umount -l "$DIR" 2>/dev/null
                    fallback_to_shm "$FILE_JSON"
                    mnt_cnt=0
                    mnt_state=2
                fi
            else
                mnt_dev=$(awk -v dir="$DIR" '$2 == dir {print $1}' /proc/mounts)
                if [ "$mnt_dev" != "$DEVICE" ] || [ "$(cat /sys/block/mmcblk1/ro)" = "1" ] || awk -v dev="$DEVICE" '$1 == dev && $4 ~ /^ro/ {found=1} END {exit !found}' /proc/mounts; then
                    ((mnt_cnt++))
                    echo '0' > "$mnt_flag"

                    if [ "$(cat /sys/block/mmcblk1/ro)" = "1" ]; then
                        logger -p local0.error "[$KEY][$TAG:$LINENO] $DEVICE is in H/W read-only mode(mnt_cnt:$mnt_cnt/fsck_cnt:$fsck_cnt)"
                    fi

                    if awk -v dev="$DEVICE" '$1 == dev && $4 ~ /^ro/ {found=1} END {exit !found}' /proc/mounts; then
                        logger -p local0.error "[$KEY][$TAG:$LINENO] $DEVICE is in S/W read-only mode(mnt_cnt:$mnt_cnt/fsck_cnt:$fsck_cnt)"
                    fi

                    if [ $mnt_cnt -gt 3 ]; then
                        echo '0' > "$mnt_flag"
                        ((fsck_cnt++))
                        if [ $fsck_cnt -gt 3 ]; then
                            logger -p local0.crit "[$KEY][$TAG:$LINENO] $DEVICE mount error"
                            fallback_to_shm "$FILE_JSON"
                            fsck_cnt=0
                            mnt_state=2
                        fi
                    fi
                fi
            fi
        ;;
        2)
            # SD absent, fallback 완료 — 재삽입만 감시
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                if [ $reinsert_fail_cnt -ge $REINSERT_FAIL_MAX ]; then
                    # fstype 감지 연속 실패: SD 물리적 제거 확인 후에만 리셋
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] SD present but fstype failed ${reinsert_fail_cnt}x. Waiting for physical re-insert."
                else
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] SD card re-inserted, attempting mount"
                    mnt_cnt=0
                    fsck_cnt=0
                    mnt_state=0
                fi
            else
                # SD 물리적으로 제거됨 — 카운터 리셋
                if [ $reinsert_fail_cnt -gt 0 ]; then
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] SD card physically removed. Resetting failure counter."
                    reinsert_fail_cnt=0
                fi
            fi
        ;;
    esac
    sleep 3
done
