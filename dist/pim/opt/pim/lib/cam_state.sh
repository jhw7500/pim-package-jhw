#!/bin/bash

STATE_FILE="/tmp/cam_state.json"
RECOVERY_FILE="/tmp/cam_recovery.json"
LOCK_FILE="/tmp/cam_op_lock"

cam_state_init() {
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" << 'EOF'
{
  "timestamp": 0,
  "state": "healthy",
  "streak": 0,
  "last_init_ts": 0,
  "last_start_ts": 0,
  "channels": {
    "ch0": {"error": false, "last_ok": 0},
    "ch1": {"error": false, "last_ok": 0},
    "ch2": {"error": false, "last_ok": 0},
    "ch3": {"error": false, "last_ok": 0}
  }
}
EOF
    fi
}

cam_state_get() {
    local key="$1"
    local default="${2:-0}"
    local result
    result=$(jq -r "$key" "$STATE_FILE" 2>/dev/null)
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "$default"
    else
        echo "$result"
    fi
}

cam_state_set() {
    local key="$1"
    local value="$2"
    local tmp="${STATE_FILE}.tmp.$$"
    
    jq "$key = $value" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

cam_state_touch() {
    cam_state_set '.timestamp' "$(date +%s)"
}

cam_in_startup_grace() {
    local grace_sec="${1:-10}"
    local start_ts=$(cam_state_get '.last_start_ts')
    local now=$(date +%s)
    
    [ "$start_ts" -gt 0 ] && [ $((now - start_ts)) -lt "$grace_sec" ]
}

cam_in_init_cooldown() {
    local cooldown_sec="${1:-40}"
    local init_ts=$(cam_state_get '.last_init_ts')
    local now=$(date +%s)
    
    [ "$init_ts" -gt 0 ] && [ $((now - init_ts)) -lt "$cooldown_sec" ]
}

cam_get_state() {
    cam_state_get '.state' '"healthy"'
}

cam_set_state() {
    local new_state="$1"
    
    case "$new_state" in
        healthy|degraded|recovering|failed)
            cam_state_set '.state' "\"$new_state\""
            cam_state_touch
            ;;
        *)
            logger -p local0.err "[CAM_STATE] invalid state: $new_state"
            return 1
            ;;
    esac
}

cam_inc_streak() {
    local current=$(cam_state_get '.streak')
    cam_state_set '.streak' $((current + 1))
    cam_state_touch
    
    if [ $((current + 1)) -ge 2 ]; then
        cam_set_state "degraded"
    fi
}

cam_reset_streak() {
    cam_state_set '.streak' 0
    cam_set_state "healthy"
    cam_state_touch
}

cam_channel_error() {
    local ch="$1"
    cam_state_set ".channels.ch${ch}.error" true
    cam_state_set ".channels.ch${ch}.last_ok" "$(date +%s)"
}

cam_channel_clear() {
    local ch="$1"
    cam_state_set ".channels.ch${ch}.error" false
}

cam_has_channel_error() {
    local errors=$(jq '[.channels[].error] | any' "$STATE_FILE" 2>/dev/null)
    [ "$errors" = "true" ]
}

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

cam_record_init() {
    cam_state_set '.last_init_ts' "$(date +%s)"
    cam_reset_streak
    cam_set_state "recovering"
}

cam_record_start() {
    cam_state_set '.last_start_ts' "$(date +%s)"
}

cam_reset_state() {
    cam_set_state "healthy"
    cam_reset_streak
    for ch in 0 1 2 3; do
        cam_channel_clear "$ch"
    done
    cam_state_touch
}
