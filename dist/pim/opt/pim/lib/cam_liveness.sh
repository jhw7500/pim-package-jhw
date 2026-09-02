#!/usr/bin/env bash
# Bounded process liveness and ordered stop under the cam-operate owner.

PIM_LIB="${PIM_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PIM_BIN="${PIM_BIN:-$(cd "$PIM_LIB/../bin" && pwd)}"
PIM_CAMERA_SYSTEMCTL="${PIM_CAMERA_SYSTEMCTL:-systemctl}"
PIM_CAMERA_KILL="${PIM_CAMERA_KILL:-kill}"
PIM_CAMERA_VCM_COMMAND="${PIM_CAMERA_VCM_COMMAND:-vcm}"
PIM_CAMERA_V4L2_CTL="${PIM_CAMERA_V4L2_CTL:-v4l2-ctl}"
PIM_CAMERA_DEVICE_ROOT="${PIM_CAMERA_DEVICE_ROOT:-/dev}"
PIM_CAMERA_BG_FLAG_FILE="${PIM_CAMERA_BG_FLAG_FILE:-/tmp/bg_chk_flag.bin}"
PIM_CAMERA_INIT_FLAG="${PIM_CAMERA_INIT_FLAG:-/tmp/init_cam_flag}"
PIM_CAMERA_RESTART_FLAG="${PIM_CAMERA_RESTART_FLAG:-/tmp/restart_flag}"
PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD="${PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD:-5}"
PIM_CAMERA_LIVENESS_GRACE_SEC="${PIM_CAMERA_LIVENESS_GRACE_SEC:-12}"
PIM_CAMERA_LIVENESS_GRACE_BYPASSES="${PIM_CAMERA_LIVENESS_GRACE_BYPASSES:-2}"
PIM_CAMERA_STOP_WAIT_SEC="${PIM_CAMERA_STOP_WAIT_SEC:-5}"
PIM_CAMERA_LIVENESS_START_WAIT_SEC="${PIM_CAMERA_LIVENESS_START_WAIT_SEC:-1}"
PIM_CAMERA_LIVENESS_QUIESCED="${PIM_CAMERA_LIVENESS_QUIESCED:-0}"
PIM_CAMERA_LIVENESS_GRACE_UNTIL="${PIM_CAMERA_LIVENESS_GRACE_UNTIL:-0}"
PIM_CAMERA_LIVENESS_GRACE_USES="${PIM_CAMERA_LIVENESS_GRACE_USES:-0}"

if ! declare -F cam_owner_assert >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$PIM_LIB/cam_recovery.sh"
fi
if ! declare -F cam_validate_runtime >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$PIM_LIB/cam_recovery_actions.sh"
fi
if ! declare -F cam_mark_degraded >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$PIM_LIB/cam_operate_control.sh"
fi

_cl_now() {
    if [ -n "${PIM_CAMERA_LIVENESS_NOW:-}" ]; then printf '%s\n' "$PIM_CAMERA_LIVENESS_NOW"; else date +%s; fi
}

_cl_stop_event() { :; }

cam_liveness_init() {
    PIM_CAMERA_LIVENESS_QUIESCED=0
    PIM_CAMERA_LIVENESS_GRACE_UNTIL=0
    PIM_CAMERA_LIVENESS_GRACE_USES=0
    export PIM_CAMERA_LIVENESS_QUIESCED PIM_CAMERA_LIVENESS_GRACE_UNTIL PIM_CAMERA_LIVENESS_GRACE_USES
}

cam_liveness_quiesce() {
    PIM_CAMERA_LIVENESS_QUIESCED=1
    export PIM_CAMERA_LIVENESS_QUIESCED
    _cl_stop_event liveness_quiesced
}

