#!/usr/bin/env bash
# Serialized camera-recovery owner, lease, and durable-result primitives.

PIM_CAMERA_RUN_DIR="${PIM_CAMERA_RUN_DIR:-/run/pim-camera}"
PIM_CAMERA_STATE_DIR="${PIM_CAMERA_STATE_DIR:-/var/lib/pim-camera}"
PIM_CAMERA_BOOT_ID_FILE="${PIM_CAMERA_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
PIM_CAMERA_PROC_ROOT="${PIM_CAMERA_PROC_ROOT:-/proc}"
PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:-$PIM_CAMERA_RUN_DIR/config/pim_runtime.json}"

_cr_owner_file() { printf '%s/owner.json' "$PIM_CAMERA_RUN_DIR"; }
_cr_recovery_dir() { printf '%s/recovery' "$PIM_CAMERA_RUN_DIR"; }
_cr_pending_file() { printf '%s/pending.json' "$(_cr_recovery_dir)"; }
_cr_active_file() { printf '%s/active.json' "$(_cr_recovery_dir)"; }
_cr_result_file() { printf '%s/results/%s.json' "$(_cr_recovery_dir)" "$1"; }
_cr_state_file() { printf '%s/recovery/state.json' "$PIM_CAMERA_STATE_DIR"; }
_cr_history_file() { printf '%s/recovery/history/%s.json' "$PIM_CAMERA_STATE_DIR" "$1"; }
_cr_service_file() { printf '%s/service-state.json' "$PIM_CAMERA_STATE_DIR"; }
_cr_now() { date +%s; }
_cr_uuid() { cat /proc/sys/kernel/random/uuid; }
_cr_proc_start() { awk '{print $22}' "$PIM_CAMERA_PROC_ROOT/$1/stat" 2>/dev/null; }

_cr_atomic_write() {
    local target=$1 data=$2 dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$data" > "$tmp" || ! sync -f "$tmp" || ! mv -f "$tmp" "$target" || ! sync -d "$dir"; then
        rm -f "$tmp"
        return 1
    fi
}

_cr_remove() {
    local target=$1 dir
    dir=$(dirname "$target")
    rm -f "$target" && sync -d "$dir"
}

_cr_lock_call() {
    local fd rc
    mkdir -p "$PIM_CAMERA_RUN_DIR" || return 70
    exec {fd}>"$PIM_CAMERA_RUN_DIR/recovery.lock" || return 70
    flock -n "$fd" || { exec {fd}>&-; return 75; }
    "$@"; rc=$?
    flock -u "$fd"
    exec {fd}>&-
    return "$rc"
}

_cr_public_action() {
    case "$1" in gstapp_restart|module_reload|camera_hard_reset|reboot_fallback) return 0;; esac
    return 1
}

_cr_request_type() {
    _cr_public_action "$1" || [ "$1" = apply_config ]
}

_cr_owner_json() { cat "$(_cr_owner_file)" 2>/dev/null; }

_cr_record_owner_matches() {
    local record=$1 saved current invocation token
    saved=$(jq -c '.owner' <<<"$record") || return 1
    current=$(_cr_owner_json) || return 1
    jq -e --argjson saved "$saved" --argjson current "$current" '
      $saved.boot_id == $current.boot_id and $saved.invocation_id == $current.invocation_id and
      $saved.pid == $current.pid and $saved.proc_start_time == $current.proc_start_time and $saved.token == $current.token
    ' >/dev/null || return 1
    invocation=$(jq -r '.invocation_id' <<<"$saved")
    token=$(jq -r '.token' <<<"$saved")
    cam_owner_assert "$invocation" "$token"
}

cam_owner_create() {
    local pid=${1:-$$} boot start invocation token now record
    [[ $pid =~ ^[0-9]+$ ]] || return 64
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 70
    start=$(_cr_proc_start "$pid")
    [ -n "$start" ] || return 69
    invocation=$(_cr_uuid) || return 70
    token=$(_cr_uuid) || return 70
    now=$(_cr_now)
    record=$(jq -cn --arg boot "$boot" --arg invocation "$invocation" --arg start "$start" --arg token "$token" --argjson pid "$pid" --argjson now "$now" \
        '{boot_id:$boot,invocation_id:$invocation,pid:$pid,proc_start_time:$start,token:$token,lifecycle:"STARTING",created_at:$now}') || return 70
    _cr_atomic_write "$(_cr_owner_file)" "$record" || return 70
}

