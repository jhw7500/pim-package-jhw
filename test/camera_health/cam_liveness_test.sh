#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-cam-liveness.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_CAMERA_RUNTIME_JSON="$PIM_CAMERA_RUN_DIR/config/pim_runtime.json"
export PIM_CAMERA_RUNTIME_VALIDATOR="$PIM_BIN/camera_runtime_config.py"
export PIM_CAMERA_DEVICE_ROOT="$WORK/dev"
export PIM_CAMERA_BG_FLAG_FILE="$WORK/bg_chk_flag.bin"
export PIM_CAMERA_INIT_FLAG="$WORK/init_cam_flag"
export PIM_CAMERA_RESTART_FLAG="$WORK/restart_flag"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_LIVENESS_NOW=100
export PIM_CAMERA_V4L2_CTL=v4l2-ctl
export PIM_CAMERA_SYSTEMCTL=systemctl
export PIM_CAMERA_VCM_COMMAND=vcm
DAEMON_PID=4242

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local wanted=$1; shift; set +e; "$@"; local got=$?; set -e; [ "$got" -eq "$wanted" ] || fail "expected rc=$wanted got=$got: $*"; }
count_log() { grep -Fxc "$1" "$PIM_CAMERA_CALL_LOG" 2>/dev/null || true; }
fingerprint() { [ -e "$1" ] && cksum "$1" || printf 'absent\n'; }
reject_effects() {
    ! grep -Eq '^(restart:|start:vcm|request:)' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "$1 performed a liveness effect"; }
}
fake_stat() {
    local start=${1:-111}
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$start"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
}
write_runtime() {
    mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")" "$PIM_CAMERA_DEVICE_ROOT"
    cat > "$PIM_CAMERA_RUNTIME_JSON" <<'JSON'
{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"i2c2":{"ch0":{"enable":true},"ch1":{"enable":false}},"i2c1":{"ch2":{"enable":false},"ch3":{"enable":false}},"v4l_map":{"csi0_subdev":2,"csi1_subdev":3}},"ORD":{},"VCM":{}}
JSON
}
export_owner_context() {
    local owner
    owner=$(cat "$PIM_CAMERA_RUN_DIR/owner.json")
    export PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
    export PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
    PIM_CAMERA_OWNER_BOOT_ID=$(jq -r .boot_id <<<"$owner")
    PIM_CAMERA_OWNER_INVOCATION=$(jq -r .invocation_id <<<"$owner")
    PIM_CAMERA_OWNER_PID=$(jq -r .pid <<<"$owner")
    PIM_CAMERA_OWNER_PROC_START_TIME=$(jq -r .proc_start_time <<<"$owner")
    PIM_CAMERA_OWNER_TOKEN=$(jq -r .token <<<"$owner")
    PIM_CAMERA_OWNER_CREATED_AT=$(jq -r .created_at <<<"$owner")
}
owner_at() {
    local lifecycle=$1
    cam_owner_create "$DAEMON_PID"
    if [ "$lifecycle" != STARTING ]; then
        cam_owner_set_lifecycle ACTIVE
        [ "$lifecycle" = ACTIVE ] || cam_owner_set_lifecycle "$lifecycle"
    fi
    export_owner_context
}
reset_case() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT" "$PIM_CAMERA_DEVICE_ROOT"
    mkdir -p "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT" "$PIM_CAMERA_DEVICE_ROOT"
    printf 'boot-a\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    : > "$PIM_CAMERA_CALL_LOG"
    : > "$WORK/procs"
    rm -f "$PIM_CAMERA_BG_FLAG_FILE" "$PIM_CAMERA_INIT_FLAG" "$PIM_CAMERA_RESTART_FLAG"
    export ORD_STATE=active ORD_RESTART_RC=0 PIM_CAMERA_PGREP_ERROR= SUBDEV_RC=0 VCM_START_RC=0
    export PIM_CAMERA_V4L2_CTL=v4l2-ctl PIM_CAMERA_VCM_COMMAND=vcm
    PIM_CAMERA_LIVENESS_QUIESCED=0
    PIM_CAMERA_LIVENESS_GRACE_UNTIL=0
    PIM_CAMERA_LIVENESS_GRACE_USES=0
    export PIM_CAMERA_LIVENESS_QUIESCED PIM_CAMERA_LIVENESS_GRACE_UNTIL PIM_CAMERA_LIVENESS_GRACE_USES
    fake_stat
    write_runtime
}
set_counter() {
    local failures=$1
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery"
    _cr_state_template | jq --argjson failures "$failures" '.actions.gstapp_restart.failed=$failures | .actions.gstapp_restart.attempted=$failures | .actions.gstapp_restart.consecutive_failures=$failures | if $failures>0 then .actions.gstapp_restart.last_request_id="prior" | .actions.gstapp_restart.last_started_at=1 | .actions.gstapp_restart.last_finished_at=1 | .actions.gstapp_restart.last_status="FAILED" | .actions.gstapp_restart.last_rc=1 else . end' > "$PIM_CAMERA_STATE_DIR/recovery/state.json"
}
clear_leases() { rm -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" "$PIM_CAMERA_RUN_DIR/recovery/active.json"; }
prepare_gst_missing() {
    printf 'vcm\n' > "$WORK/procs"
    export ORD_STATE=active
    touch "$PIM_CAMERA_DEVICE_ROOT/video3"
    set_counter "${1:-0}"
}

mkdir -p "$WORK/stub"
cat > "$WORK/stub/systemctl" <<'SH'
#!/bin/sh
printf 'systemctl:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
case "$1" in
  is-active) printf '%s\n' "$ORD_STATE"; [ "$ORD_STATE" = active ] && exit 0 || [ "$ORD_STATE" = inactive ] && exit 3 || exit 4 ;;
  restart) printf 'restart:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; exit "$ORD_RESTART_RC" ;;
  stop) printf 'stop-service:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; exit 0 ;;
