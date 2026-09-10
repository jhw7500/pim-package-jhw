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
PIM_CAMERA_LIVENESS_START_WAIT_SEC="${PIM_CAMERA_LIVENESS_START_WAIT_SEC:-30}"
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
    _cr_owner_matches_exported_context "$owner" || return 69
    _cr_owner_snapshot_live "$owner" || return 69
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
    _cr_test_owner_rollover liveness_ord || return 69
    _cl_active_guard_locked || return $?
    "$PIM_CAMERA_SYSTEMCTL" restart ord-operate.service
}
cam_liveness_restart_ord() { _cr_lock_call _cl_restart_ord_locked; }

_cl_restart_vcm_locked() {
    local path=$1
    _cr_test_owner_rollover liveness_vcm || return 69
    _cl_active_guard_locked || return $?
    (
        exec {fd}>&-
        if [ -n "${PIM_CAMERA_TEST_VCM_PRE_EXEC_HOOK:-}" ]; then
            "$PIM_CAMERA_TEST_VCM_PRE_EXEC_HOOK" || exit $?
        fi
        _cl_active_guard_locked || exit $?
        exec "$path"
    ) &
    _cl_wait_named_process vcm "$PIM_CAMERA_LIVENESS_START_WAIT_SEC"
}
cam_liveness_restart_vcm() {
    local path
    path=$(command -v "$PIM_CAMERA_VCM_COMMAND") || return 127
    _cr_lock_call _cl_restart_vcm_locked "$path"
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

_cl_note_failure_locked() {
    local target=$1 state next boot invocation
    _cr_test_owner_rollover liveness_degraded || return 69
    _cl_active_guard_locked || return $?
    if [ -e "$(_cr_service_file)" ]; then
        state=$(cat "$(_cr_service_file)" 2>/dev/null) || return 70
        _coc_state_schema <<<"$state" || return 70
    else
        state=$(_coc_state_default) || return $?
    fi
    boot=$(_coc_boot_id) || return 70
    invocation=$(_coc_invocation_id) || return 69
    next=$(jq -c --arg boot "$boot" --arg invocation "$invocation" --arg target "$target" \
      '.schema=1 | .last_boot_id=$boot | .last_invocation_id=$invocation | .dirty=false | .degraded_reason="liveness_start_failed" | .degraded_target=$target' <<<"$state") || return 70
    _cl_active_guard_locked || return $?
    _coc_write_state "$next" || return $?
    _cl_active_guard_locked || return $?
    _cr_owner_set_lifecycle_locked DEGRADED
}
cam_liveness_note_failure() { _cr_lock_call _cl_note_failure_locked "$1"; }

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
    local state action id status history terminal result
    [ -e "$(_cr_state_file)" ] || { printf '0\n'; return 0; }
    state=$(cat "$(_cr_state_file)" 2>/dev/null) || return 70
    _cr_state_valid <<<"$state" || return 70
    action=$(jq -c '.actions.gstapp_restart' <<<"$state") || return 70
    id=$(jq -r '.last_request_id // ""' <<<"$action") || return 70
    if [ -z "$id" ]; then
        jq -e '. == {attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null}' >/dev/null <<<"$action" || return 70
    else
        _cr_counter_finish_state_action_valid "$state" gstapp_restart "$id" || return 70
        status=$(jq -r '.last_status' <<<"$action") || return 70
        if [ "$status" = RUNNING ]; then
            _cr_counter_begin_prior_interruption_valid "$state" gstapp_restart "$id" 2>/dev/null || return 70
        else
            history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 70
            terminal=$(jq -ce '.request | select(type=="object")' <<<"$history") || return 70
            _cr_terminal_request_valid "$terminal" || return 70
            _cr_request_interruption_absent "$terminal" || return 70
            result=$(cat "$(_cr_result_file "$id")" 2>/dev/null) || return 70
            _cr_terminal_result_valid "$result" "$terminal" || return 70
            _cr_terminal_request_result_equal "$terminal" "$result" || return 70
            _cr_terminal_attribution_valid "$history" "$terminal" "$state" || return 70
            _cr_history_public_state_arithmetic_valid "$history" "$state" "$id" || return 70
        fi
    fi
    jq -r '.actions.gstapp_restart.consecutive_failures' <<<"$state"
}