_cl_active_guard_locked() {
    local owner
    owner=$(_cr_owner_json) || return 69
    _cr_owner_snapshot_live "$owner" "${PIM_CAMERA_OWNER_INVOCATION:-}" "${PIM_CAMERA_OWNER_TOKEN:-}" || return 69
    _cr_owner_snapshot_lifecycle_in "$owner" ACTIVE || return 69
    [ "$PIM_CAMERA_LIVENESS_QUIESCED" != 1 ] || return 69
    [ ! -e "$(_cr_pending_file)" ] && [ ! -e "$(_cr_active_file)" ] || return 75
    cam_validate_runtime "$PIM_CAMERA_RUNTIME_JSON" || return $?
}

_cl_active_guard() { _cr_lock_call _cl_active_guard_locked; }

_cl_process_status() {
    local name=$1 rc
    if pgrep -x "$name" >/dev/null 2>&1; then return 0; else rc=$?; fi
    [ "$rc" -eq 1 ] && return 1
    return "$rc"
}

_cl_ord_status() {
    local status rc
    if status=$("$PIM_CAMERA_SYSTEMCTL" is-active ord-operate.service 2>/dev/null); then rc=0; else rc=$?; fi
    [ "$rc" -eq 0 ] && [ "$status" = active ] && return 0
    case "$status" in inactive|failed) return 1;; esac
    return 2
}

_cl_restart_ord_locked() {
    _cl_active_guard_locked || return $?
    "$PIM_CAMERA_SYSTEMCTL" restart ord-operate.service
}
cam_liveness_restart_ord() { _cr_lock_call _cl_restart_ord_locked; }

_cl_restart_vcm_locked() {
    local path=$1
    _cl_active_guard_locked || return $?
    (
        exec {fd}>&-
        exec "$path"
    ) &
}
cam_liveness_restart_vcm() {
    local path
    path=$(command -v "$PIM_CAMERA_VCM_COMMAND") || return 127
    _cr_lock_call _cl_restart_vcm_locked "$path" || return $?
    _cl_wait_named_process vcm "$PIM_CAMERA_LIVENESS_START_WAIT_SEC"
}

