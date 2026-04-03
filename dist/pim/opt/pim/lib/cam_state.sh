#!/bin/bash
# cam_state — 파일 기반 키-값 저장소 (jq 제거, CPU 최적화)
# 모든 상태를 /tmp/cam_state/ 디렉토리 내 개별 파일로 관리

STATE_DIR="/tmp/cam_state"
RECOVERY_FILE="/tmp/cam_recovery.json"
LOCK_FILE="/tmp/cam_op_lock"

# ─────────────────────────────────────────────
# 내부 헬퍼
# ─────────────────────────────────────────────
_cs_read() {
    cat "${STATE_DIR}/$1" 2>/dev/null
}

_cs_write() {
    printf '%s' "$2" > "${STATE_DIR}/$1"
}

# ─────────────────────────────────────────────
# 초기화
# ─────────────────────────────────────────────
cam_state_init() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "${STATE_DIR}/channels" "${STATE_DIR}/recording"
        _cs_write timestamp 0
        _cs_write state healthy
        _cs_write streak 0
        _cs_write last_init_ts 0
        _cs_write last_start_ts 0
        for ch in 0 1 2 3; do
            _cs_write "channels/ch${ch}_error" false
            _cs_write "channels/ch${ch}_last_ok" 0
        done
        _cs_write recording/start_video_time_actual ""
        _cs_write recording/start_video_time ""
        _cs_write recording/start_video_time_chk ""
        _cs_write recording/start_video_time_cpy ""
        _cs_write recording/start_video_time_vib ""
    fi

    cam_recording_sync_schema
}

# ─────────────────────────────────────────────
# 범용 get/set (내부 전용 — 외부 호출자 없음)
# key는 파일 경로 형식: 'streak', 'channels/ch0_error' 등
# ─────────────────────────────────────────────
cam_state_get() {
    local key="$1"
    local default="${2:-0}"
    local result
    result=$(_cs_read "$key")
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "$default"
    else
        echo "$result"
    fi
}

cam_state_set() {
    _cs_write "$1" "$2"
}

cam_state_touch() {
    _cs_write timestamp "$(date +%s)"
}

# ─────────────────────────────────────────────
# recording 스키마
# ─────────────────────────────────────────────
cam_recording_schema_ready() {
    [ -f "${STATE_DIR}/recording/start_video_time_actual" ] &&
    [ -f "${STATE_DIR}/recording/start_video_time" ] &&
    [ -f "${STATE_DIR}/recording/start_video_time_chk" ] &&
    [ -f "${STATE_DIR}/recording/start_video_time_cpy" ] &&
    [ -f "${STATE_DIR}/recording/start_video_time_vib" ]
}

cam_recording_sync_schema() {
    if cam_recording_schema_ready; then
        return 0
    fi
    mkdir -p "${STATE_DIR}/recording"
    for k in start_video_time_actual start_video_time start_video_time_chk start_video_time_cpy start_video_time_vib; do
        [ -f "${STATE_DIR}/recording/$k" ] || _cs_write "recording/$k" ""
    done
}

cam_recording_set() {
    local key="$1"
    local value="$2"
    cam_state_init
    _cs_write "recording/$key" "$value"
}

# ─────────────────────────────────────────────
# 상태 머신
# ─────────────────────────────────────────────
cam_in_startup_grace() {
    local grace_sec="${1:-10}"
    local start_ts=$(_cs_read last_start_ts)
    local now=$(date +%s)
    start_ts="${start_ts:-0}"
    [ "$start_ts" -gt 0 ] && [ $((now - start_ts)) -lt "$grace_sec" ]
}

cam_in_init_cooldown() {
    local cooldown_sec="${1:-40}"
    local init_ts=$(_cs_read last_init_ts)
    local now=$(date +%s)
    init_ts="${init_ts:-0}"
    [ "$init_ts" -gt 0 ] && [ $((now - init_ts)) -lt "$cooldown_sec" ]
}

cam_get_state() {
    local s=$(_cs_read state)
    echo "${s:-healthy}"
}

cam_set_state() {
    local new_state="$1"
    case "$new_state" in
        healthy|degraded|recovering|failed)
            _cs_write state "$new_state"
            cam_state_touch
            ;;
        *)
            logger -p local0.err "[CAM_STATE] invalid state: $new_state"
            return 1
            ;;
    esac
}

cam_inc_streak() {
    local current=$(_cs_read streak)
    current="${current:-0}"
    current=$((current + 1))
    _cs_write streak "$current"
    cam_state_touch
    if [ "$current" -ge 2 ]; then
        cam_set_state "degraded"
    fi
}

cam_reset_streak() {
    _cs_write streak 0
    cam_set_state "healthy"
    cam_state_touch
}

# ─────────────────────────────────────────────
# 채널 에러
# ─────────────────────────────────────────────
cam_channel_error() {
    local ch="$1"
    _cs_write "channels/ch${ch}_error" true
    _cs_write "channels/ch${ch}_last_ok" "$(date +%s)"
}

cam_channel_clear() {
    local ch="$1"
    _cs_write "channels/ch${ch}_error" false
}

cam_has_channel_error() {
    for ch in 0 1 2 3; do
        [ "$(_cs_read "channels/ch${ch}_error")" = "true" ] && return 0
    done
    return 1
}

# ─────────────────────────────────────────────
# 복구 (recovery는 빈도 낮으므로 jq 유지)
# ─────────────────────────────────────────────
cam_request_recovery() {
    local reason="$1"
    local now=$(date +%s)
    cat > "$RECOVERY_FILE" << EOF
{
  "requested_at": $now,
  "reason": "$reason",
  "attempts": 0,
  "max_attempts": 5
}
EOF
}

cam_recovery_requested() {
    [ -f "$RECOVERY_FILE" ]
}

cam_recovery_reason() {
    jq -r '.reason // "unknown"' "$RECOVERY_FILE" 2>/dev/null
}

cam_inc_recovery_attempt() {
    local tmp="${RECOVERY_FILE}.tmp.$$"
    jq '.attempts += 1' "$RECOVERY_FILE" > "$tmp" && mv "$tmp" "$RECOVERY_FILE"
}

cam_clear_recovery() {
    rm -f "$RECOVERY_FILE"
}

cam_recovery_exhausted() {
    local attempts=$(jq -r '.attempts // 0' "$RECOVERY_FILE" 2>/dev/null)
    local max=$(jq -r '.max_attempts // 5' "$RECOVERY_FILE" 2>/dev/null)
    [ "$attempts" -ge "$max" ]
}

# ─────────────────────────────────────────────
# 락
# ─────────────────────────────────────────────
cam_lock() {
    local op="$1"
    if [ -f "$LOCK_FILE" ]; then
        local locked_op=$(cat "$LOCK_FILE" 2>/dev/null)
        logger -p local0.info "[CAM_STATE] lock held by: $locked_op"
        return 1
    fi
    echo "$op" > "$LOCK_FILE"
    return 0
}

cam_unlock() {
    rm -f "$LOCK_FILE"
}

# ─────────────────────────────────────────────
# 복합 동작
# ─────────────────────────────────────────────
cam_record_init() {
    _cs_write last_init_ts "$(date +%s)"
    cam_reset_streak
    cam_set_state "recovering"
}

cam_record_start() {
    _cs_write last_start_ts "$(date +%s)"
    cam_recording_set 'start_video_time_actual' ''
}

cam_reset_state() {
    cam_set_state "healthy"
    cam_reset_streak
    for ch in 0 1 2 3; do
        cam_channel_clear "$ch"
    done
    cam_state_touch
}