_cl_request_gstapp_recovery() {
    local failures action=gstapp_restart
    failures=$(_cl_gstapp_failures) || return $?
    [[ $PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD =~ ^[0-9]+$ ]] || return 64
    [ "$failures" -lt "$PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD" ] || action=module_reload
    _cr_test_owner_rollover liveness_request || return 69
    _cl_active_guard || return $?
    cam_request_submit "$action" liveness "gstapp process absent" >/dev/null
}

cam_liveness_tick() {
    local rc app
    _cl_active_guard || return $?
    _cl_handle_operation_flags || return 0

    rc=0; _cl_ord_status || rc=$?
    case "$rc" in
        0) ;;
        1)
            rc=0; cam_liveness_restart_ord || rc=$?
            if [ "$rc" -ne 0 ]; then cam_liveness_note_failure ord || return $?; return "$rc"; fi
            ;;
        *) return "$rc" ;;
    esac

    rc=0; _cl_process_status vcm || rc=$?
    case "$rc" in
        0) ;;
        1)
            rc=0; cam_liveness_restart_vcm || rc=$?
            if [ "$rc" -ne 0 ]; then cam_liveness_note_failure vcm || return $?; return "$rc"; fi
            ;;
        *) return "$rc" ;;
    esac

    app=$(cam_runtime_app "$PIM_CAMERA_RUNTIME_JSON") || return $?
    rc=0; _cl_process_status "$app" || rc=$?
    [ "$rc" -ne 0 ] || return 0
    [ "$rc" -eq 1 ] || return "$rc"
    rc=0; cam_liveness_gstapp_gate || rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && return 0; return "$rc"; }
    _cl_active_guard || return $?
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

_cl_current_boot_owner_process_state() {
    local owner=$1 boot owner_boot pid expected actual stat_path
    _cr_owner_schema <<<"$owner" || return 69
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 69
    owner_boot=$(jq -r .boot_id <<<"$owner") || return 69
    [ "$boot" = "$owner_boot" ] || return 69
    pid=$(jq -r .pid <<<"$owner") || return 69
    expected=$(jq -r .proc_start_time <<<"$owner") || return 69
    stat_path="$PIM_CAMERA_PROC_ROOT/$pid/stat"
    [ -e "$stat_path" ] || { printf 'absent\n'; return 0; }
    actual=$(_cr_proc_start "$pid" 2>/dev/null) || return 69
    if [ "$actual" = "$expected" ]; then
        printf 'live\n'
    else
        printf 'reused\n'
    fi
}

_cl_capture_owner_context() {
    local allow_adopt=${1:-0} systemd_handoff=${2:-0} owner lifecycle
    [ -e "$(_cr_owner_file)" ] || return 0
    owner=$(_cr_owner_json) || return 69
    _cr_owner_schema <<<"$owner" || return 69
    lifecycle=$(jq -r .lifecycle <<<"$owner") || return 69
    if [ -n "${PIM_CAMERA_OWNER_INVOCATION:-}" ]; then
        _cl_owner_matches_context "$owner" || return 69
    else
        [ "$allow_adopt" = 1 ] || return 69
        PIM_CAMERA_OWNER_BOOT_ID=$(jq -r .boot_id <<<"$owner")
        PIM_CAMERA_OWNER_INVOCATION=$(jq -r .invocation_id <<<"$owner")
        PIM_CAMERA_OWNER_PID=$(jq -r .pid <<<"$owner")
        PIM_CAMERA_OWNER_PROC_START_TIME=$(jq -r .proc_start_time <<<"$owner")
        PIM_CAMERA_OWNER_TOKEN=$(jq -r .token <<<"$owner")
        PIM_CAMERA_OWNER_CREATED_AT=$(jq -r .created_at <<<"$owner")
        export PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
        export PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
    fi
    if [ "$systemd_handoff" = 1 ]; then
        _cl_current_boot_owner_process_state "$owner" >/dev/null || return $?
    else
        [ "$lifecycle" = STOPPING ] || _cr_owner_snapshot_live "$owner" || return 69
    fi
}

