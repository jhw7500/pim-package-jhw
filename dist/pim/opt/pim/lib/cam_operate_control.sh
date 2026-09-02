#!/usr/bin/env bash
# Transaction owner for cam-operate startup, apply-config, and queued recovery.

PIM_LIB="${PIM_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PIM_BIN="${PIM_BIN:-$(cd "$PIM_LIB/../bin" && pwd)}"
PIM_CAMERA_SOURCE_ROOT="${PIM_CAMERA_SOURCE_ROOT:-/root/shared_v}"
PIM_CAMERA_RUNTIME_HELPER="${PIM_CAMERA_RUNTIME_HELPER:-$PIM_BIN/camera_runtime_config.py}"
PIM_CAMERA_CONTROL_WORK_DIR="${PIM_CAMERA_CONTROL_WORK_DIR:-$PIM_CAMERA_RUN_DIR/control}"

if ! declare -F cam_owner_assert >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$PIM_LIB/cam_recovery.sh"
fi
if ! declare -F cam_execute_action_step >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$PIM_LIB/cam_recovery_actions.sh"
fi

_coc_candidate_file() { printf '%s/candidate.json' "$PIM_CAMERA_CONTROL_WORK_DIR"; }
_coc_stage_result_file() { printf '%s/source.json' "$PIM_CAMERA_CONTROL_WORK_DIR"; }
_coc_plan_file() { printf '%s/plan.json' "$PIM_CAMERA_CONTROL_WORK_DIR"; }
_coc_projection_file() { printf '%s/projection.json' "$PIM_CAMERA_CONTROL_WORK_DIR"; }

_coc_boot_id() { cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null; }
_coc_invocation_id() { jq -r .invocation_id "$(_cr_owner_file)" 2>/dev/null; }
_coc_runtime_dir() { dirname "$PIM_CAMERA_RUNTIME_JSON"; }

_coc_state_schema() {
    jq -e '
      type == "object" and .schema == 1 and
      (.last_boot_id | type == "string" and length > 0) and
      (.last_successful_hardware_projection | type == "object") and
      (.dirty | type == "boolean") and
      (.degraded_reason == null or (.degraded_reason | type == "string")) and
      (.degraded_target == null or (.degraded_target | type == "string")) and
      (.last_invocation_id | type == "string" and length > 0)
    ' >/dev/null 2>&1
}

_coc_state_default() {
    local boot invocation
    boot=$(_coc_boot_id) || return 70
    invocation=$(_coc_invocation_id 2>/dev/null || printf unknown)
    jq -cn --arg boot "$boot" --arg invocation "$invocation" \
      '{schema:1,last_boot_id:$boot,last_successful_hardware_projection:{},dirty:false,degraded_reason:null,degraded_target:null,last_invocation_id:$invocation}'
}

_coc_state_current() {
    local state
    state=$(cat "$(_cr_service_file)" 2>/dev/null) && _coc_state_schema <<<"$state" && { printf '%s\n' "$state"; return 0; }
    _coc_state_default
}

_coc_write_state() {
    local state=$1 canonical
    canonical=$(jq -c '{schema,last_boot_id,last_successful_hardware_projection,dirty,degraded_reason,degraded_target,last_invocation_id}' <<<"$state") || return 70
    _coc_state_schema <<<"$canonical" || return 70
    _cr_atomic_write "$(_cr_service_file)" "$canonical" || return 70
}

_coc_set_dirty() {
    local dirty=$1 state next boot invocation
    state=$(_coc_state_current) || return $?
    boot=$(_coc_boot_id) || return 70
    invocation=$(_coc_invocation_id) || return 69
    next=$(jq -c --arg boot "$boot" --arg invocation "$invocation" --argjson dirty "$dirty" \
      '.schema=1 | .last_boot_id=$boot | .last_invocation_id=$invocation | .dirty=$dirty' <<<"$state") || return 70
    _coc_write_state "$next"
}

