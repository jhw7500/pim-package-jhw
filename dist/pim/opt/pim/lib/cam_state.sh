#!/bin/bash
# cam_state — 파일 기반 키-값 저장소 (jq 제거, CPU 최적화)
# 모든 상태를 /tmp/cam_state/ 디렉토리 내 개별 파일로 관리

STATE_DIR="/tmp/cam_state"
RECOVERY_FILE="/tmp/cam_recovery.json"
LOCK_FILE="/tmp/cam_op_lock"

# ─────────────────────────────────────────────
# MAX9296 RX3(0x002F) — 링크별 상태
# ─────────────────────────────────────────────
#  bit6 SYNC_LOCKED_B / bit5 WBLOCK_B / bit4 FAILLOCK_B
#  bit2 SYNC_LOCKED_A / bit1 WBLOCK_A / bit0 FAILLOCK_A
#
# FAILLOCK 은 Read-Clear 다(실측: 0x01 → 0x00 → 0x00). 링크가 계속 죽어 있어도
# 두 번째 읽기부터 0이라 레벨 신호로 못 쓴다. 그래서 판정에도 표기에도 쓰지 않는다.
#
# SYNC_LOCKED/WBLOCK 은 RO 라 read-clear 가 아니고 런타임 이탈에서 링크별로 정확히
# 갈린다(실측: 둘 다 연결 0x66 → ch1 제거 → 0x60). 둘이 모두 서야 그 링크를 살아
# 있는 것으로 본다. 부팅 시점 부재에서는 양 링크가 다 0이라 구분되지 않는다.
#
# 니블 ↔ 채널: 하위(Link A) = 홀수 채널(ch1/ch3), 상위(Link B) = 짝수(ch0/ch2).
# 드라이버 단일채널 테이블의 LINK_CFG 선택에서 나오며 ch1 제거 실측과 일치한다.
#
# chk_cam_connect.sh 와 BG_Check_for_pim.sh 가 함께 쓴다. 두 벌로 두면 갈라지므로
# 여기 한 곳에만 둔다.
RX3_LINK_A_UP=0x06    # SYNC_LOCKED_A | WBLOCK_A
RX3_LINK_B_UP=0x60    # SYNC_LOCKED_B | WBLOCK_B

# RX3 를 그 자리에서 읽어 링크 상태를 문자열로 돌려준다. 캐시하지 않는다 —
# 찍히는 값은 항상 호출 시점의 실측이어야 한다(드라이버 link_status 는 stale 이다).
#
# both_down 의 해석 주의: 부팅 시점 부재도, 두 카메라가 다 빠진 경우도 같은 값이다.
# 즉 both_down 은 채널을 지목하지 못한다. 한쪽만 내려간 경우에만 귀속에 쓸 수 있다.
#
# $1=i2c adapter (2 → ch0/ch1, 1 → ch2/ch3)
# 출력: "<원시값>/<ok|chN_down|both_down>" 또는 읽기 실패 시 "NA/NA"
read_rx3_links() {
    local raw val base a b
    raw=$(i2ctransfer -f -y -a "$1" w2@0x48 0x00 0x2f r1 2>/dev/null \
          | grep -oE '0[xX][0-9a-fA-F]+' | head -1)
    [ -n "$raw" ] || { printf 'NA/NA'; return; }
    val=$(( raw )); a=0; b=0
    base=0; [ "$1" = "1" ] && base=2
    [ $(( val & RX3_LINK_A_UP )) -eq $(( RX3_LINK_A_UP )) ] && a=1
    [ $(( val & RX3_LINK_B_UP )) -eq $(( RX3_LINK_B_UP )) ] && b=1
    if   [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then printf '%s/ok' "$raw"
    elif [ "$a" -eq 0 ] && [ "$b" -eq 0 ]; then printf '%s/both_down' "$raw"
    elif [ "$a" -eq 0 ]; then printf '%s/ch%d_down' "$raw" "$((base + 1))"
    else                      printf '%s/ch%d_down' "$raw" "$base"
    fi
}

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