_cl_stop_begin_locked() {
    local systemd_handoff=${1:-0} owner lifecycle updated current current_lifecycle
    [ -e "$(_cr_owner_file)" ] || { printf 'done\n'; return 0; }
    owner=$(_cr_owner_json) || return 69
    _cl_owner_matches_context "$owner" || return 69
    lifecycle=$(jq -r .lifecycle <<<"$owner") || return 69
    if [ "$lifecycle" = STOPPING ]; then
        [ "$systemd_handoff" != 1 ] || _cl_current_boot_owner_process_state "$owner" >/dev/null || return $?
        printf 'coordinator\n'
        return 0
    fi
    if [ "$systemd_handoff" = 1 ]; then
        _cl_current_boot_owner_process_state "$owner" >/dev/null || return $?
        _cr_lifecycle_allowed "$lifecycle" STOPPING || return 64
        updated=$(jq -c '.lifecycle="STOPPING" | .updated_at=(now|floor)' <<<"$owner") || return 70
        current=$(_cr_owner_json) || return 69
        _cl_owner_matches_context "$current" || return 69
        current_lifecycle=$(jq -r .lifecycle <<<"$current") || return 69
        [ "$current_lifecycle" = "$lifecycle" ] || return 69
        _cl_current_boot_owner_process_state "$current" >/dev/null || return $?
        _cr_atomic_write "$(_cr_owner_file)" "$updated" || return 70
    else
        _cr_owner_snapshot_live "$owner" || return 69
        _cr_owner_set_lifecycle_locked STOPPING || return $?
    fi
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
    while [ -e "$(_cr_pending_file)" ] || [ -e "$(_cr_active_file)" ]; do
        [ "$elapsed" -lt "$timeout" ] || return 75
        sleep 1
        elapsed=$((elapsed + 1))
    done
    while [ -n "$(jobs -pr 2>/dev/null)" ]; do
        [ "$elapsed" -lt "$timeout" ] || return 75
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

_cl_signal_daemon_locked() {
    local systemd_handoff=${1:-0} owner process_state stat_path actual
    _cl_stopping_guard || return $?
    if [ "$systemd_handoff" = 1 ]; then
        owner=$(_cr_owner_json) || return 69
        _cl_owner_matches_context "$owner" || return 69
        process_state=$(_cl_current_boot_owner_process_state "$owner") || return $?
        case "$process_state" in
            absent|reused) return 0 ;;
            live) "$PIM_CAMERA_KILL" -TERM "$PIM_CAMERA_OWNER_PID" ;;
            *) return 70 ;;
        esac
        return $?
    fi
    stat_path="$PIM_CAMERA_PROC_ROOT/$PIM_CAMERA_OWNER_PID/stat"
    [ -e "$stat_path" ] || return 0
    actual=$(_cr_proc_start "$PIM_CAMERA_OWNER_PID" 2>/dev/null) || return 69
    [ "$actual" = "$PIM_CAMERA_OWNER_PROC_START_TIME" ] || return 69
    "$PIM_CAMERA_KILL" -TERM "$PIM_CAMERA_OWNER_PID"
}
cam_liveness_signal_daemon() { _cr_lock_call _cl_signal_daemon_locked; }

