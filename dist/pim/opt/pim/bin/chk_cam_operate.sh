#!/bin/bash
source /opt/pim/lib/cam_state.sh

tag=$(basename "$0")
KEY=RST

SD_MOUNT_FLAG_FILE="/dev/shm/sd_mount_flag"
SD_WRITE_DISABLE_FILE_DEFAULT="/tmp/sd_write_disabled"

# Mode B (SD BAD): commit + retention in RAM only
RAM_ONLY_FINAL_PATH_DEFAULT="/dev/shm/recordings"
RAM_CAP_BYTES_DEFAULT=1717986918       # 1.6GiB (warn cap)
RAM_HARD_CAP_BYTES_DEFAULT=2147483648  # 2.0GiB (emergency cap; bypass protect)
RAM_FS_PANIC_PCT_DEFAULT=92            # /dev/shm usage% to trigger panic evict

# Mode A (SD OK): emergency thresholds beyond crit_pct
SD_HARD_CAP_PCT_DEFAULT=99             # SD usage% to bypass session protect (file-level evict)

# Mode A (SD OK): SD retention thresholds
WARN_PCT_DEFAULT=95
CRIT_PCT_DEFAULT=98

# Protect last N sessions from deletion/cleanup
PROTECT_RECENT_SESSIONS_DEFAULT=2

# Stale .part detection without wall-clock (NTP-safe)
PART_STATE_FILE_DEFAULT="/tmp/chk_cam_operate.part_state"
STABLE_WINDOW_SEC_DEFAULT=120
MAINTENANCE_INTERVAL_SEC_DEFAULT=30

BG_FLAG_FILE="/tmp/bg_chk_flag.bin"
RECOVER_REQ_INIT_CAM="/tmp/recover_req_init_cam"
LAST_INIT_TS_FILE="/tmp/last_init_cam_ts"
START_TS_FILE="/tmp/cam_state/last_start_ts"
START_DELAY_FILE="/tmp/pim_cam_start_delay"

startup_grace_extra_sec=10
init_cooldown_sec=30

# If cameras are disconnected, periodically run init_cam.sh to allow recovery
# once cameras are reconnected. Never reboot in disconnect state.
DISCONNECT_INIT_CAM_INTERVAL_SEC_DEFAULT=180
DISCONNECT_INIT_CAM_GRACE_SEC_DEFAULT=60
DISCONNECT_INIT_CAM_STATE_FILE_DEFAULT="/tmp/chk_cam_operate.disconnect_state"

# P2: final-path 진척 telemetry / heartbeat (외부 모니터링용)
FINAL_HEARTBEAT_FILE="/tmp/cam_last_final_ts"
FINAL_HEALTH_FILE="/tmp/cam_final_health"

DISCONNECT_INIT_CAM_STATE_FILE=${DISCONNECT_INIT_CAM_STATE_FILE_DEFAULT}

SYSFS_LINK_I2C2="/sys/bus/i2c/devices/2-0048/link_status"
SYSFS_LINK_I2C1="/sys/bus/i2c/devices/1-0048/link_status"

# 드라이버 sysfs에서 disconnect 비트마스크 읽기
# bit0=ch0, bit1=ch1, bit2=ch2, bit3=ch3
read_driver_disconnect() {
    local m2 m1
    m2=$(cat "$SYSFS_LINK_I2C2" 2>/dev/null | tr -d '\n')
    m1=$(cat "$SYSFS_LINK_I2C1" 2>/dev/null | tr -d '\n')
    [ -z "$m2" ] || [ "$m2" -lt 0 ] 2>/dev/null && m2=0
    [ -z "$m1" ] || [ "$m1" -lt 0 ] 2>/dev/null && m1=0
    echo $((m2 | m1))
}

get_cam_disconnect_flag() {
    local v
    v=$(cat "$BG_FLAG_FILE" 2>/dev/null | tr -d '\n')
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        echo 0
        return 0
    fi
    echo $((v & 0xf))
}

cam_is_disconnected_unified() {
    local state=$(cam_get_state)
    [ "$state" = "degraded" ] || [ "$state" = "recovering" ]
}

modules_loaded() {
    [ -d "/sys/module/max9296" ] && [ -d "/sys/module/imx8_media_dev" ]
}

read_ts() {
    [ -f "$1" ] && cat "$1" 2>/dev/null | tr -d '\n' || echo 0
}

in_init_cooldown() {
    local now last
    now=$(date +%s)
    last=$(read_ts "$LAST_INIT_TS_FILE")
    [ "$last" -gt 0 ] && [ $((now - last)) -lt "$init_cooldown_sec" ]
}