_cl_wait_named_process() {
    local name=$1 timeout=$2 elapsed=0 rc
    [[ $timeout =~ ^[0-9]+$ ]] || timeout=1
    while :; do
        rc=0; _cl_process_status "$name" || rc=$?
        [ "$rc" -ne 0 ] || return 0
        [ "$rc" -eq 1 ] || return "$rc"
        [ "$elapsed" -lt "$timeout" ] || return 1
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

cam_liveness_note_failure() {
    local target=$1
    _cl_active_guard || return $?
    cam_mark_degraded liveness_start_failed "$target" false
}

_cl_handle_operation_flags() {
    local now
    if [ -e "$PIM_CAMERA_RESTART_FLAG" ]; then
        now=$(_cl_now) || return 1
        PIM_CAMERA_LIVENESS_GRACE_UNTIL=$((now + PIM_CAMERA_LIVENESS_GRACE_SEC))
        PIM_CAMERA_LIVENESS_GRACE_USES=0
        export PIM_CAMERA_LIVENESS_GRACE_UNTIL PIM_CAMERA_LIVENESS_GRACE_USES
        return 1
    fi
    [ ! -e "$PIM_CAMERA_INIT_FLAG" ] || return 1
    return 0
}

_cl_disconnect_clear() {
    local raw
    [ -e "$PIM_CAMERA_BG_FLAG_FILE" ] || return 0
    raw=$(tr -d '\r\n' < "$PIM_CAMERA_BG_FLAG_FILE") || return 1
    [[ $raw =~ ^[0-9]+$ ]] || return 1
    [ $((raw & 15)) -eq 0 ]
}

_cl_video_present() {
    [ -e "$PIM_CAMERA_DEVICE_ROOT/video3" ] || [ -e "$PIM_CAMERA_DEVICE_ROOT/video4" ]
}

_cl_subdev_ready() {
    local command_path ch enabled subdev ctrl tried=0 now
    command_path=$(command -v "$PIM_CAMERA_V4L2_CTL" 2>/dev/null) || return 0
    for ch in 0 1 2 3; do
        enabled=$(jq -r --argjson ch "$ch" '
          if $ch < 2 then .VHL_CAM.i2c2["ch\($ch)"].enable // false
          else .VHL_CAM.i2c1["ch\($ch)"].enable // false end
        ' "$PIM_CAMERA_RUNTIME_JSON") || return 1
        [ "$enabled" = true ] || continue
        tried=1
        if [ "$ch" -lt 2 ]; then
            subdev=$(jq -r '.VHL_CAM.v4l_map.csi0_subdev // .VHL_CAM.v4l_map.csi0_video // .VHL_CAM.device_map.csi0_subdev // .VHL_CAM.device_map.csi0_video // 2' "$PIM_CAMERA_RUNTIME_JSON") || return 1
        else
            subdev=$(jq -r '.VHL_CAM.v4l_map.csi1_subdev // .VHL_CAM.v4l_map.csi1_video // .VHL_CAM.device_map.csi1_subdev // .VHL_CAM.device_map.csi1_video // 3' "$PIM_CAMERA_RUNTIME_JSON") || return 1
        fi
        [[ $subdev =~ ^[0-9]+$ ]] || return 1
        ctrl="ae_on_ch$ch"
        "$command_path" -d "$PIM_CAMERA_DEVICE_ROOT/v4l-subdev$subdev" --get-ctrl="$ctrl" >/dev/null 2>&1 && return 0
    done
    [ "$tried" -eq 1 ] || return 0
    now=$(_cl_now) || return 1
    if [ "$now" -le "$PIM_CAMERA_LIVENESS_GRACE_UNTIL" ] && [ "$PIM_CAMERA_LIVENESS_GRACE_USES" -lt "$PIM_CAMERA_LIVENESS_GRACE_BYPASSES" ]; then
        PIM_CAMERA_LIVENESS_GRACE_USES=$((PIM_CAMERA_LIVENESS_GRACE_USES + 1))
        export PIM_CAMERA_LIVENESS_GRACE_USES
        return 0
    fi
    return 1
}

cam_liveness_gstapp_gate() {
    local enabled
    _cl_active_guard || return $?
    enabled=$(jq -r '[.VHL_CAM.i2c2.ch0.enable // false,.VHL_CAM.i2c2.ch1.enable // false,.VHL_CAM.i2c1.ch2.enable // false,.VHL_CAM.i2c1.ch3.enable // false] | any(. == true)' "$PIM_CAMERA_RUNTIME_JSON") || return 64
    [ "$enabled" = true ] || return 1
    _cl_disconnect_clear || return 1
    _cl_video_present || return 1
    _cl_subdev_ready
}

_cl_gstapp_failures() {
    local state
    [ -e "$(_cr_state_file)" ] || { printf '0\n'; return 0; }
    state=$(cat "$(_cr_state_file)" 2>/dev/null) || return 70
    _cr_state_valid <<<"$state" || return 70
    jq -r '.actions.gstapp_restart.consecutive_failures' <<<"$state"
}

_cl_request_gstapp_recovery() {
    local failures action=gstapp_restart
    failures=$(_cl_gstapp_failures) || return $?
    [[ $PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD =~ ^[0-9]+$ ]] || return 64
    [ "$failures" -lt "$PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD" ] || action=module_reload
    cam_request_submit "$action" liveness "gstapp process absent" >/dev/null
}

cam_liveness_tick() {
    local rc app
    _cl_active_guard || return 0
    _cl_handle_operation_flags || return 0

    rc=0; _cl_ord_status || rc=$?
    case "$rc" in
        0) ;;
        1)
            rc=0; cam_liveness_restart_ord || rc=$?
            if [ "$rc" -ne 0 ]; then cam_liveness_note_failure ord || return $?; return "$rc"; fi
            ;;
        *) return 0 ;;
    esac

    rc=0; _cl_process_status vcm || rc=$?
    case "$rc" in
        0) ;;
        1)
            rc=0; cam_liveness_restart_vcm || rc=$?
            if [ "$rc" -ne 0 ]; then cam_liveness_note_failure vcm || return $?; return "$rc"; fi
            ;;
        *) return 0 ;;
    esac

    app=$(cam_runtime_app "$PIM_CAMERA_RUNTIME_JSON") || return 0
    rc=0; _cl_process_status "$app" || rc=$?
    [ "$rc" -ne 0 ] || return 0
    [ "$rc" -eq 1 ] || return 0
    cam_liveness_gstapp_gate || return 0
    _cl_active_guard || return 0
    _cl_request_gstapp_recovery
}