_coc_persist_success() {
    local projection=$1 state boot invocation
    boot=$(_coc_boot_id) || return 70
    invocation=$(_coc_invocation_id) || return 69
    state=$(jq -cn --arg boot "$boot" --arg invocation "$invocation" --argjson projection "$projection" \
      '{schema:1,last_boot_id:$boot,last_successful_hardware_projection:$projection,dirty:false,degraded_reason:null,degraded_target:null,last_invocation_id:$invocation}') || return 70
    _coc_write_state "$state"
}

cam_stage_source_candidate() {
    local candidate=${1:-$(_coc_candidate_file)} result=${2:-$(_coc_stage_result_file)}
    mkdir -p "$PIM_CAMERA_CONTROL_WORK_DIR" || return 70
    rm -f "$candidate" "$result" "$(_coc_plan_file)" "$(_coc_projection_file)"
    python3 "$PIM_CAMERA_RUNTIME_HELPER" stage \
      --source-root "$PIM_CAMERA_SOURCE_ROOT" --candidate "$candidate" --result "$result" \
      >/dev/null 2>&1 || return 64
}

_coc_publish_candidate() {
    [ "${FAIL_PUBLISH:-}" != 1 ] || return 70
    python3 "$PIM_CAMERA_RUNTIME_HELPER" publish \
      --candidate "$1" --runtime-dir "$(_coc_runtime_dir)" >/dev/null 2>&1 || return 70
}

_coc_projection() {
    local file=$1 output=${2:-$(_coc_projection_file)}
    python3 "$PIM_CAMERA_RUNTIME_HELPER" projection --file "$file" --output "$output" >/dev/null 2>&1 || return 64
    cat "$output"
}

_coc_plan_apply() {
    python3 "$PIM_CAMERA_RUNTIME_HELPER" plan \
      --current "$PIM_CAMERA_RUNTIME_JSON" --candidate "$1" --output "$(_coc_plan_file)" \
      >/dev/null 2>&1 || return 64
    cat "$(_coc_plan_file)"
}

cam_plan_startup_action() {
    local candidate=${1:-$(_coc_candidate_file)} previous=${2:-} boot projection prior_projection dirty
    boot=$(_coc_boot_id) || return 70
    projection=$(_coc_projection "$candidate") || return $?
    if [ -z "$previous" ]; then
        printf 'initial_module_load\n'
        return 0
    fi
    if ! _coc_state_schema <<<"$previous"; then
        printf 'camera_hard_reset\n'
        return 0
    fi
    [ "$(jq -r .last_boot_id <<<"$previous")" = "$boot" ] || { printf 'initial_module_load\n'; return 0; }
    dirty=$(jq -r .dirty <<<"$previous")
    [ "$dirty" = false ] || { printf 'camera_hard_reset\n'; return 0; }
    prior_projection=$(jq -c .last_successful_hardware_projection <<<"$previous") || { printf 'camera_hard_reset\n'; return 0; }
    if jq -ne --argjson current "$projection" --argjson previous "$prior_projection" '$current == $previous' >/dev/null; then
        printf 'module_reload\n'
    else
        printf 'camera_hard_reset\n'
    fi
}

_coc_export_owner_context() {
    local owner
    owner=$(_cr_owner_json) || return 69
    PIM_CAMERA_OWNER_BOOT_ID=$(jq -r .boot_id <<<"$owner")
    PIM_CAMERA_OWNER_INVOCATION=$(jq -r .invocation_id <<<"$owner")
    PIM_CAMERA_OWNER_PID=$(jq -r .pid <<<"$owner")
    PIM_CAMERA_OWNER_PROC_START_TIME=$(jq -r .proc_start_time <<<"$owner")
    PIM_CAMERA_OWNER_TOKEN=$(jq -r .token <<<"$owner")
    PIM_CAMERA_OWNER_CREATED_AT=$(jq -r .created_at <<<"$owner")
    export PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
    export PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
}