cam_owner_assert() {
    local expected_invocation=${1:-} expected_token=${2:-} owner boot pid start invocation token actual
    owner=$(_cr_owner_json)
    jq -e '.boot_id|type == "string"' >/dev/null 2>&1 <<<"$owner" || return 69
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 69
    pid=$(jq -r '.pid' <<<"$owner")
    start=$(jq -r '.proc_start_time' <<<"$owner")
    invocation=$(jq -r '.invocation_id' <<<"$owner")
    token=$(jq -r '.token' <<<"$owner")
    actual=$(_cr_proc_start "$pid")
    [ -n "$actual" ] && [ "$boot" = "$(jq -r '.boot_id' <<<"$owner")" ] && [ "$actual" = "$start" ] || return 69
    [ -z "$expected_invocation" ] || [ "$expected_invocation" = "$invocation" ] || return 69
    [ -z "$expected_token" ] || [ "$expected_token" = "$token" ] || return 69
}

_cr_lifecycle_allowed() {
    case "$1:$2" in
        STARTING:ACTIVE|STARTING:DEGRADED|STARTING:STOPPING|ACTIVE:APPLYING_CONFIG|ACTIVE:RECOVERING|ACTIVE:DEGRADED|ACTIVE:STOPPING|APPLYING_CONFIG:ACTIVE|APPLYING_CONFIG:DEGRADED|APPLYING_CONFIG:STOPPING|RECOVERING:ACTIVE|RECOVERING:DEGRADED|RECOVERING:STOPPING|DEGRADED:APPLYING_CONFIG|DEGRADED:RECOVERING|DEGRADED:STOPPING) return 0;;
    esac
    return 1
}

cam_owner_set_lifecycle() {
    local next=$1 owner current updated
    cam_owner_assert || return $?
    owner=$(_cr_owner_json); current=$(jq -r '.lifecycle' <<<"$owner")
    _cr_lifecycle_allowed "$current" "$next" || return 64
    updated=$(jq -c --arg next "$next" '.lifecycle=$next | .updated_at=(now|floor)' <<<"$owner") || return 70
    _cr_atomic_write "$(_cr_owner_file)" "$updated" || return 70
}

_cr_owner_available() {
    local lifecycle
    cam_owner_assert || return 69
    lifecycle=$(jq -r '.lifecycle' "$(_cr_owner_file)")
    [ "$lifecycle" = ACTIVE ] || [ "$lifecycle" = DEGRADED ] || return 69
}

_cr_request_new() {
    local type=$1 source=$2 reason=$3 source_path=${4:-} source_mtime=${5:-} id now owner req
    _cr_request_type "$type" || return 64
    [ -n "$source" ] && [ -n "$reason" ] || return 64
    [ -z "$source_mtime" ] || [[ $source_mtime =~ ^[0-9]+$ ]] || return 64
    [ ! -e "$(_cr_pending_file)" ] && [ ! -e "$(_cr_active_file)" ] || return 75
    id=$(_cr_uuid) || return 70; now=$(_cr_now); owner=$(_cr_owner_json)
    req=$(jq -cn --arg id "$id" --arg type "$type" --arg source "$source" --arg reason "$reason" --arg source_path "$source_path" --arg source_mtime "$source_mtime" --argjson now "$now" --argjson owner "$owner" \
        '{id:$id,type:$type,source:$source,reason:$reason,status:"PENDING",created_at:$now,owner:$owner} + (if $source_path == "" then {} else {source_path:$source_path} end) + (if $source_mtime == "" then {} else {source_mtime:($source_mtime|tonumber)} end)') || return 70
    _cr_atomic_write "$(_cr_pending_file)" "$req" || return 70
    printf '%s\n' "$id"
}

cam_request_submit() {
    _cr_owner_available || return $?
    _cr_lock_call _cr_request_new "$@"
}