esac
exit 64
SH
cat > "$WORK/stub/pgrep" <<'SH'
#!/bin/sh
target=
for arg; do target=$arg; done
printf 'pgrep:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
[ "$PIM_CAMERA_PGREP_ERROR" = "$target" ] && exit 8
grep -Fqx "$target" "$WORK/procs" 2>/dev/null
SH
cat > "$WORK/stub/v4l2-ctl" <<'SH'
#!/bin/sh
printf 'v4l2:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
exit "$SUBDEV_RC"
SH
cat > "$WORK/stub/vcm" <<'SH'
#!/bin/sh
printf 'start:vcm\n' >> "$PIM_CAMERA_CALL_LOG"
[ "$VCM_START_RC" -eq 0 ] || exit "$VCM_START_RC"
printf 'vcm\n' >> "$WORK/procs"
exit 0
SH
cat > "$WORK/stub/logger" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$WORK/stub/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$WORK/stub"/*
export WORK PATH="$WORK/stub:$PATH"

# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_operate_control.sh"
_cr_fsync_file() { :; }
_cr_fsync_dir() { :; }

LIVENESS="$PIM_LIB/cam_liveness.sh"
[ -f "$LIVENESS" ] || fail "Task 5 liveness library is missing: $LIVENESS"
# shellcheck source=/dev/null
source "$LIVENESS"

eval "$(declare -f cam_request_submit | sed '1s/cam_request_submit/cam_request_submit_real/')"
cam_request_submit() {
    printf 'request:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"
    cam_request_submit_real "$@"
}

echo '=== non-active, stale, quiesced, leased, and invalid guards ==='
for lifecycle in STARTING APPLYING_CONFIG RECOVERING STOPPING DEGRADED; do
    reset_case; owner_at "$lifecycle"; cam_liveness_tick || :; reject_effects "$lifecycle"
done
reset_case; owner_at ACTIVE; fake_stat 222; cam_liveness_tick || :; reject_effects stale-owner
reset_case; owner_at ACTIVE; cam_liveness_quiesce; cam_liveness_tick || :; reject_effects quiesced
for lease in pending active; do
    reset_case; owner_at ACTIVE; mkdir -p "$PIM_CAMERA_RUN_DIR/recovery"; printf '{}\n' > "$PIM_CAMERA_RUN_DIR/recovery/$lease.json"; cam_liveness_tick || :; reject_effects "$lease-lease"
done
reset_case; owner_at ACTIVE; printf '{bad runtime}\n' > "$PIM_CAMERA_RUNTIME_JSON"; cam_liveness_tick || :; reject_effects invalid-runtime
reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=unknown
cam_liveness_tick || :; reject_effects ord-inspection-error
reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"; export PIM_CAMERA_PGREP_ERROR=vcm
cam_liveness_tick || :; reject_effects vcm-inspection-error

echo '=== exact ORD and VCM restart boundaries ==='
reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive
cam_liveness_tick
[ "$(count_log restart:ord-operate.service)" -eq 1 ] || fail 'inactive ORD was not restarted exactly once'
! grep -q '^start:vcm$\|^request:' "$PIM_CAMERA_CALL_LOG" || fail 'ORD restart touched another consumer'

reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=failed
cam_liveness_tick
[ "$(count_log restart:ord-operate.service)" -eq 1 ] || fail 'failed ORD was not restarted exactly once'
! grep -q '^start:vcm$\|^request:' "$PIM_CAMERA_CALL_LOG" || fail 'failed ORD restart touched another consumer'

reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"
cam_liveness_tick
for _ in 1 2 3 4 5; do grep -q '^start:vcm$' "$PIM_CAMERA_CALL_LOG" && break; /bin/sleep 0.05; done
grep -q '^start:vcm$' "$PIM_CAMERA_CALL_LOG" || fail 'missing VCM was not started through its exact launcher'
! grep -q '^restart:' "$PIM_CAMERA_CALL_LOG" || fail 'VCM restart touched ORD'

echo '=== ORD and VCM start failure degrade only their target ==='
reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive ORD_RESTART_RC=23
expect_rc 23 cam_liveness_tick
jq -e '.degraded_target=="ord" and .degraded_reason=="liveness_start_failed"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail 'ORD failure did not persist exact degraded target'
reject_effects_without_restarts=$(grep '^request:' "$PIM_CAMERA_CALL_LOG" 2>/dev/null || true); [ -z "$reject_effects_without_restarts" ] || fail 'ORD failure requested camera recovery'

reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"; export PIM_CAMERA_VCM_COMMAND=missing-vcm-command
expect_rc 127 cam_liveness_tick
jq -e '.degraded_target=="vcm" and .degraded_reason=="liveness_start_failed"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail 'VCM failure did not persist exact degraded target'
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'VCM failure requested camera recovery'

reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"; export VCM_START_RC=23
expect_rc 1 cam_liveness_tick
jq -e '.degraded_target=="vcm" and .degraded_reason=="liveness_start_failed"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail 'immediate VCM exit was not degraded'
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'immediate VCM exit requested camera recovery'

echo '=== gstApp gates, exact process match, and persistent threshold ==='
reset_case; owner_at ACTIVE; prepare_gst_missing 0
jq '.VHL_CAM.i2c2.ch0.enable=false' "$PIM_CAMERA_RUNTIME_JSON" > "$WORK/runtime.next" && mv "$WORK/runtime.next" "$PIM_CAMERA_RUNTIME_JSON"
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'all-disabled runtime requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; printf '3\n' > "$PIM_CAMERA_BG_FLAG_FILE"
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'disconnect requested gstApp recovery'

reset_case; owner_at ACTIVE; printf 'vcm\n' > "$WORK/procs"; set_counter 0
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'missing video node requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; export SUBDEV_RC=1
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'unready subdev requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; touch "$PIM_CAMERA_INIT_FLAG"
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'init flag requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; touch "$PIM_CAMERA_RESTART_FLAG"; export SUBDEV_RC=1
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'active restart flag requested gstApp recovery'
rm -f "$PIM_CAMERA_RESTART_FLAG"
cam_liveness_tick; clear_leases
cam_liveness_tick; clear_leases
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 2 ] || fail 'restart grace did not permit exactly two subdev bypasses'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; export PIM_CAMERA_V4L2_CTL=missing-v4l2-tool
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 1 ] || fail 'absent v4l2-ctl did not preserve permissive gate'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; printf 'gstApp-helper\n' >> "$WORK/procs"
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 1 ] || fail 'substring process match suppressed exact gstApp recovery'
clear_leases; : > "$PIM_CAMERA_CALL_LOG"; printf 'gstApp\n' >> "$WORK/procs"
cam_liveness_tick
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'exact gstApp match created a duplicate request'

reset_case; owner_at ACTIVE; prepare_gst_missing 4
runtime_before=$(cksum "$PIM_CAMERA_RUNTIME_JSON")
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 1 ] || fail 'below threshold did not request gstapp_restart'
[ "$runtime_before" = "$(cksum "$PIM_CAMERA_RUNTIME_JSON")" ] || fail 'liveness rebuilt or overwrote the fixed runtime'
clear_leases; : > "$PIM_CAMERA_CALL_LOG"; set_counter 5
cam_liveness_tick
[ "$(count_log request:module_reload)" -eq 1 ] || fail 'threshold 5 did not request module_reload'

clear_leases; : > "$PIM_CAMERA_CALL_LOG"; set_counter 2; PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD=2
cam_liveness_tick
[ "$(count_log request:module_reload)" -eq 1 ] || fail 'test-overridden escalation threshold was ignored'
PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD=5

reset_case; owner_at ACTIVE; prepare_gst_missing 5; printf '{invalid}\n' > "$PIM_CAMERA_RUNTIME_JSON"
cam_liveness_tick || :; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'invalid runtime escalated'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; mkdir -p "$PIM_CAMERA_RUN_DIR/recovery"; printf '{}\n' > "$PIM_CAMERA_RUN_DIR/recovery/pending.json"
cam_liveness_tick || :; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'existing lease created another request'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; export PIM_CAMERA_PGREP_ERROR=gstApp
cam_liveness_tick || :; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'gstApp inspection error was treated as absence'