_coc_start_all_consumers() {
    cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON" || return $?
    cam_restart_vcm "$PIM_CAMERA_RUNTIME_JSON" || return $?
    cam_start_gstapp "$PIM_CAMERA_RUNTIME_JSON"
}

_coc_verify_all() {
    cam_verify_camera_ready "$PIM_CAMERA_RUNTIME_JSON" || return $?
    cam_wait_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
}

cam_mark_degraded() {
    local reason=${1:-unknown} target=${2:-camera_health} dirty=${3:-true} state next boot invocation lifecycle
    state=$(_coc_state_current) || return $?
    boot=$(_coc_boot_id) || return 70
    invocation=$(_coc_invocation_id) || return 69
    next=$(jq -c --arg boot "$boot" --arg invocation "$invocation" --arg reason "$reason" --arg target "$target" --argjson dirty "$dirty" \
      '.schema=1 | .last_boot_id=$boot | .last_invocation_id=$invocation | .dirty=$dirty | .degraded_reason=$reason | .degraded_target=$target' <<<"$state") || return 70
    _coc_write_state "$next" || return $?
    lifecycle=$(jq -r .lifecycle "$(_cr_owner_file)" 2>/dev/null) || return 69
    [ "$lifecycle" = DEGRADED ] || cam_owner_set_lifecycle DEGRADED
}

_coc_startup_fail() {
    local rc=$1 reason=$2 dirty=${3:-false} persist_rc
    cam_mark_degraded "$reason" camera_health "$dirty" >/dev/null 2>&1
    persist_rc=$?
    [ "$persist_rc" -eq 0 ] || return "$persist_rc"
    return "$rc"
}

_coc_begin_startup_action() {
    local action=$1 source_path source_mtime rc
    source_path=$(jq -r '.path | select(type == "string" and length > 0)' "$(_coc_stage_result_file)") || return 70
    source_mtime=$(jq -r '.mtime_ns | select(type == "number" and floor == . and . >= 0)' "$(_coc_stage_result_file)") || return 70
    cam_startup_request_reserve "$action" startup "same-boot daemon restart" "$source_path" "$source_mtime" >/dev/null || return $?
    cam_request_transition QUIESCING || return $?
    cam_request_transition RUNNING || return $?
    cam_executor_set_context || return $?
    cam_execute_action_step "$action" "$PIM_CAMERA_RUNTIME_JSON"
    rc=$?
    [ "$rc" -eq 0 ] || { _coc_fail_active "$rc" startup_action_failed camera_health true; return $?; }
}

cam_daemon_startup() {
    local pid=${1:-$$} previous='' candidate action projection rc countered=false
    cam_owner_create "$pid" || return $?
    _coc_export_owner_context || return $?
    cam_reconcile_interrupted || return $?
    if [ -f "$(_cr_service_file)" ]; then previous=$(cat "$(_cr_service_file)" 2>/dev/null || printf invalid); fi
    candidate=$(_coc_candidate_file)
    cam_stage_source_candidate "$candidate" "$(_coc_stage_result_file)" || { rc=$?; _coc_startup_fail "$rc" CONFIG_INVALID false; return $?; }
    action=$(cam_plan_startup_action "$candidate" "$previous") || { rc=$?; _coc_startup_fail "$rc" CONFIG_INVALID false; return $?; }
    _coc_publish_candidate "$candidate" || { rc=$?; _coc_startup_fail "$rc" publish_failed false; return $?; }
    _coc_set_dirty true || { rc=$?; _coc_startup_fail "$rc" state_write_failed true; return $?; }
    PIM_CAMERA_STARTUP_EXECUTOR=1
    export PIM_CAMERA_STARTUP_EXECUTOR
    case "$action" in
        initial_module_load)
            cam_initial_module_load "$PIM_CAMERA_RUNTIME_JSON" && _coc_start_all_consumers
            rc=$?
            ;;
        module_reload|camera_hard_reset)
            unset PIM_CAMERA_STARTUP_EXECUTOR
            countered=true
            _coc_begin_startup_action "$action"
            rc=$?
            ;;
        *) rc=70 ;;
    esac
    unset PIM_CAMERA_STARTUP_EXECUTOR
    if [ "$rc" -ne 0 ]; then
        [ "$countered" = true ] && return "$rc"
        _coc_startup_fail "$rc" startup_action_failed true
        return $?
    fi
    if [ "$countered" = true ]; then cam_request_transition VERIFYING || return $?; fi
    _coc_verify_all || { rc=$?; if [ "$countered" = true ]; then _coc_fail_active "$rc" startup_verify_failed camera_health true; else _coc_startup_fail "$rc" startup_verify_failed true; fi; return $?; }
    projection=$(_coc_projection "$PIM_CAMERA_RUNTIME_JSON") || { rc=$?; if [ "$countered" = true ]; then _coc_fail_active "$rc" projection_failed camera_health true; else _coc_startup_fail "$rc" projection_failed true; fi; return $?; }
    _coc_persist_success "$projection" || { rc=$?; if [ "$countered" = true ]; then _coc_fail_active "$rc" state_write_failed state true; else _coc_startup_fail "$rc" state_write_failed true; fi; return $?; }
    if [ "$countered" = true ]; then cam_request_finish SUCCEEDED 0 || return $?; fi
    cam_owner_set_lifecycle ACTIVE
}

