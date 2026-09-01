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
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
}
write_source() {
    local marker=${1:-source} width=${2:-640} ord=${3:-one} vcm=${4:-one} policy=${5:-one}
    mkdir -p "$PIM_CAMERA_SOURCE_ROOT"
    cat > "$PIM_CAMERA_SOURCE_ROOT/edgeconf_${marker}.json" <<JSON
{"VHL_CAM":{"app":"gstApp","cam_width":$width,"cam_height":360,"fps":30,"capture":{"enable":false},"i2c2":{"ch0":{"enable":true},"ch1":{"enable":true}},"i2c1":{"ch2":{"enable":true},"ch3":{"enable":true}},"label":"$marker"}}
JSON
    cat > "$PIM_CAMERA_SOURCE_ROOT/ord_vcm_conf.json" <<JSON
{"ORD":{"value":"$ord"},"VCM":{"value":"$vcm"},"ETC":{"policy":"$policy"},"EXTRA":{"kept":true}}
JSON
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

cam_initial_module_load() { printf 'action:initial_module_load\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_action_module_reload() { printf 'action:module_reload\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_action_camera_hard_reset() { printf 'action:camera_hard_reset\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_execute_action_step() {
    local request_type
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
    printf 'action:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"
    [ "${FAIL_ACTION:-}" != "$1" ]
}
cam_quiesce_gstapp() { cam_executor_assert_context || return $?; printf 'quiesce:gstapp\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_quiesce_consumers() { cam_executor_assert_context || return $?; printf 'quiesce:consumers\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_stop_process() { cam_executor_assert_context || return $?; printf 'quiesce:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; }
cam_restart_ord() { printf 'start:ord\n' >> "$PIM_CAMERA_CALL_LOG"; [ "${FAIL_ACTION:-}" != ord_restart ]; }
cam_restart_vcm() { printf 'start:vcm\n' >> "$PIM_CAMERA_CALL_LOG"; [ "${FAIL_ACTION:-}" != vcm_restart ]; }
cam_start_gstapp() { printf 'start:gstapp\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_wait_process_ready() {
    printf 'verify:processes:%s\n' "${2:-0}" >> "$PIM_CAMERA_CALL_LOG"
    [ "${FAIL_VERIFY:-}" != process ]
}
cam_verify_camera_ready() {
    printf 'verify:camera\n' >> "$PIM_CAMERA_CALL_LOG"
    [ "${FAIL_VERIFY:-}" != camera ]
}
_coc_policy_reload() { printf 'action:policy_reload\n' >> "$PIM_CAMERA_CALL_LOG"; }

echo "=== new-boot startup transaction ==="
reset_case boot-a
write_source new 640
cam_daemon_startup "$DAEMON_PID"
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
cam_daemon_startup "$DAEMON_PID"
[ "$(grep -c '^stage$' "$PIM_CAMERA_HELPER_LOG")" -eq 1 ] || fail "same-boot restart did not re-stage exactly once"
[ "$(count_log action:module_reload)" -eq 1 ] || fail "same-boot restart did not module-reload exactly once"
[ "$(jq -r .VHL_CAM.label "$PIM_CAMERA_RUNTIME_JSON")" = restart ] || fail "restart used manual runtime as source/fallback"
startup_history=$(grep -rl '"type":"module_reload"' "$PIM_CAMERA_STATE_DIR/recovery/history" 2>/dev/null || true)
[ -n "$startup_history" ] || fail "same-boot public action was not attributed to a request history"

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
    cam_daemon_startup "$DAEMON_PID"
    [ "$(count_log action:camera_hard_reset)" -eq 1 ] || fail "$mode did not hard reset"
done

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

echo "=== apply intake lifecycle guard ==="
cam_owner_set_lifecycle STOPPING
expect_rc 69 cam_request_submit apply_config test stopped

echo "cam operate control: PASS"