_cr_claim_locked() {
    local pending
    cam_owner_assert || return 69
    [ -f "$(_cr_pending_file)" ] || return 69
    [ ! -e "$(_cr_active_file)" ] || return 75
    pending=$(cat "$(_cr_pending_file)") || return 70
    jq -e '.id and .type and .source and .reason' >/dev/null <<<"$pending" || return 70
    _cr_record_owner_matches "$pending" || return 69
    mkdir -p "$(_cr_recovery_dir)" || return 70
    mv "$(_cr_pending_file)" "$(_cr_active_file)" && sync -d "$(_cr_recovery_dir)" || return 70
}

cam_request_claim() { _cr_lock_call _cr_claim_locked; }

_cr_transition_allowed() {
    case "$1:$2" in
        PENDING:QUIESCING|QUIESCING:RUNNING|RUNNING:VERIFYING|VERIFYING:SUCCEEDED|VERIFYING:FAILED|RUNNING:FAILED|QUIESCING:FAILED) return 0;;
    esac
    return 1
}

_cr_transition_locked() {
    local next=$1 active current updated
    cam_owner_assert || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    _cr_record_owner_matches "$active" || return 69
    current=$(jq -r '.status' <<<"$active")
    _cr_transition_allowed "$current" "$next" || return 64
    updated=$(jq -c --arg next "$next" --argjson now "$(_cr_now)" '.status=$next | .updated_at=$now' <<<"$active") || return 70
    _cr_atomic_write "$(_cr_active_file)" "$updated" || return 70
}