_coc_record_step() {
    local action=$1 status=$2 rc=$3 active id history next now
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    id=$(jq -r .id <<<"$active") || return 70
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 70
    now=$(_cr_now)
    next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" \
      '.actions += [{action:$action,request_id:$id,status:$status,rc:$rc,started_at:$now,finished_at:$now,countered:false}]' <<<"$history") || return 70
    _cr_atomic_write "$(_cr_history_file "$id")" "$next" || return 70
}

_coc_attach_source_result_locked() {
    local stage_result=$1 active updated id source_path source_mtime
    _cr_owner_lifecycle_in ACTIVE DEGRADED || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    _cr_record_owner_matches "$active" || return 69
    source_path=$(jq -r '.path | select(type == "string" and length > 0)' "$stage_result") || return 70
    source_mtime=$(jq -r '.mtime_ns | select(type == "number" and floor == . and . >= 0)' "$stage_result") || return 70
    updated=$(jq -c --arg source_path "$source_path" --argjson source_mtime "$source_mtime" \
      '.source_path=$source_path | .source_mtime=$source_mtime' <<<"$active") || return 70
    id=$(jq -r .id <<<"$active") || return 70
    _cr_mutation_guard "$active" active ACTIVE DEGRADED || return 69
    _cr_atomic_write "$(_cr_active_file)" "$updated" || return 70
    _cr_mutation_guard "$updated" transition_history ACTIVE DEGRADED || return 69
    _cr_history_request "$id" "$updated" || return 70
}

_coc_attach_source_result() { _cr_lock_call _coc_attach_source_result_locked "$1"; }

_coc_run_uncountered_step() {
    local action=$1 rc
    case "$action" in
        ord_restart) cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"; rc=$? ;;
        vcm_restart) cam_restart_vcm "$PIM_CAMERA_RUNTIME_JSON"; rc=$? ;;
        policy_reload) cam_reload_policy; rc=$? ;;
        *) return 64 ;;
    esac
    if [ "$rc" -eq 0 ]; then _coc_record_step "$action" SUCCEEDED 0 || return $?; else _coc_record_step "$action" FAILED "$rc" || return $?; fi
    return "$rc"
}

if ! declare -F _coc_policy_reload >/dev/null 2>&1; then
    _coc_policy_reload() {
        if declare -F GetConfig_ >/dev/null 2>&1; then GetConfig_; else return 0; fi
    }
fi
cam_reload_policy() { _coc_policy_reload; }

