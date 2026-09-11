#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-cam-operate-control.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_CAMERA_SOURCE_ROOT="$WORK/source"
export PIM_CAMERA_RUNTIME_JSON="$PIM_CAMERA_RUN_DIR/config/pim_runtime.json"
export PIM_CAMERA_REAL_RUNTIME_HELPER="$PIM_BIN/camera_runtime_config.py"
export PIM_CAMERA_RUNTIME_HELPER="$WORK/runtime-helper.py"
export PIM_CAMERA_CONTROL_WORK_DIR="$PIM_CAMERA_RUN_DIR/control"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_HELPER_LOG="$WORK/helper-calls"
EDGE_TEMPLATE="$ROOT/dist/pim/opt/pim/config/edgeconf_pim_base.json"
ORD_TEMPLATE="$ROOT/dist/pim/opt/pim/config/ord_vcm_conf.json"
DAEMON_PID=4242

cat > "$PIM_CAMERA_RUNTIME_HELPER" <<'PY'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["PIM_CAMERA_HELPER_LOG"], "a", encoding="utf-8") as output:
    output.write(sys.argv[1] + "\n")
os.execv(sys.executable, [sys.executable, os.environ["PIM_CAMERA_REAL_RUNTIME_HELPER"], *sys.argv[1:]])
PY

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() {
    local wanted=$1
    shift
    set +e
    "$@"
    local got=$?
    set -e
    [ "$got" -eq "$wanted" ] || fail "expected rc=$wanted got=$got: $*"
}
expect_log() { grep -Fqx "$1" "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "missing log: $1"; }; }
reject_log() { ! grep -Fqx "$1" "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "unexpected log: $1"; }; }
count_log() { grep -Fxc "$1" "$PIM_CAMERA_CALL_LOG" 2>/dev/null || true; }
fake_stat() {
    local start=${1:-111}
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$start"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
}
write_source() {
    local marker=${1:-source} width=${2:-640} ord=${3:-one} vcm=${4:-one} policy=${5:-one}
    mkdir -p "$PIM_CAMERA_SOURCE_ROOT"
    jq --arg marker "$marker" --argjson width "$width" '
        .VHL_CAM.cam_width=$width |
        .VHL_CAM.cam_height=360 |
        .VHL_CAM.fps=30 |
        .VHL_CAM.label=$marker |
        {VHL_CAM:.VHL_CAM}
    ' "$EDGE_TEMPLATE" > "$PIM_CAMERA_SOURCE_ROOT/edgeconf_${marker}.json"
    jq --arg ord "$ord" --arg vcm "$vcm" --arg policy "$policy" '
        .ORD.value=$ord |
        .VCM.value=$vcm |
        .ETC.policy=$policy |
        .EXTRA={kept:true}
    ' "$ORD_TEMPLATE" > "$PIM_CAMERA_SOURCE_ROOT/ord_vcm_conf.json"
}
publish_source_for_setup() {
    local candidate="$WORK/setup-candidate.json" result="$WORK/setup-result.json"
    python3 "$PIM_CAMERA_RUNTIME_HELPER" stage --source-root "$PIM_CAMERA_SOURCE_ROOT" --candidate "$candidate" --result "$result"
    python3 "$PIM_CAMERA_RUNTIME_HELPER" publish --candidate "$candidate" --runtime-dir "$(dirname "$PIM_CAMERA_RUNTIME_JSON")"
}
reset_case() {
    local boot=${1:-boot-a}
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_SOURCE_ROOT" "$PIM_CAMERA_PROC_ROOT"
    mkdir -p "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_SOURCE_ROOT"
    printf '%s\n' "$boot" > "$PIM_CAMERA_BOOT_ID_FILE"
    : > "$PIM_CAMERA_CALL_LOG"
    : > "$PIM_CAMERA_HELPER_LOG"
    fake_stat
    unset FAIL_ACTION FAIL_VERIFY FAIL_PUBLISH
    unset VERIFY_STARTUP_EXECUTOR VERIFY_REQUEST_EXECUTOR VERIFY_OWNER_LIFECYCLE
    unset PROCESS_VERIFY_STARTUP_EXECUTOR PROCESS_VERIFY_REQUEST_EXECUTOR PROCESS_VERIFY_OWNER_LIFECYCLE
}
service_state() {
    mkdir -p "$PIM_CAMERA_STATE_DIR"
    printf '%s\n' "$1" > "$PIM_CAMERA_STATE_DIR/service-state.json"
}
submit_apply() {
    LAST_REQUEST_ID=$(cam_request_submit apply_config test "$1")
    cam_poll_pending_request
}

CONTROL="$PIM_LIB/cam_operate_control.sh"
[ -f "$CONTROL" ] || fail "Task 4 control library is missing: $CONTROL"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery.sh"
# shellcheck source=/dev/null
source "$CONTROL"

# Protocol durability is covered in recovery_protocol_test.sh; avoid slow fsync
# here while retaining the real owner/lifecycle/request state machines.
_cr_fsync_file() { :; }
_cr_fsync_dir() { :; }

_cr_test_startup_reservation_probe() {
    [ "${STARTUP_RACE_PROBE:-}" = 1 ] || return 0
    STARTUP_RACE_PROBE=0
    STARTUP_PROBE_OWNER=$(jq -c '{boot_id,invocation_id,pid,proc_start_time,token,created_at}' "$PIM_CAMERA_RUN_DIR/owner.json")
    STARTUP_PROBE_LIFECYCLE=$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")
    STARTUP_PROBE_ACTIVE=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json" 2>/dev/null || printf null)
    STARTUP_PROBE_PENDING=$([ -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && printf present || printf absent)
    STARTUP_PROBE_RC=0
    cam_request_submit apply_config external "startup reservation race" >/dev/null || STARTUP_PROBE_RC=$?
    return 0
}
cam_owner_set_lifecycle() {
    local next=$1 rc
    _cr_lock_call _cr_owner_set_lifecycle_locked "$next"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ "$next" = ACTIVE ]; then _cr_test_startup_reservation_probe; fi
}

cam_initial_module_load() { printf 'action:initial_module_load\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_action_module_reload() { printf 'action:module_reload\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_action_camera_hard_reset() { printf 'action:camera_hard_reset\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_execute_action_step() {
    local request_type rc
    request_type=$(jq -r '.type // empty' "$PIM_CAMERA_RUN_DIR/recovery/active.json" 2>/dev/null)
    if [ "$request_type" = apply_config ]; then
        [ "${PIM_CAMERA_CONSUMERS_QUIESCED:-}" = 1 ] || return 91
        cam_consumers_prequiesced || return 94
    else
        [ -z "${PIM_CAMERA_CONSUMERS_QUIESCED:-}" ] || return 92
    fi
    if [ "${EXPECT_DIRTY_DURING_ACTION:-}" = "$1" ]; then
        jq -e '.dirty == true' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || return 93
    fi
    if [ "${REAL_COUNTER_STUB:-}" = 1 ]; then
        cam_action_counter_begin "$1" "$PIM_CAMERA_REQUEST_ID" || return $?
    fi
    printf 'action:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"
    rc=0
    [ "${FAIL_ACTION:-}" != "$1" ] || rc=1
    if [ "${REAL_COUNTER_STUB:-}" = 1 ]; then
        if [ "$rc" -eq 0 ]; then cam_action_counter_finish "$1" "$PIM_CAMERA_REQUEST_ID" SUCCEEDED 0 || return $?; else cam_action_counter_finish "$1" "$PIM_CAMERA_REQUEST_ID" FAILED "$rc" || return $?; fi
    fi
    return "$rc"
}
cam_quiesce_gstapp() { cam_executor_assert_context || return $?; printf 'quiesce:gstapp\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_quiesce_consumers() { cam_executor_assert_context || return $?; printf 'quiesce:consumers\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_stop_process() { cam_executor_assert_context || return $?; printf 'quiesce:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; }
cam_restart_ord() { printf 'start:ord\n' >> "$PIM_CAMERA_CALL_LOG"; [ "${FAIL_ACTION:-}" != ord_restart ]; }
cam_restart_vcm() { printf 'start:vcm\n' >> "$PIM_CAMERA_CALL_LOG"; [ "${FAIL_ACTION:-}" != vcm_restart ]; }
cam_start_gstapp() { printf 'start:gstapp\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_wait_process_ready() {
    PROCESS_VERIFY_STARTUP_EXECUTOR=${PIM_CAMERA_STARTUP_EXECUTOR:-}
    PROCESS_VERIFY_REQUEST_EXECUTOR=${PIM_CAMERA_EXECUTOR:-}
    PROCESS_VERIFY_OWNER_LIFECYCLE=$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json") || return 69
    cam_executor_assert_context || return $?
    printf 'verify:processes:%s\n' "${2:-0}" >> "$PIM_CAMERA_CALL_LOG"
    [ "${FAIL_VERIFY:-}" != process ]
}
cam_verify_camera_ready() {
    VERIFY_STARTUP_EXECUTOR=${PIM_CAMERA_STARTUP_EXECUTOR:-}
    VERIFY_REQUEST_EXECUTOR=${PIM_CAMERA_EXECUTOR:-}
    VERIFY_OWNER_LIFECYCLE=$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json") || return 69
    cam_executor_assert_context || return $?
    printf 'verify:camera\n' >> "$PIM_CAMERA_CALL_LOG"
    [ "${FAIL_VERIFY:-}" != camera ]
}
_coc_policy_reload() { printf 'action:policy_reload\n' >> "$PIM_CAMERA_CALL_LOG"; [ "${FAIL_ACTION:-}" != policy_reload ]; }

echo "=== new-boot startup transaction ==="
reset_case boot-a
write_source new 640
expect_rc 0 cam_daemon_startup "$DAEMON_PID"
[ "$VERIFY_STARTUP_EXECUTOR" = 1 ] || fail "new boot verification lacked startup executor authority"
[ "$VERIFY_OWNER_LIFECYCLE" = STARTING ] || fail "new boot verification did not retain STARTING owner"
[ -z "$VERIFY_REQUEST_EXECUTOR" ] || fail "new boot verification used request executor authority"
[ "$PROCESS_VERIFY_STARTUP_EXECUTOR" = 1 ] || fail "new boot process verification lacked startup executor authority"
[ "$PROCESS_VERIFY_OWNER_LIFECYCLE" = STARTING ] || fail "new boot process verification did not retain STARTING owner"
[ -z "$PROCESS_VERIFY_REQUEST_EXECUTOR" ] || fail "new boot process verification used request executor authority"
[ -z "${PIM_CAMERA_STARTUP_EXECUTOR+x}" ] || fail "new boot retained startup executor after successful verification"
[ "$(grep -c '^stage$' "$PIM_CAMERA_HELPER_LOG")" -eq 1 ] || fail "new boot did not stage exactly once"
[ "$(count_log action:initial_module_load)" -eq 1 ] || fail "new boot did not initialize modules exactly once"
expect_log start:ord
expect_log start:vcm
expect_log start:gstapp
expect_log verify:camera
expect_log verify:processes:1
jq -e '.lifecycle == "ACTIVE" and .pid == 4242' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "startup owner not ACTIVE"
jq -e '.schema == 1 and .last_boot_id == "boot-a" and (.last_successful_hardware_projection.cam_width == 640) and .dirty == false and .degraded_reason == null and .degraded_target == null and (.last_invocation_id | strings)' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "new boot state projection"
[ -f "$PIM_CAMERA_RUNTIME_JSON" ] || fail "startup did not publish runtime"

echo "=== live owner acquisition is fail closed ==="
live_pending_id=$(cam_request_submit apply_config operator "must survive second startup")
mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history" "$PIM_CAMERA_RUN_DIR/recovery/results"
printf '{"sentinel":"history"}\n' > "$PIM_CAMERA_STATE_DIR/recovery/history/live-owner-sentinel.json"
printf '{"sentinel":"result"}\n' > "$PIM_CAMERA_RUN_DIR/recovery/results/live-owner-sentinel.json"
printf '{"sentinel":"counter"}\n' > "$PIM_CAMERA_STATE_DIR/recovery/state.json"
owner_before=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
service_before=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
runtime_before=$(cksum "$PIM_CAMERA_RUNTIME_JSON")
pending_before=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
history_before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/live-owner-sentinel.json")
result_before=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/live-owner-sentinel.json")
counter_before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
: > "$PIM_CAMERA_CALL_LOG"
: > "$PIM_CAMERA_HELPER_LOG"
expect_rc 75 cam_daemon_startup "$DAEMON_PID"
[ "$owner_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "live-owner rejection mutated owner"
[ "$service_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "live-owner rejection mutated service state"
[ "$runtime_before" = "$(cksum "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "live-owner rejection mutated runtime"
[ "$pending_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/pending.json")" ] || fail "live-owner rejection mutated pending lease"
[ "$history_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/live-owner-sentinel.json")" ] || fail "live-owner rejection mutated existing history"
[ "$result_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/live-owner-sentinel.json")" ] || fail "live-owner rejection mutated existing result"
[ "$counter_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "live-owner rejection mutated existing counters"
[ "$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")" = "$live_pending_id" ] || fail "live-owner rejection replaced pending request"
[ ! -e "$PIM_CAMERA_STATE_DIR/recovery/history/$live_pending_id.json" ] || fail "live-owner rejection created history"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/results/$live_pending_id.json" ] || fail "live-owner rejection created result"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail "live-owner rejection acted on consumers"
[ ! -s "$PIM_CAMERA_HELPER_LOG" ] || fail "live-owner rejection staged or published config"

echo "=== new-boot verification failure clears startup authority ==="
reset_case boot-failed-verify
write_source failed-verify 640
FAIL_VERIFY=process
expect_rc 1 cam_daemon_startup "$DAEMON_PID"
[ "$VERIFY_STARTUP_EXECUTOR" = 1 ] || fail "failed new-boot verification lacked startup executor authority"
[ "$VERIFY_OWNER_LIFECYCLE" = STARTING ] || fail "failed new-boot verification did not retain STARTING owner"
[ -z "$VERIFY_REQUEST_EXECUTOR" ] || fail "failed new-boot verification used request executor authority"
[ "$PROCESS_VERIFY_STARTUP_EXECUTOR" = 1 ] || fail "failed new-boot process verification lacked startup executor authority"
[ "$PROCESS_VERIFY_OWNER_LIFECYCLE" = STARTING ] || fail "failed new-boot process verification did not retain STARTING owner"
[ -z "$PROCESS_VERIFY_REQUEST_EXECUTOR" ] || fail "failed new-boot process verification used request executor authority"
[ -z "${PIM_CAMERA_STARTUP_EXECUTOR+x}" ] || fail "new boot retained startup executor after failed verification"
jq -e '.lifecycle == "DEGRADED"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "failed verification lifecycle"
jq -e '.dirty == true and .degraded_reason == "startup_verify_failed"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "failed verification state"

echo "=== startup source failure has no side effects ==="
reset_case boot-a
expect_rc 64 cam_daemon_startup "$DAEMON_PID"
[ ! -e "$PIM_CAMERA_RUNTIME_JSON" ] || fail "source failure published runtime"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "source failure started a consumer/action"; }
jq -e '.lifecycle == "DEGRADED"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "source failure lifecycle"

echo "=== same-boot restart always re-stages and reloads ==="
reset_case boot-a
write_source restart 640
cam_daemon_startup "$DAEMON_PID"
manual=$(mktemp "$WORK/manual.XXXXXX")
jq '.VHL_CAM.label="manual-edit"' "$PIM_CAMERA_RUNTIME_JSON" > "$manual" && mv "$manual" "$PIM_CAMERA_RUNTIME_JSON"
: > "$PIM_CAMERA_CALL_LOG"
: > "$PIM_CAMERA_HELPER_LOG"
fake_stat 222
STARTUP_RACE_PROBE=1
STARTUP_PROBE_RC=
STARTUP_PROBE_OWNER=
STARTUP_PROBE_LIFECYCLE=
STARTUP_PROBE_ACTIVE=
STARTUP_PROBE_PENDING=
REAL_COUNTER_STUB=1
set +e
cam_daemon_startup "$DAEMON_PID"
restart_rc=$?
set -e
unset REAL_COUNTER_STUB
[ "$STARTUP_PROBE_RC" = 75 ] || fail "external apply entered former ACTIVE-before-submit boundary rc=${STARTUP_PROBE_RC:-missing}"
[ "$restart_rc" -eq 0 ] || fail "reserved same-boot startup failed rc=$restart_rc"
[ -z "$VERIFY_STARTUP_EXECUTOR" ] || fail "same-boot verification retained startup executor authority"
[ "$VERIFY_REQUEST_EXECUTOR" = 1 ] || fail "same-boot verification lacked request executor authority"
[ "$VERIFY_OWNER_LIFECYCLE" = RECOVERING ] || fail "same-boot verification did not retain RECOVERING owner"
[ -z "$PROCESS_VERIFY_STARTUP_EXECUTOR" ] || fail "same-boot process verification retained startup executor authority"
[ "$PROCESS_VERIFY_REQUEST_EXECUTOR" = 1 ] || fail "same-boot process verification lacked request executor authority"
[ "$PROCESS_VERIFY_OWNER_LIFECYCLE" = RECOVERING ] || fail "same-boot process verification did not retain RECOVERING owner"
[ -z "${PIM_CAMERA_STARTUP_EXECUTOR+x}" ] || fail "same-boot restart leaked startup executor authority"
[ "$STARTUP_PROBE_OWNER" = "$(jq -c '{boot_id,invocation_id,pid,proc_start_time,token,created_at}' "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "startup reservation changed daemon identity"
[ "$STARTUP_PROBE_LIFECYCLE" = RECOVERING ] || fail "startup reservation did not publish private RECOVERING after active"
[ "$STARTUP_PROBE_PENDING" = absent ] || fail "startup reservation left a pending request"
jq -e --argjson owner "$STARTUP_PROBE_OWNER" '.type=="module_reload" and .status=="PENDING" and ({boot_id:.owner.boot_id,invocation_id:.owner.invocation_id,pid:.owner.pid,proc_start_time:.owner.proc_start_time,token:.owner.token,created_at:.owner.created_at}==$owner)' >/dev/null <<<"$STARTUP_PROBE_ACTIVE" || fail "private RECOVERING was not backed by the reserved active identity"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "external startup-race request occupied pending lease"
[ "$(grep -c '^stage$' "$PIM_CAMERA_HELPER_LOG")" -eq 1 ] || fail "same-boot restart did not re-stage exactly once"
[ "$(count_log action:module_reload)" -eq 1 ] || fail "same-boot restart did not module-reload exactly once"
[ "$(jq -r .VHL_CAM.label "$PIM_CAMERA_RUNTIME_JSON")" = restart ] || fail "restart used manual runtime as source/fallback"
startup_history=$(grep -rl '"type":"module_reload"' "$PIM_CAMERA_STATE_DIR/recovery/history" 2>/dev/null || true)
[ -n "$startup_history" ] || fail "same-boot public action was not attributed to a request history"
jq -e '[.actions[].action] == ["module_reload"] and [.actions[].status] == ["SUCCEEDED"]' "$startup_history" >/dev/null || fail "same-boot startup action history did not complete"
jq -e '.actions.module_reload.attempted==1 and .actions.module_reload.succeeded==1' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "same-boot startup action counter did not complete"

echo "=== partial startup reservation is recoverable and never ACTIVE ==="
reset_case boot-a
write_source partial-history 640
cam_daemon_startup "$DAEMON_PID"
fake_stat 222
: > "$PIM_CAMERA_CALL_LOG"
PIM_CAMERA_TEST_FAILPOINT=startup_reserve_after_history
export PIM_CAMERA_TEST_FAILPOINT
expect_rc 70 cam_daemon_startup "$DAEMON_PID"
unset PIM_CAMERA_TEST_FAILPOINT
partial_history_file=$(grep -rl '"source":"startup"' "$PIM_CAMERA_STATE_DIR/recovery/history" | tail -1)
[ -n "$partial_history_file" ] || fail "after-history reservation lost internal history"
partial_history_id=$(jq -r .request.id "$partial_history_file")
jq -e '.lifecycle=="STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "after-history reservation exposed RECOVERING/ACTIVE"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "after-history reservation exposed a partial lease"
partial_history_owner=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
partial_history_bytes=$(cksum "$partial_history_file")
expect_rc 69 cam_request_submit apply_config external "after-history intake"
[ "$partial_history_owner" = "$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "after-history intake mutated owner"
[ "$partial_history_bytes" = "$(cksum "$partial_history_file")" ] || fail "after-history intake mutated history"
fake_stat 333
cam_daemon_startup "$DAEMON_PID"
jq -e --arg id "$partial_history_id" '.request.id==$id and .request.status=="FAILED" and .request.interrupted==true' "$partial_history_file" >/dev/null || fail "after-history retry did not terminalize orphan history"
[ "$(count_log action:camera_hard_reset)" -eq 1 ] || fail "after-history retry did not use dirty hard reset"
jq -e '.lifecycle=="ACTIVE"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "after-history retry did not recover"

reset_case boot-a
write_source partial 640
cam_daemon_startup "$DAEMON_PID"
fake_stat 222
: > "$PIM_CAMERA_CALL_LOG"
PIM_CAMERA_TEST_FAILPOINT=startup_reserve_after_active
export PIM_CAMERA_TEST_FAILPOINT
expect_rc 70 cam_daemon_startup "$DAEMON_PID"
unset PIM_CAMERA_TEST_FAILPOINT
partial_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/active.json")
jq -e '.lifecycle=="STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "partial startup reservation exposed ACTIVE"
jq -e '.status=="PENDING"' "$PIM_CAMERA_RUN_DIR/recovery/active.json" >/dev/null || fail "partial startup reservation lost claimed lease"
jq -e '.dirty==true' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "partial startup reservation was not dirty"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail "partial startup reservation executed action"
partial_owner_before_intake=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
partial_active_before_intake=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/active.json")
expect_rc 69 cam_request_submit apply_config external "after-active intake"
[ "$partial_owner_before_intake" = "$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "after-active intake mutated owner"
[ "$partial_active_before_intake" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail "after-active intake mutated active"
fake_stat 333
cam_daemon_startup "$DAEMON_PID"
jq -e --arg id "$partial_id" '.id==$id and .status=="FAILED" and .rc==70' "$PIM_CAMERA_RUN_DIR/recovery/results/$partial_id.json" >/dev/null || fail "partial startup reservation did not produce terminal result"
jq -e '.request.status=="FAILED" and .request.interrupted==true and (.actions|length)==0' "$PIM_CAMERA_STATE_DIR/recovery/history/$partial_id.json" >/dev/null || fail "partial startup reservation did not reconcile history"
[ "$(count_log action:camera_hard_reset)" -eq 1 ] || fail "partial startup retry did not use dirty hard reset"
jq -e '.lifecycle=="ACTIVE"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "partial startup retry did not recover"

echo "=== restart hard-reset classification ==="
for mode in projection_changed projection_absent state_corrupt dirty interrupted_history; do
    reset_case boot-a
    write_source base 640
    cam_daemon_startup "$DAEMON_PID"
    case "$mode" in
        projection_changed) rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_base.json"; write_source changed 800 ;;
        projection_absent) jq 'del(.last_successful_hardware_projection)' "$PIM_CAMERA_STATE_DIR/service-state.json" > "$WORK/state.next" && mv "$WORK/state.next" "$PIM_CAMERA_STATE_DIR/service-state.json" ;;
        state_corrupt) printf '{bad json}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json" ;;
        dirty) jq '.dirty=true' "$PIM_CAMERA_STATE_DIR/service-state.json" > "$WORK/state.next" && mv "$WORK/state.next" "$PIM_CAMERA_STATE_DIR/service-state.json" ;;
        interrupted_history)
            old_owner=$(cat "$PIM_CAMERA_RUN_DIR/owner.json")
            mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history"
            jq -cn --argjson owner "$old_owner" '{request:{id:"interrupted",status:"RUNNING",owner:$owner},actions:[]}' > "$PIM_CAMERA_STATE_DIR/recovery/history/interrupted.json"
            ;;
    esac
    : > "$PIM_CAMERA_CALL_LOG"
    fake_stat 222
    cam_daemon_startup "$DAEMON_PID"
    [ "$(count_log action:camera_hard_reset)" -eq 1 ] || fail "$mode did not hard reset"
done

echo "=== monitor reload follows the actually claimed apply request ==="
reset_case boot-a
write_source arrival-base 640 one one one
cam_daemon_startup "$DAEMON_PID"
rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_arrival-base.json"
write_source arrival-new 640 two one one
: > "$PIM_CAMERA_CALL_LOG"
reload_calls=0
reload_observed=
inject_apply_before_poll=1
arrival_request_id=
monitor_reload_from_runtime() {
    reload_calls=$((reload_calls + 1))
    reload_observed=$(jq -r '.VHL_CAM.label // empty' "$PIM_CAMERA_RUNTIME_JSON")
}
cam_liveness_tick() { :; }
eval "$(declare -f cam_poll_pending_request | sed '1s/cam_poll_pending_request/cam_poll_pending_request_without_arrival/')"
cam_poll_pending_request() {
    if [ "$inject_apply_before_poll" -eq 1 ]; then
        inject_apply_before_poll=0
        [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "arrival race did not enter without pending"
        arrival_request_id=$(cam_request_submit apply_config test "arrival before poll")
    fi
    cam_poll_pending_request_without_arrival
}
expect_rc 0 cam_monitor_control_iteration monitor_reload_from_runtime
executed_type=$(jq -r .type "$PIM_CAMERA_RUN_DIR/recovery/results/$arrival_request_id.json")
if [ "$reload_calls" -ne 1 ]; then
    printf 'ROUND3_RED: executed_type=%s reload_calls=%s\n' "$executed_type" "$reload_calls" >&2
    fail "actually executed apply request did not reload daemon configuration exactly once"
fi
jq -e '.type=="apply_config" and .status=="SUCCEEDED" and .rc==0' "$PIM_CAMERA_RUN_DIR/recovery/results/$arrival_request_id.json" >/dev/null || fail "arrival request did not execute successfully"
[ "${PIM_CAMERA_MONITOR_WORK_TYPE:-}" = apply_config ] || fail "monitor did not expose the actually executed apply type"
[ "$reload_observed" = arrival-new ] || fail "reload callback observed stale runtime configuration"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "arrival request retained a lease"
expect_rc 1 cam_monitor_control_iteration monitor_reload_from_runtime
[ "$reload_calls" -eq 1 ] || fail "no-work iteration reused the prior apply type"
[ -z "${PIM_CAMERA_MONITOR_WORK_TYPE:-}" ] || fail "no-work iteration retained stale work type"

echo "=== apply validation and owner/lease continuity ==="
reset_case boot-a
write_source active 640
cam_daemon_startup "$DAEMON_PID"
owner_before=$(jq -c '{boot_id,invocation_id,pid,proc_start_time,token,created_at}' "$PIM_CAMERA_RUN_DIR/owner.json")
rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_active.json"
printf '{bad json}\n' > "$PIM_CAMERA_SOURCE_ROOT/edgeconf_bad.json"
runtime_before=$(cksum "$PIM_CAMERA_RUNTIME_JSON")
: > "$PIM_CAMERA_CALL_LOG"
apply_id=$(cam_request_submit apply_config test invalid)
expect_rc 64 cam_poll_pending_request
[ "$runtime_before" = "$(cksum "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "invalid apply replaced runtime"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail "invalid apply quiesced or acted"
jq -e '.status == "FAILED" and .rc == 64' "$PIM_CAMERA_RUN_DIR/recovery/results/$apply_id.json" >/dev/null || fail "invalid apply result"
[ "$owner_before" = "$(jq -c '{boot_id,invocation_id,pid,proc_start_time,token,created_at}' "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "apply replaced owner tuple"

echo "=== valid apply union, order, persistence, and no rollback ==="
rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_bad.json"
write_source union 640 two two two
: > "$PIM_CAMERA_CALL_LOG"
: > "$PIM_CAMERA_HELPER_LOG"
submit_apply union
[ "$(grep -c '^plan$' "$PIM_CAMERA_HELPER_LOG")" -eq 1 ] || fail "apply did not calculate semantic plan exactly once"
expected=$'quiesce:consumers\naction:gstapp_restart\nstart:ord\nstart:vcm\naction:policy_reload\nverify:camera\nverify:processes:1'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "apply union/order"; }
jq -e '[.actions[].action] == ["ord_restart","vcm_restart","policy_reload"] and all(.actions[]; .countered == false)' "$PIM_CAMERA_STATE_DIR/recovery/history/$LAST_REQUEST_ID.json" >/dev/null || fail "uncountered apply history"
jq -e '(.request.source_path | strings) and (.request.source_mtime | numbers)' "$PIM_CAMERA_STATE_DIR/recovery/history/$LAST_REQUEST_ID.json" >/dev/null || fail "apply source metadata history"
jq -e '.lifecycle == "ACTIVE"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "valid apply lifecycle"
jq -e '.dirty == false and .degraded_target == null and .last_successful_hardware_projection.cam_width == 640' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "valid apply state"

rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_union.json"
write_source failed 640 three two two
: > "$PIM_CAMERA_CALL_LOG"
FAIL_ACTION=ord_restart expect_rc 1 submit_apply post-publish-failure
[ "$(jq -r .ORD.value "$PIM_CAMERA_RUNTIME_JSON")" = three ] || fail "post-publish failure rolled runtime back"
jq -e '.lifecycle == "DEGRADED"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "post-publish failure lifecycle"
jq -e '.degraded_reason == "post-publish-failure" and .degraded_target == "ord"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "degraded reason/target"

echo "=== no-change apply behavior ==="
# Repair the failed target with a no-change apply from DEGRADED.
: > "$PIM_CAMERA_CALL_LOG"
unset FAIL_ACTION
submit_apply repair-ord
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = $'quiesce:ord\nstart:ord\nverify:camera\nverify:processes:1' ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "degraded ORD repair"; }

# ACTIVE no-change validates/publishes but performs no public action.
: > "$PIM_CAMERA_CALL_LOG"
submit_apply no-change
reject_log action:gstapp_restart
reject_log action:module_reload
reject_log action:camera_hard_reset
expect_log verify:camera

for target in vcm gstapp process camera_health; do
    jq --arg target "$target" '.lifecycle="DEGRADED"' "$PIM_CAMERA_RUN_DIR/owner.json" > "$WORK/owner.next" && mv "$WORK/owner.next" "$PIM_CAMERA_RUN_DIR/owner.json"
    jq --arg target "$target" '.degraded_reason="test" | .degraded_target=$target | .dirty=false' "$PIM_CAMERA_STATE_DIR/service-state.json" > "$WORK/state.next" && mv "$WORK/state.next" "$PIM_CAMERA_STATE_DIR/service-state.json"
    : > "$PIM_CAMERA_CALL_LOG"
    submit_apply "repair-$target"
    case "$target" in
        vcm) expect_log start:vcm ;;
        gstapp|process) expect_log action:gstapp_restart ;;
        camera_health) expect_log action:module_reload ;;
    esac
done

jq '.lifecycle="DEGRADED"' "$PIM_CAMERA_RUN_DIR/owner.json" > "$WORK/owner.next" && mv "$WORK/owner.next" "$PIM_CAMERA_RUN_DIR/owner.json"
jq '.degraded_reason="interrupted" | .degraded_target="ord" | .dirty=true' "$PIM_CAMERA_STATE_DIR/service-state.json" > "$WORK/state.next" && mv "$WORK/state.next" "$PIM_CAMERA_STATE_DIR/service-state.json"
: > "$PIM_CAMERA_CALL_LOG"
submit_apply dirty-repair
expect_log action:camera_hard_reset
reject_log start:ord

echo "=== automatic recovery preserves manual runtime ==="
manual=$(mktemp "$WORK/manual.XXXXXX")
jq '.VHL_CAM.label="manual-survives"' "$PIM_CAMERA_RUNTIME_JSON" > "$manual" && mv "$manual" "$PIM_CAMERA_RUNTIME_JSON"
: > "$PIM_CAMERA_CALL_LOG"
jq '.dirty=false' "$PIM_CAMERA_STATE_DIR/service-state.json" > "$WORK/state.next" && mv "$WORK/state.next" "$PIM_CAMERA_STATE_DIR/service-state.json"
EXPECT_DIRTY_DURING_ACTION=module_reload
export EXPECT_DIRTY_DURING_ACTION
cam_request_submit module_reload health "automatic recovery" >/dev/null
cam_poll_pending_request
unset EXPECT_DIRTY_DURING_ACTION
[ "$(jq -r .VHL_CAM.label "$PIM_CAMERA_RUNTIME_JSON")" = manual-survives ] || fail "automatic recovery re-staged source"
[ "$(count_log action:module_reload)" -eq 1 ] || fail "automatic recovery did not use current runtime"
jq -e '.dirty == false and .degraded_reason == null and .degraded_target == null' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "verified recovery did not clear service degradation"
: > "$PIM_CAMERA_CALL_LOG"
submit_apply overwrite-manual
[ "$(jq -r .VHL_CAM.label "$PIM_CAMERA_RUNTIME_JSON")" = failed ] || fail "apply did not overwrite manual runtime from source"

echo "=== hard reset preserves semantic policy union ==="
reset_case boot-a
write_source baseline 640 one one one
cam_daemon_startup "$DAEMON_PID"
rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_baseline.json"
write_source hardware-policy 800 one one two
: > "$PIM_CAMERA_CALL_LOG"
submit_apply hardware-policy
expected=$'quiesce:consumers\naction:camera_hard_reset\naction:policy_reload\nverify:camera\nverify:processes:1'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "hardware+ETC apply lost precedence union"; }

reset_case boot-a
write_source dirty-base 640 one one one
cam_daemon_startup "$DAEMON_PID"
jq '.dirty=true' "$PIM_CAMERA_STATE_DIR/service-state.json" > "$WORK/state.next" && mv "$WORK/state.next" "$PIM_CAMERA_STATE_DIR/service-state.json"
rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_dirty-base.json"
write_source dirty-policy 640 one one two
: > "$PIM_CAMERA_CALL_LOG"
submit_apply dirty-policy
[ "$(count_log action:camera_hard_reset)" -eq 1 ] || fail "dirty+ETC apply did not hard reset once"
[ "$(count_log action:policy_reload)" -eq 1 ] || fail "dirty+ETC apply discarded policy reload"
reject_log action:gstapp_restart
reject_log start:ord
reject_log start:vcm
[ "$(tail -3 "$PIM_CAMERA_CALL_LOG")" = $'action:policy_reload\nverify:camera\nverify:processes:1' ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "dirty+ETC policy/verify order"; }

reset_case boot-a
write_source hardware-base 640 one one one
cam_daemon_startup "$DAEMON_PID"
rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_hardware-base.json"
write_source hardware-only 800 one one one
: > "$PIM_CAMERA_CALL_LOG"
submit_apply hardware-only
[ "$(count_log action:camera_hard_reset)" -eq 1 ] || fail "hardware-only apply did not hard reset once"
reject_log action:policy_reload

echo "=== policy-only failure retries on identical apply ==="
reset_case boot-a
write_source policy-only 640 one one one
cam_daemon_startup "$DAEMON_PID"
write_source policy-only 640 one one two
: > "$PIM_CAMERA_CALL_LOG"
FAIL_ACTION=policy_reload expect_rc 1 submit_apply policy-only-failure
jq -e '.lifecycle=="DEGRADED"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "policy-only failure owner lifecycle"
jq -e '.dirty==false and .degraded_reason=="policy-only-failure" and .degraded_target=="policy"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "policy-only failure degraded state"
[ "$(count_log action:policy_reload)" -eq 1 ] || fail "policy-only failure action count"
reject_log verify:camera

: > "$PIM_CAMERA_CALL_LOG"
unset FAIL_ACTION
submit_apply policy-only-retry
expected=$'action:policy_reload\nverify:camera\nverify:processes:1'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "policy-only no-change retry"; }
jq -e '.lifecycle=="ACTIVE"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "policy-only retry owner lifecycle"
jq -e '.dirty==false and .degraded_reason==null and .degraded_target==null' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "policy-only retry did not clear degradation after success"

reset_case boot-a
write_source policy-fail-base 640 one one one
cam_daemon_startup "$DAEMON_PID"
rm -f "$PIM_CAMERA_SOURCE_ROOT/edgeconf_policy-fail-base.json"
write_source policy-fail 800 one one two
: > "$PIM_CAMERA_CALL_LOG"
FAIL_ACTION=policy_reload expect_rc 1 submit_apply hardware-policy-failure
[ "$(jq -r .VHL_CAM.label "$PIM_CAMERA_RUNTIME_JSON")" = policy-fail ] || fail "policy failure rolled runtime back"
jq -e '.lifecycle=="DEGRADED"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "policy failure owner lifecycle"
jq -e '.dirty==true and .degraded_reason=="hardware-policy-failure" and .degraded_target=="policy"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "policy failure degraded state"
jq -e '.status=="FAILED" and .rc==1' "$PIM_CAMERA_RUN_DIR/recovery/results/$LAST_REQUEST_ID.json" >/dev/null || fail "policy failure request result"
[ "$(count_log action:camera_hard_reset)" -eq 1 ] && [ "$(count_log action:policy_reload)" -eq 1 ] || fail "policy failure action count"
reject_log verify:camera

: > "$PIM_CAMERA_CALL_LOG"
unset FAIL_ACTION
submit_apply hardware-policy-retry
expected=$'quiesce:consumers\naction:camera_hard_reset\naction:policy_reload\nverify:camera\nverify:processes:1'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "hardware+policy no-change retry"; }
jq -e '.lifecycle=="ACTIVE"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "hardware+policy retry owner lifecycle"
jq -e '.dirty==false and .degraded_reason==null and .degraded_target==null' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "hardware+policy retry did not clear degradation after success"

echo "=== apply intake lifecycle guard ==="
cam_owner_set_lifecycle STOPPING
expect_rc 69 cam_request_submit apply_config test stopped

echo "cam operate control: PASS"