_cl_owner_matches_context() {
    local owner=$1 key expected actual
    _cr_owner_schema <<<"$owner" || return 69
    for key in boot_id invocation_id pid proc_start_time token created_at; do
        expected=$(jq -r --arg key "$key" '.[$key]' <<<"$owner") || return 69
        case "$key" in
            boot_id) actual=${PIM_CAMERA_OWNER_BOOT_ID:-} ;;
            invocation_id) actual=${PIM_CAMERA_OWNER_INVOCATION:-} ;;
            pid) actual=${PIM_CAMERA_OWNER_PID:-} ;;
            proc_start_time) actual=${PIM_CAMERA_OWNER_PROC_START_TIME:-} ;;
            token) actual=${PIM_CAMERA_OWNER_TOKEN:-} ;;
            created_at) actual=${PIM_CAMERA_OWNER_CREATED_AT:-} ;;
        esac
        [ -n "$actual" ] && [ "$expected" = "$actual" ] || return 69
    done
}

_cl_capture_owner_context() {
    local allow_adopt=${1:-0} owner
    [ -e "$(_cr_owner_file)" ] || return 0
    owner=$(_cr_owner_json) || return 69
    _cr_owner_snapshot_live "$owner" || return 69
    if [ -n "${PIM_CAMERA_OWNER_INVOCATION:-}" ]; then
        _cl_owner_matches_context "$owner" || return 69
        return 0
    fi
    [ "$allow_adopt" = 1 ] || return 69
    PIM_CAMERA_OWNER_BOOT_ID=$(jq -r .boot_id <<<"$owner")
    PIM_CAMERA_OWNER_INVOCATION=$(jq -r .invocation_id <<<"$owner")
    PIM_CAMERA_OWNER_PID=$(jq -r .pid <<<"$owner")
    PIM_CAMERA_OWNER_PROC_START_TIME=$(jq -r .proc_start_time <<<"$owner")
    PIM_CAMERA_OWNER_TOKEN=$(jq -r .token <<<"$owner")
    PIM_CAMERA_OWNER_CREATED_AT=$(jq -r .created_at <<<"$owner")
    export PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
    export PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
}

_cl_stop_begin_locked() {
    local owner lifecycle
    [ -e "$(_cr_owner_file)" ] || { printf 'done\n'; return 0; }
    owner=$(_cr_owner_json) || return 69
    _cr_owner_snapshot_live "$owner" "${PIM_CAMERA_OWNER_INVOCATION:-}" "${PIM_CAMERA_OWNER_TOKEN:-}" || return 69
    lifecycle=$(jq -r .lifecycle <<<"$owner") || return 69
    if [ "$lifecycle" = STOPPING ]; then printf 'wait\n'; return 0; fi
    _cr_owner_set_lifecycle_locked STOPPING || return $?
    printf 'coordinator\n'
}