_coc_effective_steps() {
    local plan=$1 state owner_lifecycle target
    state=$(_coc_state_current) || return $?
    if [ "$(jq -r .dirty <<<"$state")" = true ]; then
        printf 'camera_hard_reset\n'
        jq -e '.steps | index("policy_reload") != null' >/dev/null <<<"$plan" && printf 'policy_reload\n'
        return 0
    fi
    if [ "$(jq -r .semantic_change <<<"$plan")" = true ]; then
        jq -r '.steps[]' <<<"$plan"
        return 0
    fi
    owner_lifecycle=$(jq -r .lifecycle "$(_cr_owner_file)") || return 69
    [ "$owner_lifecycle" = DEGRADED ] || return 0
    target=$(jq -r '.degraded_target // empty' <<<"$state")
    case "$target" in
        ord) printf 'ord_restart\n' ;;
        vcm) printf 'vcm_restart\n' ;;
        gstapp|gstApp|process) printf 'gstapp_restart\n' ;;
        camera|camera_health|health) printf 'module_reload\n' ;;
    esac
}

_coc_quiesce_steps() {
    local steps=$1
    if grep -Eq '^(camera_hard_reset|module_reload)$' <<<"$steps"; then cam_quiesce_consumers "$PIM_CAMERA_RUNTIME_JSON"; return $?; fi
    if grep -qx gstapp_restart <<<"$steps" && { grep -qx ord_restart <<<"$steps" || grep -qx vcm_restart <<<"$steps"; }; then
        cam_quiesce_consumers "$PIM_CAMERA_RUNTIME_JSON"; return $?
    fi
    if grep -qx gstapp_restart <<<"$steps"; then cam_quiesce_gstapp "$PIM_CAMERA_RUNTIME_JSON" || return $?; fi
    if grep -qx ord_restart <<<"$steps"; then cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" ord || return $?; fi
    if grep -qx vcm_restart <<<"$steps"; then cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" vcm || return $?; fi
    return 0
}

_coc_step_target() {
    case "$1" in ord_restart) printf ord;; vcm_restart) printf vcm;; gstapp_restart) printf gstapp;; policy_reload) printf policy;; *) printf camera_health;; esac
}

_coc_fail_active() {
    local rc=$1 reason=$2 target=$3 dirty=$4 status
    status=$(jq -r .status "$(_cr_active_file)" 2>/dev/null || printf unknown)
    case "$status" in QUIESCING|RUNNING|VERIFYING) cam_request_transition FAILED >/dev/null 2>&1 || return $?;; esac
    cam_mark_degraded "$reason" "$target" "$dirty" >/dev/null 2>&1 || return $?
    cam_request_finish FAILED "$rc" >/dev/null 2>&1 || return $?
    return "$rc"
}

_coc_fail_retryable_liveness_gstapp() {
    local rc=$1 active id state history
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    _cr_request_schema "$active" || return 70
    jq -e '.type=="gstapp_restart" and .source=="liveness" and .reason=="gstapp process absent" and .status=="RUNNING"' >/dev/null <<<"$active" || return 70
    _cr_record_owner_ready "$active" RECOVERING || return 69
    id=$(jq -r .id <<<"$active") || return 70
    state=$(cat "$(_cr_state_file)" 2>/dev/null) || return 70
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 70
    _cr_counter_finish_pair_valid "$history" "$state" gstapp_restart "$id" || return 70
    jq -e --arg id "$id" --argjson rc "$rc" '
      .actions.gstapp_restart.last_request_id==$id and
      .actions.gstapp_restart.last_status=="FAILED" and
      .actions.gstapp_restart.last_rc==$rc and
      .actions.gstapp_restart.consecutive_failures>0
    ' >/dev/null <<<"$state" || return 70
    _cr_test_failpoint retryable_liveness_before_finish || return 70
    cam_request_finish FAILED "$rc" >/dev/null 2>&1 || return $?
    cam_owner_set_lifecycle ACTIVE >/dev/null 2>&1 || return $?
    return "$rc"
}

_coc_finish_preflight_failed() {
    local rc=$1 finish_rc
    cam_request_finish FAILED "$rc"
    finish_rc=$?
    [ "$finish_rc" -eq 0 ] || return "$finish_rc"
    return "$rc"
}