cam_liveness_wait_daemon_quiesced() {
    local systemd_handoff=${1:-0} timeout=$PIM_CAMERA_STOP_WAIT_SEC elapsed=0 owner process_state actual stat_path
    [[ $timeout =~ ^[0-9]+$ ]] || timeout=5
    if [ "$systemd_handoff" = 1 ]; then
        while :; do
            owner=$(_cr_owner_json) || return 69
            _cl_owner_matches_context "$owner" || return 69
            process_state=$(_cl_current_boot_owner_process_state "$owner") || return $?
            case "$process_state" in
                absent|reused) return 0 ;;
                live) ;;
                *) return 70 ;;
            esac
            [ "$elapsed" -lt "$timeout" ] || return 75
            sleep 1
            elapsed=$((elapsed + 1))
        done
    fi
    stat_path="$PIM_CAMERA_PROC_ROOT/$PIM_CAMERA_OWNER_PID/stat"
    while :; do
        [ -e "$stat_path" ] || return 0
        actual=$(_cr_proc_start "$PIM_CAMERA_OWNER_PID" 2>/dev/null) || return 69
        [ "$actual" = "$PIM_CAMERA_OWNER_PROC_START_TIME" ] || return 69
        [ "$elapsed" -lt "$timeout" ] || return 75
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

_cl_reconcile_stop_lease_locked() {
    local systemd_handoff=${1:-0} owner process_state stat_path actual
    owner=$(_cr_owner_json) || return 69
    _cl_owner_matches_context "$owner" || return 69
    _cr_owner_snapshot_lifecycle_in "$owner" STOPPING || return 69
    if [ "$systemd_handoff" = 1 ]; then
        process_state=$(_cl_current_boot_owner_process_state "$owner") || return $?
        case "$process_state" in
            absent|reused) _cr_reconcile_abandoned_lease_locked "$owner" ;;
            live) return 75 ;;
            *) return 70 ;;
        esac
        return $?
    fi
    stat_path="$PIM_CAMERA_PROC_ROOT/$PIM_CAMERA_OWNER_PID/stat"
    if [ -e "$stat_path" ]; then
        actual=$(_cr_proc_start "$PIM_CAMERA_OWNER_PID" 2>/dev/null) || return 69
        [ "$actual" != "$PIM_CAMERA_OWNER_PROC_START_TIME" ] || return 75
        return 69
    fi
    _cr_reconcile_abandoned_lease_locked "$owner"
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
    [ ! -e "$(_cr_pending_file)" ] && [ ! -e "$(_cr_active_file)" ] || return 75
    _cr_remove "$(_cr_owner_file)"
}

_cl_ordered_stop_locked() {
    local external=$1 systemd_handoff=${2:-0} mode
    _cl_capture_owner_context "$external" "$systemd_handoff" || return $?
    mode=$(_cl_stop_begin_locked "$systemd_handoff") || return $?
    case "$mode" in
        done) return 0 ;;
        coordinator) ;;
        *) return 70 ;;
    esac
    _cl_stop_event stopping
    _cl_stop_event intake_closed
    cam_liveness_quiesce || return $?
    if [ "$external" -eq 1 ]; then
        _cl_stop_event daemon_quiesce_signaled
        _cl_signal_daemon_locked "$systemd_handoff" || return $?
        cam_liveness_wait_daemon_quiesced "$systemd_handoff" || return $?
        _cl_stop_event daemon_quiesced
        _cl_reconcile_stop_lease_locked "$systemd_handoff" || return $?
    fi
    cam_liveness_wait_for_work || return $?
    _cl_stop_event action_child_quiesced
    cam_liveness_stop_managed || return $?
    _cl_stop_event managed_stopped
    _cl_stop_event terminal_stop
    _cl_finish_stop_locked || return $?
    _cl_stop_event owner_removed
}

cam_liveness_ordered_stop() {
    local external=0
    [ "${1:-}" != --external ] || external=1
    _cr_lock_call _cl_ordered_stop_locked "$external"
}

_cl_ordered_stop_systemd_locked() {
    local attempts=${PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS:-30} attempt=1 rc
    case "$attempts" in
        [7-9]|1[0-9]|2[0-9]|30) ;;
        *) attempts=30 ;;
    esac
    while [ "$attempt" -le "$attempts" ]; do
        _cl_ordered_stop_locked 1 1
        rc=$?
        [ "$rc" -eq 75 ] || return "$rc"
        [ "$attempt" -lt "$attempts" ] || return 75
        sleep 1
        attempt=$((attempt + 1))
    done
    return 75
}

cam_liveness_ordered_stop_systemd() {
    _cr_lock_call_wait 75 _cl_ordered_stop_systemd_locked
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