_cl_wait_owner_removed() {
    local timeout=$PIM_CAMERA_STOP_WAIT_SEC elapsed=0
    [[ $timeout =~ ^[0-9]+$ ]] || timeout=5
    while [ -e "$(_cr_owner_file)" ]; do
        [ "$elapsed" -lt "$timeout" ] || return 75
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

cam_liveness_wait_for_work() {
    local timeout=$PIM_CAMERA_STOP_WAIT_SEC elapsed=0
    [[ $timeout =~ ^[0-9]+$ ]] || timeout=5
    while [ -e "$(_cr_active_file)" ]; do
        [ "$elapsed" -lt "$timeout" ] || break
        sleep 1
        elapsed=$((elapsed + 1))
    done
    while [ -n "$(jobs -pr 2>/dev/null)" ]; do
        [ "$elapsed" -lt "$timeout" ] || break
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

_cl_stopping_guard() {
    local owner
    owner=$(_cr_owner_json) || return 69
    _cl_owner_matches_context "$owner" || return 69
    _cr_owner_snapshot_lifecycle_in "$owner" STOPPING
}

cam_liveness_signal_daemon() {
    _cl_stopping_guard || return $?
    "$PIM_CAMERA_KILL" -TERM "$PIM_CAMERA_OWNER_PID"
}

cam_liveness_wait_daemon_quiesced() {
    local timeout=$PIM_CAMERA_STOP_WAIT_SEC elapsed=0 actual
    [[ $timeout =~ ^[0-9]+$ ]] || timeout=5
    while :; do
        actual=$(_cr_proc_start "$PIM_CAMERA_OWNER_PID" 2>/dev/null || true)
        [ "$actual" = "$PIM_CAMERA_OWNER_PROC_START_TIME" ] || return 0
        [ "$elapsed" -lt "$timeout" ] || return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

cam_liveness_stop_managed() {
    local rc=0
    PIM_CAMERA_STOP_EXECUTOR=1
    export PIM_CAMERA_STOP_EXECUTOR
    cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" gstapp || rc=$?
    if [ "$rc" -eq 0 ]; then cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" pimcam || rc=$?; fi
    if [ "$rc" -eq 0 ]; then cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" bg || rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        _cl_stopping_guard || rc=$?
        [ "$rc" -ne 0 ] || "$PIM_CAMERA_SYSTEMCTL" stop ord-operate.service || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" vcm || rc=$?; fi
    unset PIM_CAMERA_STOP_EXECUTOR
    return "$rc"
}

_cl_finish_stop_locked() {
    local owner
    [ -e "$(_cr_owner_file)" ] || return 0
    owner=$(_cr_owner_json) || return 69
    _cl_owner_matches_context "$owner" || return 69
    _cr_owner_snapshot_lifecycle_in "$owner" STOPPING || return 69
    _cr_remove "$(_cr_owner_file)"
}

cam_liveness_ordered_stop() {
    local external=0 mode rc
    [ "${1:-}" != --external ] || external=1
    _cl_capture_owner_context "$external" || return $?
    mode=$(_cr_lock_call _cl_stop_begin_locked) || return $?
    case "$mode" in
        done) return 0 ;;
        wait) [ "$external" -eq 0 ] && return 0; _cl_wait_owner_removed; return $? ;;
        coordinator) ;;
        *) return 70 ;;
    esac
    _cl_stop_event stopping
    _cl_stop_event intake_closed
    cam_liveness_quiesce || return $?
    if [ "$external" -eq 1 ]; then
        _cl_stop_event daemon_quiesce_signaled
        cam_liveness_signal_daemon || return $?
        cam_liveness_wait_daemon_quiesced || return $?
        _cl_stop_event daemon_quiesced
    fi
    cam_liveness_wait_for_work || return $?
    _cl_stop_event action_child_quiesced
    cam_liveness_stop_managed || return $?
    _cl_stop_event managed_stopped
    _cl_stop_event terminal_stop
    _cr_lock_call _cl_finish_stop_locked || return $?
    _cl_stop_event owner_removed
}

_cl_trap_signal() {
    local rc=$1
    trap - TERM INT EXIT
    cam_liveness_ordered_stop >/dev/null 2>&1 || :
    exit "$rc"
}

_cl_trap_exit() {
    local rc=$?
    trap - TERM INT EXIT
    cam_liveness_ordered_stop >/dev/null 2>&1 || :
    return "$rc"
}

cam_liveness_install_traps() {
    trap '_cl_trap_signal 143' TERM
    trap '_cl_trap_signal 130' INT
    trap '_cl_trap_exit' EXIT
}