cam_apply_config_transaction() {
    local active type candidate plan steps step rc=0 projection dirty=false reason target
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    type=$(jq -r .type <<<"$active") || return 70
    [ "$type" = apply_config ] || return 64
    _cr_record_owner_ready "$active" ACTIVE DEGRADED || return 69
    reason=$(jq -r .reason <<<"$active")
    candidate=$(_coc_candidate_file)
    if ! cam_stage_source_candidate "$candidate" "$(_coc_stage_result_file)"; then
        _coc_finish_preflight_failed 64
        return $?
    fi
    _coc_attach_source_result "$(_coc_stage_result_file)" || { rc=$?; _coc_finish_preflight_failed "$rc"; return $?; }
    plan=$(_coc_plan_apply "$candidate") || { rc=$?; _coc_finish_preflight_failed "$rc"; return $?; }
    steps=$(_coc_effective_steps "$plan") || { rc=$?; _coc_finish_preflight_failed "$rc"; return $?; }
    cam_owner_set_lifecycle APPLYING_CONFIG || return $?
    cam_request_transition QUIESCING || return $?
    cam_executor_set_context || { rc=$?; _coc_fail_active "$rc" "$reason" executor false; return $?; }
    _coc_quiesce_steps "$steps" || { rc=$?; _coc_fail_active "$rc" "$reason" process false; return $?; }
    cam_request_transition RUNNING || return $?
    _coc_publish_candidate "$candidate" || { rc=$?; _coc_fail_active "$rc" "$reason" config false; return $?; }
    if grep -Eq '^(module_reload|camera_hard_reset)$' <<<"$steps"; then dirty=true; _coc_set_dirty true || { rc=$?; _coc_fail_active "$rc" "$reason" camera_health true; return $?; }; fi
    if grep -qx camera_hard_reset <<<"$steps"; then
        PIM_CAMERA_CONSUMERS_QUIESCED=1 cam_execute_action_step camera_hard_reset "$PIM_CAMERA_RUNTIME_JSON" || rc=$?
        [ "$rc" -eq 0 ] || { _coc_fail_active "$rc" "$reason" camera_health true; return $?; }
    else
        for step in gstapp_restart ord_restart vcm_restart; do
            grep -qx "$step" <<<"$steps" || continue
            if [ "$step" = gstapp_restart ]; then PIM_CAMERA_CONSUMERS_QUIESCED=1 cam_execute_action_step "$step" "$PIM_CAMERA_RUNTIME_JSON" || rc=$?; else _coc_run_uncountered_step "$step" || rc=$?; fi
            if [ "$rc" -ne 0 ]; then target=$(_coc_step_target "$step"); _coc_fail_active "$rc" "$reason" "$target" "$dirty"; return $?; fi
        done
        if grep -qx module_reload <<<"$steps"; then
            PIM_CAMERA_CONSUMERS_QUIESCED=1 cam_execute_action_step module_reload "$PIM_CAMERA_RUNTIME_JSON" || rc=$?
            [ "$rc" -eq 0 ] || { _coc_fail_active "$rc" "$reason" camera_health true; return $?; }
        fi
    fi
    if grep -qx policy_reload <<<"$steps"; then
        _coc_run_uncountered_step policy_reload || rc=$?
        if [ "$rc" -ne 0 ]; then _coc_fail_active "$rc" "$reason" policy "$dirty"; return $?; fi
    fi
    cam_request_transition VERIFYING || return $?
    _coc_verify_all || { rc=$?; _coc_fail_active "$rc" "$reason" camera_health "$dirty"; return $?; }
    projection=$(_coc_projection "$PIM_CAMERA_RUNTIME_JSON") || { rc=$?; _coc_fail_active "$rc" "$reason" camera_health "$dirty"; return $?; }
    _coc_persist_success "$projection" || { rc=$?; _coc_fail_active "$rc" "$reason" state true; return $?; }
    cam_request_finish SUCCEEDED 0 || return $?
    cam_owner_set_lifecycle ACTIVE
}