maybe_init_cam_on_disconnect() {
    local cam_disconnect_flag now first_seen last_init

    cam_disconnect_flag=$(get_cam_disconnect_flag)
    local drv_disc
    drv_disc=$(read_driver_disconnect)
    if (( cam_disconnect_flag == 0 )) && (( drv_disc == 0 )); then
        # init_cam 직후 cooldown 중에는 sysfs가 아직 -1(→0)이므로 상태 파일 보존
        if ! in_init_cooldown && ! cam_in_init_cooldown "$init_cooldown_sec"; then
            if [ -f "$DISCONNECT_INIT_CAM_STATE_FILE" ]; then
                logger -p local0.notice "[$KEY][$tag:$LINENO] disconnect state cleared (flag=$cam_disconnect_flag drv=$drv_disc)"
            fi
            rm -f "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null
        fi
        return 1
    fi

    if in_init_cooldown || cam_in_init_cooldown "$init_cooldown_sec"; then
        return 0
    fi

    now=$(date +%s)
    first_seen=$(cat "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null | awk -F',' '{print $1}')
    last_init=$(cat "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null | awk -F',' '{print $2}')
    if [[ ! "$first_seen" =~ ^[0-9]+$ ]]; then
        first_seen=$now
    fi
    if [[ ! "$last_init" =~ ^[0-9]+$ ]]; then
        last_init=0
    fi

    if (( (now - first_seen) < DISCONNECT_INIT_CAM_GRACE_SEC )); then
        printf "%s,%s" "$first_seen" "$last_init" > "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null
        return 1
    fi

    if (( (now - last_init) >= DISCONNECT_INIT_CAM_INTERVAL_SEC )); then
        logger -p local0.notice "[$KEY][$tag:$LINENO] cam disconnect($cam_disconnect_flag): periodic init_cam.sh (interval=${DISCONNECT_INIT_CAM_INTERVAL_SEC}s)"
        printf "%s,%s" "$first_seen" "$now" > "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null
        /opt/pim/bin/init_cam.sh
        return 0
    fi

    printf "%s,%s" "$first_seen" "$last_init" > "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null
    return 1
}

force_edgeconf_app_to_gstapp() {
    local cfg="$1"
    local cur_app=""
    local tmpf=""

    if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
        logger -p local0.err "[$KEY][$tag:$LINENO] edgeconf file not found for app force: $cfg"
        return 1
    fi

    cur_app=$(jq -r '(.VHL_CAM.app // "")' "$cfg" 2>/dev/null | tr -d '\n')
    if [ "$cur_app" = "gstApp" ]; then
        return 0
    fi

    tmpf=$(mktemp "${cfg}.tmp.XXXXXX" 2>/dev/null)
    if [ -z "$tmpf" ]; then
        logger -p local0.err "[$KEY][$tag:$LINENO] mktemp failed for app force: $cfg"
        return 1
    fi

    if jq '.VHL_CAM.app = "gstApp"' "$cfg" > "$tmpf" 2>/dev/null; then
        if mv -f "$tmpf" "$cfg"; then
            logger -p local0.notice "[$KEY][$tag:$LINENO] forced .VHL_CAM.app to gstApp (was:${cur_app:-unset})"
            return 0
        fi
    fi

    rm -f "$tmpf" 2>/dev/null
    logger -p local0.err "[$KEY][$tag:$LINENO] failed to force .VHL_CAM.app to gstApp"
    return 1
}

GetConfig_() {
    IFS=$'\t' read -r \
        srt_en file_chk_reboot time_rec_en file_check_delay \
        startup_grace_extra_sec init_cooldown_sec \
        DISCONNECT_INIT_CAM_INTERVAL_SEC DISCONNECT_INIT_CAM_GRACE_SEC < <(
        jq -r '[
            (.VCM.srt_enable // false),
            (.ETC.file_check_reboot // false),
            (.VCM.file_time_check // false),
            (.ETC.file_check_delay // 10),
            (.ETC.startup_grace_extra_sec // 10),
            (.ETC.init_cooldown_sec // 40),
            (.ETC.disconnect_init_interval_sec // 180),
            (.ETC.disconnect_init_grace_sec // 60)
        ] | @tsv' "$FILE_JSON_"
    )
    unset IFS

    #read  srt_en file_chk_reboot time_rec_en file_check_delay < <(jq -r '[.VCM.srt_enable, .ETC.file_check_reboot, .VCM.file_time_check, .ETC.file_check_delay] | @tsv' $FILE_JSON_)
}

GetConfig() {
    IFS=$'\t' read -r \
        app vhl_name rec_min cap_en cap_record_en cap_rtsp_en \
        tmp_path sd_tmp_path final_path muxer cam_ch0 cam_ch1 cam_ch2 cam_ch3 < <(
        jq -r '[
            (.VHL_CAM.app // "streamApp"),
            (.VHL_CAM.vhl_name // "VD3001"),
            (.VHL_CAM.recording_time // 1),
            (.VHL_CAM.capture.enable // false),
            (.VHL_CAM.capture.record // false),
            (.VHL_CAM.capture.rtsp   // false),
            (.VHL_CAM.tmp_path // "/mnt/sd_cam/tmp"),
            (.VHL_CAM.sd_tmp_path // .VHL_CAM.tmp_path // "/mnt/sd_cam/tmp"),
            (.VHL_CAM.final_path // "/mnt/sd_cam"),
            (.VHL_CAM.muxer // "mp4"),
            (.VHL_CAM.i2c2.ch0.enable // false),
            (.VHL_CAM.i2c2.ch1.enable // false),
            (.VHL_CAM.i2c1.ch2.enable // false),
            (.VHL_CAM.i2c1.ch3.enable // false)
        ] | @tsv' "$FILE_JSON"
    )
    unset IFS

    # Preserve config paths (used for SD retention even if runtime overrides apply)
    final_path_cfg="$final_path"
    sd_tmp_path_cfg="$sd_tmp_path"

    rec_time=$((rec_min*60))
    #rst_time=$((rec_time+90))
    #rst_time=20
    if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
        #logger -p local0.notice "[$key][$tag:$LINENO] csi1 enable"
        csi1_en=1
    fi

    if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
        #logger -p local0.notice "[$key][$tag:$LINENO] csi2 enable"
        csi2_en=1
    fi

    if [[ "$csi1_en" -eq 1 ]] && [[ "$csi2_en" -eq 1 ]]; then
        rst_time=35
        app_delay=22
    else
        rst_time=25
        app_delay=11
    fi
}

StartScript() {
pid=$(ps -ef |grep $1 |grep -v grep |awk '{print $2}')
if [ ! -n "$pid" ]; then
    #echo "no" >/dev/null
    logger -p local0.notice "[$KEY][$tag:$LINENO] $service start"
    /opt/pim/bin/$1 &
fi
}

# .part 파일을 2단계로 이동하는 함수 (경로 동일 케이스 대응)
MovePartFile() {
    local part_file="$1"
    local filename=$(basename "$part_file")
    local final_name
    # .part 확장자가 있으면 제거, 없으면 그대로 유지
    if [[ "$filename" == *.part ]]; then
        final_name="${filename%.part}"
    else
        final_name="$filename"
    fi

    # P1-A: SD 상태가 60s 사이클 사이에 바뀔 수 있으므로 commit 시점에 모드를 재확인하여
    # final_path / sd_tmp_path 가 현재 SD 상태에 맞도록 보장한다.
    # (SD가 마운트 해제됐는데도 final_path가 SD인 채로 mv 시도하면 rootfs 마운트포인트에
    # 잘못 쓰이고 heartbeat가 거짓으로 갱신될 수 있다.)
    apply_storage_mode_overrides

    local src_file="$part_file"
    local part_dir
    part_dir=$(dirname "$part_file")
    local tmp_dir="${tmp_path%/}"
    local sd_tmp_dir="${sd_tmp_path%/}"
    local final_dir="${final_path%/}"

    if [ ! -f "$part_file" ]; then
        logger -p local0.warning "[$KEY][$tag:$LINENO] part file not found: $part_file"
        return 1
    fi

    logger -p local0.debug "[$KEY][$tag:$LINENO] processing: $filename"

    # Stage 1: tmp_path → sd_tmp_path
    # - Only run when the input file is actually in tmp_path
    # - This avoids "cp to self" when recovering a stale .part already in sd_tmp_path
    if [ "$tmp_dir" != "$sd_tmp_dir" ] && [ "$part_dir" = "$tmp_dir" ]; then
        # cross-filesystem copy
        if ! cp "$part_file" "${sd_tmp_dir}/${filename}"; then
            logger -p local0.error "[$KEY][$tag:$LINENO] Stage1 cp failed: $filename"
            return 1
        fi

        # 파일 flush
        sync -f "${sd_tmp_dir}/${filename}" 2>/dev/null || sync

        # 디렉토리 flush
        sync -f "$sd_tmp_dir" 2>/dev/null || sync

        # 원본 삭제 (RAM)
        rm -f "$part_file"

        logger -p local0.debug "[$KEY][$tag:$LINENO] Stage1: $filename → sd_tmp"

        # Stage 2의 소스는 sd_tmp_path
        src_file="${sd_tmp_dir}/${filename}"
    fi

    # Stage 2: sd_tmp_path → final_path (.part 확장자 있으면 제거)
    if [ "$src_file" = "${final_dir}/${final_name}" ]; then
        logger -p local0.debug "[$KEY][$tag:$LINENO] Stage2 skip (same path): $final_name"
    elif ! mv "$src_file" "${final_dir}/${final_name}"; then
        logger -p local0.error "[$KEY][$tag:$LINENO] Stage2 mv failed: $filename"
        return 1
    fi

    # P2-3: final 도착 heartbeat. mv가 mtime을 보존하므로 find -mmin은 도착 시점이 아닌
    # fragment 생성 시점을 본다. 정확한 "최근 final 도착 시각"을 별도 파일로 기록한다.
    date +%s > "$FINAL_HEARTBEAT_FILE" 2>/dev/null

    logger -p local0.info "[$KEY][$tag:$LINENO] Complete: $final_name"
    return 0
}

is_sd_ok() {
    [ -f "$SD_MOUNT_FLAG_FILE" ] && grep -qE '^(1|2)$' "$SD_MOUNT_FLAG_FILE"
}

is_ram_only_mode() {
    # RAM cap retention must run ONLY in RAM-only mode.
    # Enter RAM-only mode when SD is not OK or SD writes are force-disabled.
    local disable_file="${SD_WRITE_DISABLE_FILE:-$SD_WRITE_DISABLE_FILE_DEFAULT}"
    if ! is_sd_ok; then
        return 0
    fi
    if [ -f "$disable_file" ]; then
        return 0
    fi
    return 1
}

extract_session_id_from_filename() {
    # Expected patterns:
    # - <name>_YYYYMMDD_HHMMSS-chX.mp4(.part)
    # - <name>_YYYYMMDD_HHMMSS-chX.ts(.part)
    # Return: YYYYMMDD_HHMM
    local base="$1"
    # Accept both aligned (SS=00) and non-aligned first fragments (SS!=00)
    printf '%s' "$base" | sed -nE 's/.*_([0-9]{8}_[0-9]{4})[0-9]{2}.*/\1/p'
}

apply_storage_mode_overrides() {
    # Runtime-only overrides; do not edit edgeconf.
    # If SD is not OK, do not write to SD. Keep committing in RAM-only.
    local disable_file="${SD_WRITE_DISABLE_FILE:-$SD_WRITE_DISABLE_FILE_DEFAULT}"
    if ! is_sd_ok || [ -f "$disable_file" ]; then
        final_path="${RAM_ONLY_FINAL_PATH:-$RAM_ONLY_FINAL_PATH_DEFAULT}"
        sd_tmp_path="$tmp_path"
    else
        # Restore snapshot values loaded at process start.
        # This avoids depending on live JSON reloads while still allowing SD OK/BAD transitions.
        if [ -n "$final_path_cfg" ]; then
            final_path="$final_path_cfg"
        fi
        if [ -n "$sd_tmp_path_cfg" ]; then
            sd_tmp_path="$sd_tmp_path_cfg"
        fi
    fi
}

# Cache variables for session list
_SESSIONS_CACHE_DIR=""
_SESSIONS_CACHE_TIME=0
_SESSIONS_CACHE_RESULT=""
_SESSIONS_CACHE_TTL=${SESSIONS_CACHE_TTL:-10}  # Default 10 seconds TTL

list_sessions_in_dir_sorted() {
    local dir="$1"
    local now=$(date +%s)

    # Check cache validity
    if [ "$dir" = "$_SESSIONS_CACHE_DIR" ] && \
       [ $((now - _SESSIONS_CACHE_TIME)) -lt "$_SESSIONS_CACHE_TTL" ]; then
        printf '%s\n' "$_SESSIONS_CACHE_RESULT"
        return
    fi

    # Cache miss: scan directory and build result
    declare -A _seen
    local f base sid

    [ -d "$dir" ] || return 0
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            *.part) continue;;
        esac
        sid=$(extract_session_id_from_filename "$base")
        [ -n "$sid" ] || continue
        _seen["$sid"]=1
    done

    if [ ${#_seen[@]} -gt 0 ]; then
        _SESSIONS_CACHE_RESULT=$(printf '%s\n' "${!_seen[@]}" | sort)
    else
        _SESSIONS_CACHE_RESULT=""
    fi

    # Update cache metadata
    _SESSIONS_CACHE_DIR="$dir"
    _SESSIONS_CACHE_TIME="$now"

    printf '%s\n' "$_SESSIONS_CACHE_RESULT"
}

delete_session_in_dir() {
    local dir="$1"
    local sid="$2"

    [ -d "$dir" ] || return 1
    # mp4/ts
    # seconds can be non-00 for the first fragment after restart
    rm -f "$dir"/*"${sid}"??-ch*.mp4 2>/dev/null
    rm -f "$dir"/*"${sid}"??-ch*.ts 2>/dev/null
    rm -f "$dir"/*"${sid}"??-vib.bin 2>/dev/null
    # subtitle (naming may vary; keep it broad but still tied to sid)
    rm -f "$dir"/*"${sid}"*data*.srt 2>/dev/null
    rm -f "$dir"/*"${sid}"*.srt 2>/dev/null
}

get_df_usage_pct() {
    local dir="$1"
    df -P "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

get_df_inode_pct() {
    local dir="$1"
    df -Pi "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

# SD-side emergency: evict oldest fragments at file granularity until df% drops below stop_pct.
# Bypasses session protect; preserves the single newest fragment.
emergency_evict_oldest_fragments_pct() {
    local dir="$1"
    local stop_pct="$2"
    local files
    [ -d "$dir" ] || return 0
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f \
        \( -name '*.mp4' -o -name '*.ts' -o -name '*.srt' \
           -o -name '*-vib.bin' -o -name '*.part' \) \
        -printf '%T@\t%p\n' 2>/dev/null | sort -n | awk -F'\t' '{print $2}')
    local n=${#files[@]}
    [ "$n" -le 1 ] && return 0
    local last_idx=$((n - 1))
    local i=0 removed=0 cur=""
    for (( i=0; i<last_idx; i++ )); do
        rm -f "${files[$i]}" 2>/dev/null && ((removed++))
        if [ -n "$stop_pct" ]; then
            cur=$(get_df_usage_pct "$dir")
            [ -n "$cur" ] && [ "$cur" -lt "$stop_pct" ] && break
        fi
    done
    if [ "$removed" -gt 0 ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] SD emergency evict: removed $removed fragments (now ${cur:-?}%, dir=$dir)"
    fi
}

enforce_sd_retention_if_needed() {
    local target_dir="$1"
    local warn_pct=${WARN_PCT:-$WARN_PCT_DEFAULT}
    local crit_pct=${CRIT_PCT:-$CRIT_PCT_DEFAULT}
    local protect_n=${PROTECT_RECENT_SESSIONS:-$PROTECT_RECENT_SESSIONS_DEFAULT}
    local usage sid
    local sessions keep_line

    # Skip retention if filesystem is read-only — and force-disable SD writes to fall back to RAM-only.
    # Without this, RAM-only fallback never engages and gstApp keeps hitting EROFS/ENOSPC on SD.
    if ! touch "$target_dir/.retention_rw_test" 2>/dev/null; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] retention: SD read-only — force-disable SD writes ($target_dir)"
        : > "${SD_WRITE_DISABLE_FILE:-$SD_WRITE_DISABLE_FILE_DEFAULT}" 2>/dev/null
        return 1
    fi
    rm -f "$target_dir/.retention_rw_test" 2>/dev/null

    # Optimization: df check interval (check every N deletions instead of every loop)
    local df_check_interval=5
    local delete_count=0

    usage=$(get_df_usage_pct "$target_dir")
    [ -n "$usage" ] || return 0

    if [ "$usage" -lt "$warn_pct" ]; then
        return 0
    fi

    if [ "$usage" -ge "$crit_pct" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] retention: disk usage ${usage}% >= ${crit_pct}% (dir=$target_dir)"
    else
        logger -p local0.error "[$KEY][$tag:$LINENO] retention: disk usage ${usage}% >= ${warn_pct}% (dir=$target_dir)"
    fi

    sessions=$(list_sessions_in_dir_sorted "$target_dir")
    [ -n "$sessions" ] || return 0

    # Compute protected newest sessions
    keep_line=$(printf '%s\n' "$sessions" | tail -n "$protect_n" | tr '\n' '|' | sed 's/|$//')

    while :; do
        sid=$(printf '%s\n' "$sessions" | head -n 1)
        [ -n "$sid" ] || break

        if [ -n "$keep_line" ] && printf '%s\n' "$sid" | grep -qE "^(${keep_line})$"; then
            logger -p local0.warning "[$KEY][$tag:$LINENO] retention: only protected sessions remain; cannot delete further"
            break
        fi

        logger -p local0.notice "[$KEY][$tag:$LINENO] retention: deleting session $sid"
        delete_session_in_dir "$target_dir" "$sid"
        ((delete_count++))

        # Optimization: update list using tail to skip deleted session (avoids re-scanning)
        sessions=$(printf '%s\n' "$sessions" | tail -n +2)
        [ -n "$sessions" ] || break

        # Optimization: check df only every N deletions
        if [ $((delete_count % df_check_interval)) -eq 0 ]; then
            usage=$(get_df_usage_pct "$target_dir")
            [ -n "$usage" ] || break
            [ "$usage" -lt "$warn_pct" ] && break
        fi
    done

    # Hard cap fallback: bypass session protect when SD usage extreme.
    # Triggers on oversized single session, all-.part state, or orphan-named files.
    local hard_pct=${SD_HARD_CAP_PCT:-$SD_HARD_CAP_PCT_DEFAULT}
    usage=$(get_df_usage_pct "$target_dir")
    if [ -n "$usage" ] && [ "$usage" -ge "$hard_pct" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] SD HARD CAP: ${usage}% >= ${hard_pct}% (bypass protect)"
        emergency_evict_oldest_fragments_pct "$target_dir" "$warn_pct"
    fi
}

update_sd_write_disable_flag() {
    local target_dir="$1"
    local disable_file="${SD_WRITE_DISABLE_FILE:-$SD_WRITE_DISABLE_FILE_DEFAULT}"
    local warn_pct=${WARN_PCT:-$WARN_PCT_DEFAULT}
    local crit_pct=${CRIT_PCT:-$CRIT_PCT_DEFAULT}
    local usage inode_pct

    usage=$(get_df_usage_pct "$target_dir")
    [ -n "$usage" ] || return 0

    # Inode exhaustion watchdog: df-block can be fine while ext4 inodes are full.
    # Many small files (.srt / -vib.bin) accumulate faster than block usage.
    inode_pct=$(get_df_inode_pct "$target_dir")

    if [ "$usage" -ge "$crit_pct" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] CRITICAL: disk usage ${usage}% >= ${crit_pct}% (disable SD writes)"
        : > "$disable_file"
    elif [ -n "$inode_pct" ] && [ "$inode_pct" -ge "$crit_pct" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] CRITICAL: SD inode ${inode_pct}% >= ${crit_pct}% (disable SD writes)"
        : > "$disable_file"
    elif [ -f "$disable_file" ] && [ "$usage" -lt "$warn_pct" ] && \
         { [ -z "$inode_pct" ] || [ "$inode_pct" -lt "$warn_pct" ]; }; then
        rm -f "$disable_file"
        logger -p local0.notice "[$KEY][$tag:$LINENO] disk usage ${usage}% inode ${inode_pct:-?}% < ${warn_pct}% (re-enable SD writes)"
    fi
}

get_dir_size_bytes() {
    local dir="$1"
    du -sb "$dir" 2>/dev/null | awk '{print $1}'
}

# Emergency: evict oldest fragments at file granularity, ignoring session protect.
# Used when RAM hard cap or /dev/shm panic threshold is hit.
# Always preserves the single newest fragment so an active recording can continue.
emergency_evict_oldest_fragments() {
    local dir="$1"
    local target_size="$2"
    local files
    [ -d "$dir" ] || return 0
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f \
        \( -name '*.mp4' -o -name '*.ts' -o -name '*.srt' \
           -o -name '*-vib.bin' -o -name '*.part' \) \
        -printf '%T@\t%p\n' 2>/dev/null | sort -n | awk -F'\t' '{print $2}')
    local n=${#files[@]}
    [ "$n" -le 1 ] && return 0
    local last_idx=$((n - 1))
    local i=0 removed=0 cur
    for (( i=0; i<last_idx; i++ )); do
        rm -f "${files[$i]}" 2>/dev/null && ((removed++))
        if [ -n "$target_size" ]; then
            cur=$(get_dir_size_bytes "$dir")
            [ -n "$cur" ] && [ "$cur" -le "$target_size" ] && break
        fi
    done
    if [ "$removed" -gt 0 ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] emergency evict: removed $removed oldest fragments (dir=$dir)"
    fi
}

ram_fs_panic() {
    local pct
    pct=$(df -P /dev/shm 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    [ -n "$pct" ] || return 1
    [ "$pct" -ge "${RAM_FS_PANIC_PCT:-$RAM_FS_PANIC_PCT_DEFAULT}" ]
}

enforce_ram_cap_if_needed() {
    local target_dir="$final_path"
    local cap_bytes=${RAM_CAP_BYTES:-$RAM_CAP_BYTES_DEFAULT}
    local protect_n=${PROTECT_RECENT_SESSIONS:-$PROTECT_RECENT_SESSIONS_DEFAULT}
    local size sid
    local sessions keep_line

    size=$(get_dir_size_bytes "$target_dir")
    [ -n "$size" ] || return 0
    if [ "$size" -le "$cap_bytes" ]; then
        return 0
    fi

    logger -p local0.error "[$KEY][$tag:$LINENO] RAM cap: ${size}B > ${cap_bytes}B (dir=$target_dir)"

    sessions=$(list_sessions_in_dir_sorted "$target_dir")
    [ -n "$sessions" ] || return 0
    keep_line=$(printf '%s\n' "$sessions" | tail -n "$protect_n" | tr '\n' '|' | sed 's/|$//')

    while :; do
        size=$(get_dir_size_bytes "$target_dir")
        [ -n "$size" ] || break
        [ "$size" -gt "$cap_bytes" ] || break

        sid=$(printf '%s\n' "$sessions" | head -n 1)
        [ -n "$sid" ] || break

        if [ -n "$keep_line" ] && printf '%s\n' "$sid" | grep -qE "^(${keep_line})$"; then
            logger -p local0.warning "[$KEY][$tag:$LINENO] RAM cap: only protected sessions remain; cannot delete further"
            break
        fi

        logger -p local0.notice "[$KEY][$tag:$LINENO] RAM cap: deleting session $sid"
        delete_session_in_dir "$target_dir" "$sid"

        sessions=$(list_sessions_in_dir_sorted "$target_dir")
        [ -n "$sessions" ] || break
    done

    # Hard cap fallback: bypass session protect when emergency cap exceeded.
    # Triggers when only protected sessions remain but size still over hard cap
    # (e.g., a single oversized session, all-.part state, orphan-named files).
    local hard_cap=${RAM_HARD_CAP_BYTES:-$RAM_HARD_CAP_BYTES_DEFAULT}
    size=$(get_dir_size_bytes "$target_dir")
    if [ -n "$size" ] && [ "$size" -gt "$hard_cap" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] RAM HARD CAP: ${size}B > ${hard_cap}B (bypass protect)"
        emergency_evict_oldest_fragments "$target_dir" "$cap_bytes"
    fi
}

# 완료된 세션의 모든 .part 파일 처리
ProcessCompletedSessions() {
    local done_file
    local timestamp
    local success_count=0
    local fail_count=0
    local tmp_dir sd_tmp_dir final_dir
    tmp_dir="${tmp_path%/}"
    sd_tmp_dir="${sd_tmp_path%/}"
    final_dir="${final_path%/}"
    local scan_dir part_file base
    local scan_dirs=("$tmp_dir")
    if [ "$sd_tmp_dir" != "$tmp_dir" ]; then
        scan_dirs+=("$sd_tmp_dir")
    fi
    declare -A processed_base

    for done_file in /tmp/session_*.all_done; do
        [ -f "$done_file" ] || continue

        # 타임스탬프 추출 (session_20260127_1430.all_done -> 20260127_1430)
        timestamp=$(basename "$done_file" | sed 's/session_\(.*\)\.all_done/\1/')

        # [보호 로직] 현재 시각(분)과 동일한 세션은 아직 녹화 중일 가능성이 크므로 미룸
        # 예: 02:10:04에 0210 세션이 완료되었다고 오더라도, 02:10:59까지는 0210 세션을 유지함
        current_min_ts=$(date '+%Y%m%d_%H%M')
        if [ "$timestamp" = "$current_min_ts" ]; then
            # logger -p local0.debug "[$KEY][$tag:$LINENO] postponing current session: $timestamp"
            continue
        fi

        # Reset per marker
        processed_base=()

        logger -p local0.notice "[$KEY][$tag:$LINENO] processing session: $timestamp"

        # 해당 타임스탬프의 모든 .part 파일 처리
        # - Scan both tmp_path and sd_tmp_path to handle crash windows (Stage1 done, Stage2 pending)
        for scan_dir in "${scan_dirs[@]}"; do
            [ -d "$scan_dir" ] || continue
            for part_file in "$scan_dir"/*"${timestamp}"*.part \
                             "$scan_dir"/*"${timestamp}"*.mp4 \
                             "$scan_dir"/*"${timestamp}"*.ts \
                             "$scan_dir"/*"${timestamp}"*.srt \
                             "$scan_dir"/*"${timestamp}"*-vib.bin; do
                [ -f "$part_file" ] || continue

                base=$(basename "$part_file")
                # Only mark as processed on success; if tmp attempt fails, allow sd_tmp attempt.
                if [ "${processed_base[$base]+x}" = "x" ]; then
                    continue
                fi

                if MovePartFile "$part_file"; then
                    ((success_count++))
                    processed_base[$base]=1
                else
                    ((fail_count++))
                fi
            done
        done

        # final_path 디렉토리 flush (한 번만)
        sync -f "$final_dir" 2>/dev/null || sync

        if [ $fail_count -eq 0 ]; then
            rm -f "$done_file"
        else
            logger -p local0.error "[$KEY][$tag:$LINENO] keeping marker due to failures: $done_file"
        fi

        if [ $fail_count -eq 0 ]; then
            logger -p local0.notice "[$KEY][$tag:$LINENO] session $timestamp completed: $success_count files"
        else
            logger -p local0.error "[$KEY][$tag:$LINENO] session $timestamp: $success_count ok, $fail_count failed"
        fi

        # 카운터 초기화
        success_count=0
        fail_count=0
    done
}

# Stale .part 파일 정리 (10분 이상 방치된 파일)
CleanupStalePartFiles() {
    local state_file="${PART_STATE_FILE:-$PART_STATE_FILE_DEFAULT}"
    local stable_window_sec=${STABLE_WINDOW_SEC:-$STABLE_WINDOW_SEC_DEFAULT}
    local interval_sec=${MAINTENANCE_INTERVAL_SEC:-$MAINTENANCE_INTERVAL_SEC_DEFAULT}
    local stable_needed=$(( (stable_window_sec + interval_sec - 1) / interval_sec ))
    local protect_n=${PROTECT_RECENT_SESSIONS:-$PROTECT_RECENT_SESSIONS_DEFAULT}

     local tmp_dir="${tmp_path%/}"
     local sd_tmp_dir="${sd_tmp_path%/}"
     local scan_dirs=("$tmp_dir")
     if [ "$sd_tmp_dir" != "$tmp_dir" ]; then
         scan_dirs+=("$sd_tmp_dir")
     fi

     # gstApp writes real start time (seconds can be non-00) into this file.
     # File names are always HHMM00, so the first fragment after app start can be shorter.
     # When that happens, do NOT delete the HHMM00 .part for that minute as "stale".
     local start_time start_sid start_sec
     start_time=$(cat /tmp/start_video_time_chk 2>/dev/null | tr -d '\n')
     start_sid=$(printf '%s' "$start_time" | sed -nE 's/^([0-9]{8}) ([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\1_\2\3/p')
     start_sec=$(printf '%s' "$start_time" | sed -nE 's/^([0-9]{8}) ([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\4/p')

    declare -A prev_size
    declare -A stable_cnt
    declare -A present

    local line path size cnt
    local removed_count=0
    local sid base keep_line
    local recent_sessions

    if [ -f "$state_file" ]; then
        while IFS=$'\t' read -r path size cnt; do
            [ -n "$path" ] || continue
            prev_size["$path"]="$size"
            stable_cnt["$path"]="$cnt"
        done < "$state_file"
    fi

    # Build protected recent session list based on current part files in tmp_path + sd_tmp_path
    recent_sessions=$(for scan_dir in "${scan_dirs[@]}"; do
        [ -d "$scan_dir" ] || continue
        for f in "$scan_dir"/*.part; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            sid=$(extract_session_id_from_filename "$base")
            [ -n "$sid" ] && printf '%s\n' "$sid"
        done
    done | sort -u)
    keep_line=$(printf '%s\n' "$recent_sessions" | tail -n "$protect_n" | tr '\n' '|' | sed 's/|$//')

    # Scan candidates: tmp_path and (if different) sd_tmp_path
    for scan_dir in "${scan_dirs[@]}"; do
        [ -d "$scan_dir" ] || continue
        for part_file in "$scan_dir"/*.part; do
            [ -f "$part_file" ] || continue
            present["$part_file"]=1
            size=$(stat -c %s "$part_file" 2>/dev/null)
            [ -n "$size" ] || continue

            if [ "${prev_size[$part_file]+x}" = "x" ] && [ "${prev_size[$part_file]}" = "$size" ]; then
                stable_cnt["$part_file"]=$(( ${stable_cnt[$part_file]:-0} + 1 ))
            else
                prev_size["$part_file"]="$size"
                stable_cnt["$part_file"]=0
            fi

            base=$(basename "$part_file")
            sid=$(extract_session_id_from_filename "$base")

            # Skip if session is protected or commit marker exists
            if [ -n "$sid" ]; then
                if [ -n "$keep_line" ] && printf '%s\n' "$sid" | grep -qE "^(${keep_line})$"; then
                    continue
                fi
                if [ -f "/tmp/session_${sid}.all_done" ]; then
                    continue
                fi
            fi

            # Stale 판단: size-stable for N maintenance cycles
            if [ "${stable_cnt[$part_file]:-0}" -ge "$stable_needed" ]; then
                if [ "$scan_dir" = "$sd_tmp_dir" ] && [ "$tmp_dir" != "$sd_tmp_dir" ]; then
                    logger -p local0.warning "[$KEY][$tag:$LINENO] stale sd_tmp part: $base (stable_cnt=${stable_cnt[$part_file]})"
                    if MovePartFile "$part_file"; then
                        logger -p local0.notice "[$KEY][$tag:$LINENO] recovered stale: $base"
                    else
                        # Do not delete on recovery failure; keep for next retry / manual inspection.
                        logger -p local0.error "[$KEY][$tag:$LINENO] recovery failed, keeping: $base"
                    fi
                else
                    # tmp_path stale cleanup caveat:
                    # The first fragment after app start/restart can start at non-00 seconds (shorter duration),
                    # but the file name still uses HHMM00. Do NOT treat that first HHMM00 file as stale.
                    if [ "$scan_dir" = "$tmp_dir" ]; then
                        if [ -n "$start_sid" ] && [ -n "$start_sec" ] && [ "$start_sec" != "00" ] && [ -n "$sid" ] && [ "$sid" = "$start_sid" ]; then
                            logger -p local0.notice "[$KEY][$tag:$LINENO] skip stale delete (first short fragment minute): $base (start_time=$start_time)"
                            continue
                        fi

                        if [ -z "$sid" ]; then
                            logger -p local0.notice "[$KEY][$tag:$LINENO] skip stale delete (unrecognized filename): $base"
                            continue
                        fi
                    fi

                    logger -p local0.info "[$KEY][$tag:$LINENO] removing stale part: $base (stable_cnt=${stable_cnt[$part_file]})"
                    rm -f "$part_file"
                fi

                unset prev_size["$part_file"]
                unset stable_cnt["$part_file"]
                ((removed_count++))
            fi
        done
    done

    # Rewrite state file (drop entries not present)
    : > "$state_file"
    for path in "${!prev_size[@]}"; do
        [ "${present[$path]+x}" = "x" ] || continue
        printf '%s\t%s\t%s\n' "$path" "${prev_size[$path]}" "${stable_cnt[$path]:-0}" >> "$state_file"
    done

    if [ $removed_count -gt 0 ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] processed $removed_count stale .part files"
    fi
}

BackfillRamRecordingsToSd() {
    local ram_final_dir="${RAM_ONLY_FINAL_PATH:-$RAM_ONLY_FINAL_PATH_DEFAULT}"
    local sd_final_dir="${final_path_cfg%/}"
    local moved_count=0
    local skipped_count=0
    local fail_count=0
    local now_ts mtime
    local src dst base src_size dst_size

    if [ -z "$sd_final_dir" ] || [ "$sd_final_dir" = "$ram_final_dir" ]; then
        return 0
    fi

    [ -d "$ram_final_dir" ] || return 0
    if [ ! -d "$sd_final_dir" ]; then
        mkdir -p "$sd_final_dir" || return 1
    fi

    now_ts=$(date +%s)
    for src in "$ram_final_dir"/*.mp4 "$ram_final_dir"/*.ts "$ram_final_dir"/*.srt "$ram_final_dir"/*-vib.bin; do
        [ -f "$src" ] || continue

        mtime=$(stat -c %Y "$src" 2>/dev/null || echo 0)
        if [ "$mtime" -gt 0 ] && [ $((now_ts - mtime)) -lt 10 ]; then
            continue
        fi

        base=$(basename "$src")
        dst="$sd_final_dir/$base"

        if [ -e "$dst" ]; then
            src_size=$(stat -c %s "$src" 2>/dev/null || echo "")
            dst_size=$(stat -c %s "$dst" 2>/dev/null || echo "")
            if [ -n "$src_size" ] && [ "$src_size" = "$dst_size" ]; then
                rm -f "$src"
                ((skipped_count++))
                continue
            fi
            dst="${sd_final_dir}/${base}.ramdup.$(date +%s)"
        fi

        if mv "$src" "$dst"; then
            ((moved_count++))
        else
            ((fail_count++))
        fi
    done

    if [ "$moved_count" -gt 0 ] || [ "$skipped_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] ram backlog backfill: moved=$moved_count skipped=$skipped_count failed=$fail_count ($ram_final_dir -> $sd_final_dir)"
        sync -f "$sd_final_dir" 2>/dev/null || sync
        # P0-1: SD 복귀 후 backfill로 RAM 파일이 SD final에 도착했음을 heartbeat에 반영한다.
        # mv는 mtime을 보존하므로 find -mmin은 backfill된 파일을 못 잡고, heartbeat도 갱신 안 되면
        # 다음 CheckFinalArrival 사이클에 false STALL 발생 → 무한 kill_test.sh loop.
        # moved_count>0 (실제 mv 발생) 시에만 갱신. skipped (dedup)는 새 도착이 아니므로 제외.
        if [ "$moved_count" -gt 0 ]; then
            date +%s > "$FINAL_HEARTBEAT_FILE" 2>/dev/null
        fi
    fi

    [ "$fail_count" -eq 0 ]
}

# Final-path telemetry 1줄 갱신. 외부 모니터(pim_guardian 등)에서 읽어 사용.
# 형식: <status> <last_arrival_age_sec | stall_cnt> <window_min> <epoch_now>
_write_final_health() {
    local status="$1"
    local metric="$2"
    local window_min_local=$(( rec_min * 2 ))
    [ "$window_min_local" -lt 2 ] && window_min_local=2
    printf '%s %s %s %s\n' \
        "$status" "$metric" "$window_min_local" "$(date +%s)" \
        > "$FINAL_HEALTH_FILE" 2>/dev/null
}

# Final-path 정체 감시.
# 최근 (rec_min × 2)분 내에 final_path에 새 ${vhl_name}_* 파일이 없으면
# .all_done 마커 누락 등으로 인한 사일런트 정체로 판단하고 카메라 앱을 재시작한다.
# (사용자 우선순위: "정체가 침묵하는 게 진짜 문제, 복구만 되면 OK")
#
# P0 가드:
#   - RAM-only 모드에서는 final_path_cfg(SD)가 의도적으로 안 쓰임 → skip
#   - 녹화 비활성(cap_record_en=false 또는 모든 채널 disabled) → skip
#   - 이미 재시작/kill 사이클 진행 중 → skip
# Escalation (사용자 escalation 정책: 정체 지속 시 단계적 강도 증가):
#   stall_cnt 1-2: kill_test.sh
#   stall_cnt 3-4: init_cam.sh (cooldown 무관, 정체는 cooldown보다 우선)
#   stall_cnt 5+ : reboot (file_chk_reboot=true 시)
CheckFinalArrival() {
    local final_dir="${final_path_cfg%/}"
    [ -d "$final_dir" ] || return 0

    # P0-1: RAM-only 모드에서는 SD 경로 검사 자체가 무의미
    if is_ram_only_mode; then
        final_stall_cnt=0
        _write_final_health "RAM_ONLY" 0
        return 0
    fi

    # P1-B: 녹화 비활성 시 트리거 안 함.
    # 메인 루프(L1124, L1129)와 동일 조건을 사용:
    #   - 모든 카메라 채널 disabled
    #   - capture 모드(cap_en=true)인데 capture.record=false
    # cap_record_en 단독 체크는 잘못된 가드 (일반 녹화 단말이 cap_en=false, cap_record_en=false 케이스에서 오작동).
    if [[ "$csi1_en" -eq 0 ]] && [[ "$csi2_en" -eq 0 ]]; then
        final_stall_cnt=0
        _write_final_health "REC_DISABLED" 0
        return 0
    fi
    if [[ "$cap_en" == *"$ENABLE_VAL"* && "$cap_record_en" != *"$ENABLE_VAL"* ]]; then
        final_stall_cnt=0
        _write_final_health "REC_DISABLED" 0
        return 0
    fi

    # P0-2: 이미 재시작/kill 사이클 진행 중이면 중복 호출 차단
    if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ] || [ -f /tmp/kill_flag ]; then
        _write_final_health "BUSY" 0
        return 0
    fi

    # 시작 직후 워밍업: 첫 녹화가 final에 도달할 시간 확보.
    # P2: rec_time*2 단독은 boundary case에 부족. file_check_delay (gstApp 첫 fragment 대기)
    # 와 startup_grace_extra_sec (앱 부팅 grace) 까지 포함하여 첫 post-warmup 사이클의
    # false STALL을 차단한다.
    local warmup_sec=$(( rec_time * 2 + ${file_check_delay:-10} + ${startup_grace_extra_sec:-10} ))
    if [ "$timer" -lt "$warmup_sec" ]; then
        _write_final_health "WARMUP" "$timer"
        return 0
    fi

    local window_min=$(( rec_min * 2 ))
    [ "$window_min" -lt 2 ] && window_min=2
    local window_sec=$(( window_min * 60 ))

    # P2-3: heartbeat 1차 검사 (가장 정확). MovePartFile 성공 시 갱신됨.
    if [ -f "$FINAL_HEARTBEAT_FILE" ]; then
        local hb_ts now_ts age
        hb_ts=$(cat "$FINAL_HEARTBEAT_FILE" 2>/dev/null | tr -d '\r\n')
        now_ts=$(date +%s)
        if [[ "$hb_ts" =~ ^[0-9]+$ ]]; then
            age=$(( now_ts - hb_ts ))
            if [ "$age" -ge 0 ] && [ "$age" -lt "$window_sec" ]; then
                final_stall_cnt=0
                _write_final_health "OK" "$age"
                return 0
            fi
        fi
    fi

    # 2차 fallback: find -mmin (heartbeat 없거나 깨졌을 때만)
    if find "$final_dir" -maxdepth 1 -type f -name "${vhl_name}_*" \
            -mmin -"$window_min" -print -quit 2>/dev/null | grep -q .; then
        # heartbeat가 없었다면 지금 만들어둔다 (다음 사이클부터 정확)
        date +%s > "$FINAL_HEARTBEAT_FILE" 2>/dev/null
        final_stall_cnt=0
        _write_final_health "OK_FB" 0
        return 0
    fi

    ((final_stall_cnt++))
    logger -p local0.emerg "[$KEY][$tag:$LINENO] FINAL STALL: no new ${vhl_name}_* in ${final_dir} for >${window_min}m (stall_cnt=$final_stall_cnt)"
    echo "NG" > "$FILE_CHECK"
    _write_final_health "STALL" "$final_stall_cnt"

    if [ "$final_stall_cnt" -le 2 ]; then
        logger -p local0.error "[$KEY][$tag:$LINENO] FINAL STALL escalate: kill_test.sh (stall_cnt=$final_stall_cnt)"
        /opt/pim/bin/kill_test.sh
    elif [ "$final_stall_cnt" -le 4 ]; then
        logger -p local0.error "[$KEY][$tag:$LINENO] FINAL STALL escalate: init_cam.sh (stall_cnt=$final_stall_cnt)"
        /opt/pim/bin/init_cam.sh
    else
        if [[ "$file_chk_reboot" == *"$ENABLE_VAL"* ]]; then
            logger -p local0.emerg "[$KEY][$tag:$LINENO] FINAL STALL persistent (stall_cnt=$final_stall_cnt) — reboot"
            sleep 1
            reboot
        else
            logger -p local0.notice "[$KEY][$tag:$LINENO] FINAL STALL persistent but file_chk_reboot=false — reset counter"
            final_stall_cnt=0
        fi
    fi
}

# Disk 사용량 체크
CheckDiskSpace() {
    # Panic watchdog: /dev/shm filesystem near-full → emergency evict regardless of cap state.
    # Last line of defense against tmpfs full (would block all subsequent .part writes).
    if is_ram_only_mode && [ -d "$final_path" ] && ram_fs_panic; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] /dev/shm panic threshold reached — emergency evict"
        emergency_evict_oldest_fragments "$final_path" \
            "${RAM_CAP_BYTES:-$RAM_CAP_BYTES_DEFAULT}"
    fi

    if ! is_ram_only_mode; then
        BackfillRamRecordingsToSd
    fi

    # SD OK: enforce retention against SD final path from config.
    if is_sd_ok; then
        if [ -n "$final_path_cfg" ] && [ -d "$final_path_cfg" ]; then
            enforce_sd_retention_if_needed "$final_path_cfg"
            update_sd_write_disable_flag "$final_path_cfg"
            # Apply runtime overrides immediately when CRIT flips SD write state.
            apply_storage_mode_overrides
            # P0-2: update_sd_write_disable_flag가 막 sd_write_disabled를 제거했을 수 있다.
            # 이 경우 위쪽 첫 backfill은 is_ram_only_mode=true 상태에서 skip 되어,
            # 같은 사이클의 CheckFinalArrival이 SD 모드로 실행되는데 RAM backlog가 그대로
            # 남아 false STALL이 발생할 수 있다. 모드 복구 후 한 번 더 시도하여 차단한다.
            if ! is_ram_only_mode; then
                BackfillRamRecordingsToSd
            fi
        fi
    fi

    # Enforce RAM cap ONLY in RAM-only mode
    if is_ram_only_mode && [ -d "$final_path" ]; then
        enforce_ram_cap_if_needed
    fi
    return 0
}

logger -p local0.emerg "[$KEY][$tag:$LINENO] cam-operate daemon start : Booting"
#/opt/pim/bin/automnt_sd_for_emmc_boot.sh /mnt/sd_cam &
modprobe rtc_ds1307
modprobe max9296 || logger -p local0.err "[$KEY][$tag:$LINENO] modprobe max9296 failed"
modprobe imx8-media-dev || logger -p local0.err "[$KEY][$tag:$LINENO] modprobe imx8-media-dev failed"
#/opt/pim/bin/start_cam.sh 20

FILE_="/tmp/start_video_time_chk"
#FILE_JSON=/root/shared_v/edgeconf_pim.json
FILE_JSON_=/root/shared_v/ord_vcm_conf.json
FILE_CHECK=/tmp/file_check
FLAG_PATH=/tmp
ENABLE_VAL="true"
DISABLE_VAL="false"
retry=0
retry_boot=0
retry_total=0
last_init_ts=0
final_stall_cnt=0
#touch $FILE_

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
force_edgeconf_app_to_gstapp "$FILE_JSON" || true

timer=0
mnt_path="/mnt/sd_cam"
tmp_path="/tmp"
start_f=0
curTimeEpoch=0
startTimeEpoch=0
diffEpoch=0
check_num=0
file_cnt=0
datetime=0
datetime_=0
file_check_delay=10
muxer=""
cap_en="false"
cap_record_en="false"
cap_rtsp_en="false"
startTime=""
startTime_=""
rec_time=0
rec_min=0
csi1_en=0
csi2_en=0
timestamp=0

GetConfig

if is_sd_ok; then
    logger -p local0.notice "[$KEY][$tag:$LINENO] sd flag is 1 or 2"
else
    logger -p local0.err "[$KEY][$tag:$LINENO] invalid sd flag or not exist"
    if [ "$tmp_path" != "/dev/shm" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] fallback tmp_path(runtime only): $tmp_path -> /dev/shm"
        tmp_path="/dev/shm"
    fi
fi

apply_storage_mode_overrides

if [ ! -d "$tmp_path" ]; then
    mkdir -p "$tmp_path"
fi

if [ ! -d "$sd_tmp_path" ]; then
    mkdir -p "$sd_tmp_path"
fi

if [ ! -d "$final_path" ]; then
    mkdir -p "$final_path"
fi

logger -p local0.info "[$KEY][$tag:$LINENO] /opt/pim/bin/start_cam.sh $app_delay"
/opt/pim/bin/start_cam.sh $app_delay
#rst_time=60
#StartApp start_cam.sh
#StartScript restart_app.sh

GetConfig_

logger -p local0.notice "[$KEY][$tag:$LINENO] ch0:$cam_ch0, ch1:$cam_ch1, ch2:$cam_ch2, ch3:$cam_ch3, srt:$srt_en, time_rec_en:$time_rec_en, vhl_name:$vhl_name, rec_time:$rec_time, rst_time:$rst_time, cap_en:$cap_en, mnt_path:$mnt_path, tmp_path:$tmp_path, sd_tmp_path:$sd_tmp_path, final_path:$final_path, app_delay:$app_delay, muxer:$muxer, file_check_delay:$file_check_delay file_chk_reboot:$file_chk_reboot"

while :
do

    check_num=0
    file_cnt=0

    if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then
        sleep 5
        timer=0
        continue
    fi

    if [ -f /tmp/kill_flag ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] kill_flag set"
        rm /tmp/kill_flag
        cat /dev/null > $FILE_
        timer=0
    fi

    # Disconnect handling: periodically re-init modules so that when cameras reconnect
    # we can resume normal file checks. No reboot in disconnect state.
    if maybe_init_cam_on_disconnect; then
        timer=0
        sleep 5
        continue
    fi

    cam_state_init

    if [ -f "$RECOVER_REQ_INIT_CAM" ]; then
        cam_disconnect_flag=$(get_cam_disconnect_flag)
        drv_disc_now=$(read_driver_disconnect)
        if (( cam_disconnect_flag == 0 )) && (( drv_disc_now == 0 )); then
            rm -f "$RECOVER_REQ_INIT_CAM"
            cam_clear_recovery
        elif [ "$drv_disc_now" -ne 0 ]; then
            logger -p local0.notice "[$KEY][$tag:$LINENO] skip recover_req init_cam: driver disconnect(0x$(printf '%x' $drv_disc_now))"
            rm -f "$RECOVER_REQ_INIT_CAM"
            cam_clear_recovery
        elif in_init_cooldown || cam_in_init_cooldown "$init_cooldown_sec"; then
            :
        else
            logger -p local0.error "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh because recover request"
            rm -f "$RECOVER_REQ_INIT_CAM"
            cam_clear_recovery
            /opt/pim/bin/init_cam.sh
            timer=0
            sleep 5
            continue
        fi
    fi

    # Driver load failure: retry init_cam, then reboot (unless disconnect).
    if ! modules_loaded; then
        cam_disconnect_flag=$(get_cam_disconnect_flag)
        logger -p local0.error "[$KEY][$tag:$LINENO] driver module not loaded (max9296/imx8_media_dev)"
        echo "NG" > $FILE_CHECK
        if (( cam_disconnect_flag == 0x0 )); then
            ((retry_boot++))
            retry_total=$(($retry+$retry_boot))
            if [ "$retry_total" -le 5 ]; then
                logger -p local0.error "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh because driver load fail ($retry/$retry_boot/$retry_total)"
                cam_request_recovery "driver_load_fail"
                /opt/pim/bin/init_cam.sh
            else
                logger -p local0.error "[$KEY][$tag:$LINENO] retry_total $retry_total is over (driver load fail)"
                if [[ "$file_chk_reboot" == *"$ENABLE_VAL"* ]]; then
                    logger -p local0.emerg "[$KEY][$tag:$LINENO] rebooting because driver load fail ($retry/$retry_boot/$retry_total)"
                    sleep 1
                    reboot
                else
                    logger -p local0.notice "[$KEY][$tag:$LINENO] retry count reset because file_check_reboot is not true"
                    retry=0
                    retry_boot=0
                    retry_total=0
                fi
            fi
        else
            logger -p local0.err "[$KEY][$tag:$LINENO] no retry/reboot because cam is disconnect($cam_disconnect_flag)"
        fi
        timer=0
        sleep 5
        continue
    fi

    if [[ "$time_rec_en" != *"$ENABLE_VAL"* ]]; then
        sleep 5
        continue
    fi

    if [[ "$cap_en" == *"$ENABLE_VAL"* && "$cap_record_en" != *"$ENABLE_VAL"* ]]; then
        sleep 5
        continue
    fi

    if [[ "$csi1_en" -eq 0 ]] && [[ "$csi2_en" -eq 0 ]]; then
        sleep 5
        continue
    fi

    # === 이벤트 기반: 완료된 세션 처리 (최적화: all_done 파일 존재 시만 호출) ===
    if compgen -G '/tmp/session_*.all_done' > /dev/null 2>&1; then
        ProcessCompletedSessions
    fi

    #if [ -e "$FILE_" ]; then
    startTime=$(cat $FILE_ 2>/dev/null| tr -d '\n' 2>/dev/null)
    #startTime=$(cat "$FILE_" 2>/dev/null | tr -d '\n' | sed 's/:[0-9][0-9]$/:00/')
	if [ -n "$startTime"  ]; then
        timer=0
        start_f=1
		curTimeEpoch=$(date "+%s")
		startTimeEpoch=$(date -d "$startTime" "+%s")
		diffEpoch=$(echo "$curTimeEpoch - $startTimeEpoch" |bc)
        #logger -p local0.info "[$KEY][$tag:$LINENO] start_video_time_:$startTime, cur_time:$(date '+%Y%m%d %H:%M:%S'), diff:$diffEpoch"
		if [ "$diffEpoch" -ge "$file_check_delay" ]; then
            logger -p local0.info "[$KEY][$tag:$LINENO] start_video_time_:$startTime, cur_time:$(date '+%Y%m%d %H:%M:%S'), diff:$diffEpoch"
            #timer=0
			cat /dev/null > $FILE_
			datetime=$(date -d "$startTime" "+%Y%m%d_%H%M%S")
            datetime_=$(date -d "$startTime" "+%Y%m%d_%H%M")
            drv_disc=$(read_driver_disconnect)
            enabled_chs=()
            disconnect_chs=()
            checked_chs=()
            missing_chs=()
            srt_status="disabled"
            [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] && enabled_chs+=("ch0")
            [[ "$cam_ch1" == *"$ENABLE_VAL"* ]] && enabled_chs+=("ch1")
            [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] && enabled_chs+=("ch2")
            [[ "$cam_ch3" == *"$ENABLE_VAL"* ]] && enabled_chs+=("ch3")
            [ $(( (drv_disc >> 0) & 1 )) -eq 1 ] && disconnect_chs+=("ch0")
            [ $(( (drv_disc >> 1) & 1 )) -eq 1 ] && disconnect_chs+=("ch1")
            [ $(( (drv_disc >> 2) & 1 )) -eq 1 ] && disconnect_chs+=("ch2")
            [ $(( (drv_disc >> 3) & 1 )) -eq 1 ] && disconnect_chs+=("ch3")

            if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] && [ $(( (drv_disc >> 0) & 1 )) -eq 0 ]; then
                ((check_num++))
                checked_chs+=("ch0")
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch0.${muxer}" ]; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch0.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch0*" > /dev/null; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch0* exist"
                    ((file_cnt++))
                else
                    missing_chs+=("ch0")
                fi
            fi


            if [[ "$cam_ch1" == *"$ENABLE_VAL"* ]] && [ $(( (drv_disc >> 1) & 1 )) -eq 0 ]; then
                ((check_num++))
                checked_chs+=("ch1")
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch1.${muxer}" ]; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch1.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch1*" > /dev/null; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch1* exist"
                    ((file_cnt++))
                else
                    missing_chs+=("ch1")
                fi
            fi

            if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] && [ $(( (drv_disc >> 2) & 1 )) -eq 0 ]; then
                ((check_num++))
                checked_chs+=("ch2")
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch2.${muxer}" ]; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch2.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch2*" > /dev/null; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch2* exist"
                    ((file_cnt++))
                else
                    missing_chs+=("ch2")
                fi
            fi

            if [[ "$cam_ch3" == *"$ENABLE_VAL"* ]] && [ $(( (drv_disc >> 3) & 1 )) -eq 0 ]; then
                ((check_num++))
                checked_chs+=("ch3")
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch3.${muxer}" ]; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch3.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch3*" > /dev/null; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch3* exist"
                    ((file_cnt++))
                else
                    missing_chs+=("ch3")
                fi
            fi

            if [[ "$srt_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*data.srt*" > /dev/null; then
                    logger -p local0.debug "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*data.srt* exist"
                    ((file_cnt++))
                    srt_status="ok"
                else
                    srt_status="miss"
                fi
            fi

            # === 기존 1분 이동 로직: .part 기반 로직으로 대체됨 ===
            # if [ "$mnt_path" != "$tmp_path" ]; then
            #     if [ -f /dev/shm/sd_mount_flag ] && grep -qE '^(1|2)$' /dev/shm/sd_mount_flag; then
            #         timestamp=$(date -d '1 min ago' '+%Y%m%d_%H%M')
            #         cmd="mv ${tmp_path}/*${vhl_name}_${timestamp}* ${mnt_path}/ 2>/dev/null"
            #         logger -p local0.notice "[$KEY][$tag:$LINENO] $cmd"
            #         eval "$cmd"
            #         if [ "$rec_min" -gt 1 ]; then
            #             timestamp=$(date -d "${rec_min} min ago" '+%Y%m%d_%H%M')
            #             cmd="mv ${tmp_path}/*${vhl_name}_${timestamp}* ${mnt_path}/ 2>/dev/null"
            #             logger -p local0.notice "[$KEY][$tag:$LINENO] $cmd"
            #             eval "$cmd"
            #         fi
            #     else
            #         logger -p local0.err "[$KEY][$tag:$LINENO] sd mount err...dont move ${tmp_path} to ${mnt_path}"
            #     fi
            # fi
            sync
            en_str=$(IFS=,; echo "${enabled_chs[*]}")
            disc_str=$(IFS=,; echo "${disconnect_chs[*]}")
            chk_str=$(IFS=,; echo "${checked_chs[*]}")
            miss_str=$(IFS=,; echo "${missing_chs[*]}")
			logger -p local0.debug "[$KEY][$tag:$LINENO] check_num:$check_num cnt:$file_cnt"
			if [ "$check_num" -ne "$file_cnt" ]; then
                logger -p local0.error "[$KEY][$tag:$LINENO] ${muxer},srt file chk fail: en=[${en_str}] disc=[${disc_str}] chk=[${chk_str}] miss=[${miss_str}] srt=[${srt_status}] ($retry/$retry_boot/$retry_total)"
                start_f=0
                echo "NG" > $FILE_CHECK
                cam_disconnect_flag=$(get_cam_disconnect_flag)
                if in_init_cooldown || cam_in_init_cooldown "$init_cooldown_sec"; then
                    logger -p local0.notice "[$KEY][$tag:$LINENO] skip retry: in init cooldown ($retry/$retry_boot/$retry_total)"
                elif (( cam_disconnect_flag == 0x0 )); then
                    ((retry++))
                    retry_total=$(($retry+$retry_boot))
                    if [ "$retry_total" -le 3 ]; then
                        logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh ($retry/$retry_boot/$retry_total)"
                        /opt/pim/bin/kill_test.sh
                    elif [ "$retry_total" -le 5 ]; then
                        logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh ($retry/$retry_boot/$retry_total)"
                        cam_request_recovery "file_check_fail"
                        /opt/pim/bin/init_cam.sh
                    else
                        logger -p local0.error "[$KEY][$tag:$LINENO] retry total $retry_total is over"
                        if [[ "$file_chk_reboot" == *"$ENABLE_VAL"* ]]; then
                            logger -p local0.emerg "[$KEY][$tag:$LINENO] rebooting because file check fail ($retry/$retry_boot/$retry_total)"
                            sleep 1
                            #creboot
                            reboot
                        else
                            logger -p local0.notice "[$KEY][$tag:$LINENO] retry count reset because file_check_reboot is not true"
                            retry=0
                            retry_boot=0
                            retry_total=0
                        fi
                    fi
                else
                    drv_disc_now=$(read_driver_disconnect)
                    if [ "$drv_disc_now" -ne 0 ]; then
                        logger -p local0.notice "[$KEY][$tag:$LINENO] skip init_cam: driver disconnect(0x$(printf '%x' $drv_disc_now)), file check fail expected"
                    else
                        logger -p local0.err  "[$KEY][$tag:$LINENO] cam disconnect($cam_disconnect_flag): /opt/pim/bin/init_cam.sh"
                        if ! in_init_cooldown && ! cam_in_init_cooldown "$init_cooldown_sec"; then
                            # periodic init_cam 간격 추적을 위해 last_init 갱신
                            local now_ts
                            now_ts=$(date +%s)
                            local first_seen_val
                            first_seen_val=$(cat "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null | awk -F',' '{print $1}')
                            [[ ! "$first_seen_val" =~ ^[0-9]+$ ]] && first_seen_val=$now_ts
                            printf "%s,%s" "$first_seen_val" "$now_ts" > "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null
                            /opt/pim/bin/init_cam.sh
                        fi
                    fi
                fi
			else
				logger -p local0.info "[$KEY][$tag:$LINENO] ${muxer},srt file chk ok: en=[${en_str}] disc=[${disc_str}] chk=[${chk_str}] srt=[${srt_status}]"
				retry=0
                retry_boot=0
                retry_total=0
                echo "OK" > $FILE_CHECK
			fi
		fi
    else
        if [ "$timer" -ge $((rec_time+file_check_delay)) ]; then
            logger -p local0.error "[$KEY][$tag:$LINENO start_f init beacause file not create"
            start_f=0
        fi
    fi

    if [ "$start_f" -eq 0 ]; then
        if [ "$timer" -ge "$rst_time" ]; then 
            logger -p local0.error "[$KEY][$tag:$LINENO] $app all file not create($timer >= $rst_time), $FILE_:$startTime"
            timer=0
            start_f=0
            if [ "$csi1_en" -eq 0 ] && [ "$csi2_en" -eq 0 ]; then
                logger -p local0.error "[$KEY][$tag:$LINENO] all channel disabled at $FILE_JSON"
                continue;
            fi

            echo "NG" > $FILE_CHECK
            cam_disconnect_flag=$(get_cam_disconnect_flag)
            if in_init_cooldown || cam_in_init_cooldown "$init_cooldown_sec"; then
                logger -p local0.notice "[$KEY][$tag:$LINENO] skip retry_boot: in init cooldown ($retry/$retry_boot/$retry_total)"
            elif (( cam_disconnect_flag == 0x0 )); then
                ((retry_boot++))
                retry_total=$(($retry+$retry_boot))
                if [ "$retry_total" -le 2 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh ($retry/$retry_boot/$retry_total)"
                    /opt/pim/bin/kill_test.sh
                elif [ "$retry_total" -le 4 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh ($retry/$retry_boot/$retry_total)"
                    cam_request_recovery "startup_fail"
                    /opt/pim/bin/init_cam.sh
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] retry_total $retry_total is over"
                    if [[ "$file_chk_reboot" == *"$ENABLE_VAL"* ]]; then
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] rebooting because all file not create ($retry/$retry_boot/$retry_total)"
                        sleep 1
                        reboot
                    else
                        logger -p local0.notice "[$KEY][$tag:$LINENO] retry count reset because file_check_reboot is not true"
                        retry=0
                        retry_boot=0
                        retry_total=0
                    fi
                fi
            else
                local drv_disc
                drv_disc=$(read_driver_disconnect)
                if (( drv_disc != 0 )); then
                    logger -p local0.notice "[$KEY][$tag:$LINENO] cam disconnect($cam_disconnect_flag) drv_disc=$drv_disc: skip init_cam (periodic handles recovery)"
                else
                    logger -p local0.err  "[$KEY][$tag:$LINENO] cam disconnect($cam_disconnect_flag): /opt/pim/bin/init_cam.sh"
                    if ! in_init_cooldown && ! cam_in_init_cooldown "$init_cooldown_sec"; then
                        # periodic init_cam 간격 추적을 위해 last_init 갱신
                        local now_ts
                        now_ts=$(date +%s)
                        local first_seen_val
                        first_seen_val=$(cat "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null | awk -F',' '{print $1}')
                        [[ ! "$first_seen_val" =~ ^[0-9]+$ ]] && first_seen_val=$now_ts
                        printf "%s,%s" "$first_seen_val" "$now_ts" > "$DISCONNECT_INIT_CAM_STATE_FILE" 2>/dev/null
                        /opt/pim/bin/init_cam.sh
                    fi
                fi
            fi
	    fi
    fi

    # === 주기적 정리 작업 (60초마다) ===
    if [ $((timer % 60)) -eq 0 ]; then
        # IMPORTANT: Do NOT reload JSON while running.
        # We only apply runtime overrides based on SD state (OK/BAD) and flags.
        apply_storage_mode_overrides
        mkdir -p "$tmp_path" "$sd_tmp_path" "$final_path" 2>/dev/null
        CleanupStalePartFiles
        CheckDiskSpace
        CheckFinalArrival
    fi

    sleep 2
    ((timer+=2))
    #GetConfig
    #logger -p local0.notice "[$KEY][$tag:$LINENO] timer:$timer"
done

logger -p local0.notice "[$KEY][$tag:$LINENO] cam-operate stop"