cam_request_transition() { [ $# -eq 1 ] || return 64; _cr_lock_call _cr_transition_locked "$1"; }

_cr_state_template() {
    jq -cn '{actions:{gstapp_restart:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},module_reload:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},camera_hard_reset:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},reboot_fallback:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null}}}'
}

_cr_state_init() {
    [ -f "$(_cr_state_file)" ] && { jq -e '.actions|type == "object"' "$(_cr_state_file)" >/dev/null 2>&1 || return 1; return 0; }
    _cr_atomic_write "$(_cr_state_file)" "$(_cr_state_template)"
}

_cr_counter_begin_locked() {
    local action=$1 id=$2 active state updated
    _cr_public_action "$action" || return 64
    cam_owner_assert || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    _cr_record_owner_matches "$active" || return 69
    [ "$(jq -r .status <<<"$active")" = RUNNING ] || return 64
    _cr_state_init || return 70
    state=$(cat "$(_cr_state_file)") || return 70
    updated=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$(_cr_now)" '.actions[$action].attempted += 1 | .actions[$action].last_request_id=$id | .actions[$action].last_started_at=$now | .actions[$action].last_status="RUNNING" | .actions[$action].last_rc=null' <<<"$state") || return 70
    _cr_atomic_write "$(_cr_state_file)" "$updated" || return 70
}

cam_action_counter_begin() { [ $# -eq 2 ] || return 64; _cr_lock_call _cr_counter_begin_locked "$@"; }

_cr_counter_finish_locked() {
    local action=$1 id=$2 status=$3 rc=$4 active state updated
    _cr_public_action "$action" || return 64
    [ "$status" = SUCCEEDED ] || [ "$status" = FAILED ] || return 64
    [[ $rc =~ ^[0-9]+$ ]] || return 64
    cam_owner_assert || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    _cr_record_owner_matches "$active" || return 69
    [ "$(jq -r .id <<<"$active")" = "$id" ] || return 64
    case "$(jq -r .status <<<"$active")" in RUNNING|VERIFYING) ;; *) return 64;; esac
    _cr_state_init || return 70; state=$(cat "$(_cr_state_file)") || return 70
    updated=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$(_cr_now)" '
      .actions[$action].last_request_id=$id | .actions[$action].last_finished_at=$now | .actions[$action].last_status=$status | .actions[$action].last_rc=$rc |
      if $status == "SUCCEEDED" then .actions[$action].succeeded += 1 | .actions[$action].consecutive_failures=0 else .actions[$action].failed += 1 | .actions[$action].consecutive_failures += 1 end' <<<"$state") || return 70
    _cr_atomic_write "$(_cr_state_file)" "$updated" || return 70
}

cam_action_counter_finish() { [ $# -eq 4 ] || return 64; _cr_lock_call _cr_counter_finish_locked "$@"; }

_cr_finish_locked() {
    local status=$1 rc=$2 active id result history terminal
    [ "$status" = SUCCEEDED ] || [ "$status" = FAILED ] || return 64
    [[ $rc =~ ^[0-9]+$ ]] || return 64
    cam_owner_assert || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    _cr_record_owner_matches "$active" || return 69
    id=$(jq -r .id <<<"$active")
    terminal=$(jq -c --arg status "$status" --argjson rc "$rc" --argjson now "$(_cr_now)" '.status=$status | .rc=$rc | .finished_at=$now' <<<"$active") || return 70
    result=$(jq -c '{id,type,status,rc,source,reason,created_at,finished_at} + (if has("source_path") then {source_path} else {} end) + (if has("source_mtime") then {source_mtime} else {} end)' <<<"$terminal") || return 70
    history=$(jq -cn --argjson request "$terminal" '{request:$request,actions:[]}') || return 70
    _cr_atomic_write "$(_cr_result_file "$id")" "$result" || return 70
    _cr_atomic_write "$(_cr_history_file "$id")" "$history" || return 70
    _cr_remove "$(_cr_active_file)" || return 70
}

cam_request_finish() { [ $# -eq 2 ] || return 64; _cr_lock_call _cr_finish_locked "$@"; }

_cr_mark_dirty() {
    local current updated
    current=$(cat "$(_cr_service_file)" 2>/dev/null || printf '{}')
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$current" || return 1
    updated=$(jq -c --argjson now "$(_cr_now)" '.dirty=true | .dirty_at=$now' <<<"$current") || return 1
    _cr_atomic_write "$(_cr_service_file)" "$updated"
}

_cr_embedded_owner_valid() {
    local file=$1 owner current invocation token
    owner=$(jq -c '.request.owner' "$file" 2>/dev/null) || return 1
    current=$(_cr_owner_json) || return 1
    jq -e --argjson saved "$owner" --argjson current "$current" '
      $saved.boot_id == $current.boot_id and $saved.invocation_id == $current.invocation_id and
      $saved.pid == $current.pid and $saved.proc_start_time == $current.proc_start_time and $saved.token == $current.token
    ' >/dev/null || return 1
    invocation=$(jq -r '.invocation_id // empty' <<<"$owner")
    token=$(jq -r '.token // empty' <<<"$owner")
    [ -n "$invocation" ] && [ -n "$token" ] && cam_owner_assert "$invocation" "$token"
}

cam_reconcile_interrupted() {
    local file history updated changed=0
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history" || return 70
    shopt -s nullglob
    for file in "$PIM_CAMERA_STATE_DIR"/recovery/history/*.json; do
        history=$(cat "$file") || return 70
        case "$(jq -r '.request.status // empty' <<<"$history")" in SUCCEEDED|FAILED) continue;; esac
        _cr_embedded_owner_valid "$file" && continue
        updated=$(jq -c --argjson now "$(_cr_now)" '.request.status="FAILED" | .request.rc=70 | .request.interrupted=true | .request.finished_at=$now | .request.interrupted_reason="interrupted"' <<<"$history") || return 70
        _cr_atomic_write "$file" "$updated" || return 70
        changed=1
    done
    shopt -u nullglob
    [ "$changed" -eq 0 ] || _cr_mark_dirty || return 70
}

cam_recovery_status_json() {
    local request_id=${1:-} owner pending active state result
    if [ -n "$request_id" ]; then
        result=$(cat "$(_cr_result_file "$request_id")" 2>/dev/null) || return 69
        printf '%s\n' "$result"
        return 0
    fi
    owner=$(cat "$(_cr_owner_file)" 2>/dev/null || printf 'null')
    pending=$(cat "$(_cr_pending_file)" 2>/dev/null || printf 'null')
    active=$(cat "$(_cr_active_file)" 2>/dev/null || printf 'null')
    state=$(cat "$(_cr_state_file)" 2>/dev/null || printf 'null')
    jq -cn --argjson owner "$owner" --argjson pending "$pending" --argjson active "$active" --argjson state "$state" '{owner:$owner,pending:$pending,active:$active,state:$state}'
}