_coc_execute_recovery_active() {
    local active type reason rc=0 dirty=false target=camera_health projection
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    type=$(jq -r .type <<<"$active") || return 70
    reason=$(jq -r .reason <<<"$active") || return 70
    if ! cam_validate_runtime "$PIM_CAMERA_RUNTIME_JSON"; then
        cam_request_finish FAILED 64 || return $?
        cam_mark_degraded CONFIG_INVALID config false || return $?
        return 64
    fi
    cam_owner_set_lifecycle RECOVERING || return $?
    cam_request_transition QUIESCING || return $?
    cam_request_transition RUNNING || return $?
    cam_executor_set_context || return $?
    case "$type" in
        module_reload|camera_hard_reset)
            dirty=true
            _coc_set_dirty true || { rc=$?; _coc_fail_active "$rc" "$reason" state true; return $?; }
            ;;
        gstapp_restart) target=gstapp ;;
    esac
    case "$type" in
        gstapp_restart) cam_execute_action_step gstapp_restart "$PIM_CAMERA_RUNTIME_JSON" || rc=$? ;;
        module_reload)
            cam_execute_action_step module_reload "$PIM_CAMERA_RUNTIME_JSON" || rc=$?
            if [ "$rc" -ne 0 ]; then rc=0; cam_execute_action_step camera_hard_reset "$PIM_CAMERA_RUNTIME_JSON" || rc=$?; fi
            if [ "$rc" -ne 0 ]; then rc=0; cam_execute_action_step reboot_fallback "$PIM_CAMERA_RUNTIME_JSON" || rc=$?; fi
            ;;
        camera_hard_reset)
            cam_execute_action_step camera_hard_reset "$PIM_CAMERA_RUNTIME_JSON" || rc=$?
            if [ "$rc" -ne 0 ]; then rc=0; cam_execute_action_step reboot_fallback "$PIM_CAMERA_RUNTIME_JSON" || rc=$?; fi
            ;;
        reboot_fallback) cam_execute_action_step reboot_fallback "$PIM_CAMERA_RUNTIME_JSON" || rc=$? ;;
        *) return 64 ;;
    esac
    if [ "$rc" -ne 0 ]; then
        if [ "$type" = gstapp_restart ] &&
           jq -e '.source=="liveness" and .reason=="gstapp process absent"' >/dev/null <<<"$active"; then
            _coc_fail_retryable_liveness_gstapp "$rc"
        else
            _coc_fail_active "$rc" "$reason" "$target" "$dirty"
        fi
        return $?
    fi
    cam_request_transition VERIFYING || return $?
    _coc_verify_all || { rc=$?; _coc_fail_active "$rc" "$reason" camera_health "$dirty"; return $?; }
    projection=$(_coc_projection "$PIM_CAMERA_RUNTIME_JSON") || { rc=$?; _coc_fail_active "$rc" "$reason" camera_health "$dirty"; return $?; }
    _coc_persist_success "$projection" || { rc=$?; _coc_fail_active "$rc" "$reason" state true; return $?; }
    cam_request_finish SUCCEEDED 0 || return $?
    cam_owner_set_lifecycle ACTIVE
}

cam_execute_pending_request() {
    local type
    type=$(jq -r .type "$(_cr_active_file)" 2>/dev/null) || return 69
    if [ "$type" = apply_config ]; then cam_apply_config_transaction; else _coc_execute_recovery_active; fi
}

cam_poll_pending_request() {
    [ -f "$(_cr_pending_file)" ] || return 1
    cam_request_claim || return $?
    cam_execute_pending_request
}

cam_daemon_begin_stop() {
    cam_owner_set_lifecycle STOPPING
}

cam_daemon_finish_stop() {
    _cr_owner_lifecycle_in STOPPING || return 69
    _cr_remove "$(_cr_owner_file)" || return 70
}