echo '=== liveness gstApp failures remain retryable until module escalation ==='
cam_action_gstapp_restart() { return 23; }
reset_case; owner_at ACTIVE; prepare_gst_missing 0
for failure in 1 2 3 4 5; do
    cam_liveness_tick
    jq -e '.type=="gstapp_restart" and .source=="liveness" and .reason=="gstapp process absent"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null || fail "liveness failure $failure did not submit exact gstApp request"
    cam_request_claim
    if [ "$failure" -eq 1 ]; then
        PIM_CAMERA_TEST_FAILPOINT=retryable_liveness_before_finish expect_rc 70 cam_execute_pending_request
        request_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/active.json")
        history_file="$PIM_CAMERA_STATE_DIR/recovery/history/$request_id.json"
        result_file="$PIM_CAMERA_RUN_DIR/recovery/results/$request_id.json"
        jq -e '.status=="RUNNING" and (has("rc")|not) and (has("finished_at")|not)' "$PIM_CAMERA_RUN_DIR/recovery/active.json" >/dev/null || fail 'retry failpoint wrote a nonterminal FAILED request'
        jq -e '.request.status=="RUNNING" and (.actions[-1].status=="FAILED") and (.actions[-1].rc==23)' "$history_file" >/dev/null || fail 'retry failpoint did not preserve the recoverable RUNNING/terminal-action pair'
        [ ! -e "$result_file" ] || fail 'retry failpoint published a premature request result'

        cp "$history_file" "$WORK/retry-history.valid"
        jq '.actions[-1].rc=24' "$history_file" > "$WORK/retry-history.invalid" && mv "$WORK/retry-history.invalid" "$history_file"
        retry_active_before=$(fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")
        retry_owner_before=$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
        retry_state_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
        retry_history_before=$(fingerprint "$history_file")
        retry_result_before=$(fingerprint "$result_file")
        expect_rc 70 _coc_fail_retryable_liveness_gstapp 23
        [ "$retry_active_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail 'invalid retry evidence mutated active request'
        [ "$retry_owner_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail 'invalid retry evidence mutated owner'
        [ "$retry_state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail 'invalid retry evidence mutated counters'
        [ "$retry_history_before" = "$(fingerprint "$history_file")" ] || fail 'invalid retry evidence mutated history'
        [ "$retry_result_before" = "$(fingerprint "$result_file")" ] || fail 'invalid retry evidence published a result'
        cp "$WORK/retry-history.valid" "$history_file"
        expect_rc 23 _coc_fail_retryable_liveness_gstapp 23
    else
        expect_rc 23 cam_execute_pending_request
    fi
    jq -e --argjson failure "$failure" '.actions.gstapp_restart.failed==$failure and .actions.gstapp_restart.consecutive_failures==$failure and .actions.gstapp_restart.last_status=="FAILED" and .actions.gstapp_restart.last_rc==23' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "liveness failure $failure was not countered exactly"
    [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail "liveness failure $failure made the owner terminal"
    [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "liveness failure $failure retained a lease"
done
cam_liveness_tick
jq -e '.type=="module_reload" and .source=="liveness" and .reason=="gstapp process absent"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null || fail 'five actual gstApp failures did not escalate the next tick to module_reload'

reset_case; owner_at ACTIVE; prepare_gst_missing 0
cam_request_submit gstapp_restart legacy-restart-app legacy-wrapper >/dev/null
cam_request_claim
expect_rc 23 cam_execute_pending_request
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] || fail 'legacy gstApp failure did not remain terminal DEGRADED'

cam_action_module_reload() { return 24; }
cam_action_camera_hard_reset() { return 24; }
cam_action_reboot_fallback() { return 24; }
reset_case; owner_at ACTIVE; prepare_gst_missing 5
cam_liveness_tick
jq -e '.type=="module_reload" and .source=="liveness"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null || fail 'non-gst liveness case did not submit module_reload'
cam_request_claim
expect_rc 24 cam_execute_pending_request
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] || fail 'non-gst liveness failure did not remain terminal DEGRADED'

echo '=== one-pass compatibility shim is finite ==='
cat > "$WORK/stub/recoveryctl" <<'SH'
#!/bin/sh
printf 'shim:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
exit 0
SH
chmod +x "$WORK/stub/recoveryctl"
PIM_CAMERA_RECOVERYCTL="$WORK/stub/recoveryctl" timeout 2 bash "$PIM_BIN/restart_app.sh"
[ "$(count_log 'shim:request gstapp_restart --source legacy-restart-app --reason legacy-wrapper --wait 120')" -eq 1 ] || fail 'restart_app shim did not forward exactly once'

echo 'cam liveness: PASS'
