#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-cam-stop.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export WORK

export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_CAMERA_RUNTIME_JSON="$PIM_CAMERA_RUN_DIR/config/pim_runtime.json"
export PIM_CAMERA_RUNTIME_VALIDATOR="$PIM_BIN/camera_runtime_config.py"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_STOP_WAIT_SEC=0
export PIM_CAMERA_QUIESCE_TIMEOUT_SEC=0
export PIM_CAMERA_SYSTEMCTL=systemctl
export PIM_CAMERA_KILL="$WORK/stub/daemon-kill"
DAEMON_PID=4242

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local wanted=$1; shift; set +e; "$@"; local got=$?; set -e; [ "$got" -eq "$wanted" ] || fail "expected rc=$wanted got=$got: $*"; }
fingerprint() { [ -e "$1" ] && cksum "$1" || printf 'absent\n'; }
review_failures=''
fake_stat() {
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
}
write_runtime() {
    mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")"
    printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false}},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
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
reset_case() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT"
    mkdir -p "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT"
    printf 'boot-a\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    : > "$PIM_CAMERA_CALL_LOG"
    fake_stat
    write_runtime
    cam_owner_create "$DAEMON_PID"
    cam_owner_set_lifecycle ACTIVE
    export_owner_context
    PIM_CAMERA_LIVENESS_QUIESCED=0
    export PIM_CAMERA_LIVENESS_QUIESCED
}

mkdir -p "$WORK/stub"
cat > "$WORK/stub/systemctl" <<'SH'
#!/bin/sh
printf 'stop-service:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"
exit 0
SH
cat > "$WORK/stub/killcam" <<'SH'
#!/bin/sh
printf 'FORBIDDEN:killcam\n' >> "$PIM_CAMERA_CALL_LOG"
exit 99
SH
cat > "$WORK/stub/daemon-kill" <<'SH'
#!/bin/sh
printf 'daemon-signal:%s:%s\n' "$1" "$2" >> "$PIM_CAMERA_CALL_LOG"
rm -f "$PIM_CAMERA_PROC_ROOT/$2/stat"
exit 0
SH
cat > "$WORK/stub/pgrep" <<'SH'
#!/bin/sh
target=
for arg; do target=$arg; done
[ -r "$WORK/stop-procs" ] || exit 1
grep -Fqx "$target" "$WORK/stop-procs" 2>/dev/null
SH
cat > "$WORK/stub/pkill" <<'SH'
#!/bin/sh
printf 'pkill:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
target=
for arg; do target=$arg; done
grep -Fvx "$target" "$WORK/stop-procs" > "$WORK/stop-procs.next" 2>/dev/null || :
mv "$WORK/stop-procs.next" "$WORK/stop-procs"
exit 0
SH
cat > "$WORK/stub/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$WORK/stub"/*
export PATH="$WORK/stub:$PATH"

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

echo '=== STOPPING executor is the existing exact stop boundary ==='
reset_case
cam_owner_set_lifecycle STOPPING
PIM_CAMERA_STOP_EXECUTOR=1 expect_rc 0 cam_executor_assert_context
printf '{invalid runtime}\n' > "$PIM_CAMERA_RUNTIME_JSON"
set +e
PIM_CAMERA_STOP_EXECUTOR=1 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" gstapp; invalid_gstapp_rc=$?
PIM_CAMERA_STOP_EXECUTOR=1 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" pimcam; invalid_pimcam_rc=$?
set -e
[ "$invalid_gstapp_rc" -eq 0 ] && [ "$invalid_pimcam_rc" -eq 0 ] || review_failures="$review_failures invalid-runtime:$invalid_gstapp_rc/$invalid_pimcam_rc"

echo '=== STOPPING cleanup survives daemon exit with exact immutable owner ==='
reset_case
cam_owner_set_lifecycle STOPPING
printf 'gstApp\nPIMCAM\n' > "$WORK/stop-procs"
rm -f "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
PIM_CAMERA_STOP_EXECUTOR=1 expect_rc 0 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" gstapp
PIM_CAMERA_STOP_EXECUTOR=1 expect_rc 0 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" pimcam
[ ! -s "$WORK/stop-procs" ] || fail 'post-daemon STOPPING cleanup left exact app processes'
[ -e "$PIM_CAMERA_RUN_DIR/owner.json" ] || fail 'consumer cleanup removed owner before terminal stop'
saved_token=$PIM_CAMERA_OWNER_TOKEN
PIM_CAMERA_OWNER_TOKEN=foreign-token
PIM_CAMERA_STOP_EXECUTOR=1 expect_rc 69 cam_executor_assert_context
PIM_CAMERA_OWNER_TOKEN=$saved_token

echo '=== a BUSY foreign daemon exit preserves the live owner ==='
reset_case
foreign_owner_before=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
foreign_runtime_before=$(cksum "$PIM_CAMERA_RUNTIME_JSON")
printf 'gstApp\nvcm\n' > "$WORK/managed-procs"
foreign_process_before=$(cksum "$WORK/managed-procs")
unset PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
unset PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
expect_rc 75 cam_daemon_startup "$DAEMON_PID"
set +e
cam_liveness_ordered_stop; foreign_stop_rc=$?
set -e
[ "$foreign_stop_rc" -eq 69 ] || review_failures="$review_failures foreign-owner-rc:$foreign_stop_rc"
[ "$foreign_owner_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || review_failures="$review_failures foreign-owner-mutated"
[ "$foreign_runtime_before" = "$(fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || review_failures="$review_failures foreign-runtime-mutated"
[ "$foreign_process_before" = "$(fingerprint "$WORK/managed-procs")" ] || review_failures="$review_failures foreign-process-mutated"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || review_failures="$review_failures foreign-effects"

echo '=== shutdown order and intake closure are exact ==='
reset_case
STOP_REQUEST_RC=
_cl_stop_event() {
    local event=$1 owner_state=absent
    [ -e "$PIM_CAMERA_RUN_DIR/owner.json" ] && owner_state=present
    printf 'event:%s:owner=%s\n' "$event" "$owner_state" >> "$PIM_CAMERA_CALL_LOG"
    if [ "$event" = intake_closed ]; then
        set +e
        cam_request_submit gstapp_restart stop-test forbidden >/dev/null 2>&1
        STOP_REQUEST_RC=$?
        set -e
    fi
}
cam_stop_process() { printf 'stop:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; }
cam_liveness_ordered_stop --external
[ "$STOP_REQUEST_RC" -eq 69 ] || fail "STOPPING intake returned $STOP_REQUEST_RC instead of 69"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail 'STOPPING accepted a request'
[ ! -e "$PIM_CAMERA_RUN_DIR/owner.json" ] || fail 'ordered stop retained owner'
cat > "$WORK/expected-order" <<'EOF'
event:stopping:owner=present
event:intake_closed:owner=present
event:liveness_quiesced:owner=present
event:daemon_quiesce_signaled:owner=present
daemon-signal:-TERM:4242
event:daemon_quiesced:owner=present
event:action_child_quiesced:owner=present
stop:gstapp
stop:pimcam
stop:bg
stop-service:ord-operate.service
stop:vcm
event:managed_stopped:owner=present
event:terminal_stop:owner=present
event:owner_removed:owner=absent
EOF
diff -u "$WORK/expected-order" "$PIM_CAMERA_CALL_LOG" >/dev/null || review_failures="$review_failures external-signal-order"

echo '=== repeated and competing stop paths converge ==='
before=$(cksum "$PIM_CAMERA_CALL_LOG")
cam_liveness_ordered_stop --external
[ "$before" = "$(cksum "$PIM_CAMERA_CALL_LOG")" ] || fail 'second stop repeated cleanup after owner removal'

reset_case
cam_owner_set_lifecycle STOPPING
_cl_stop_event() { printf 'unexpected:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"; }
expect_rc 75 cam_liveness_ordered_stop --external
! grep -q '^stop:\|^stop-service:' "$PIM_CAMERA_CALL_LOG" || fail 'non-coordinator reordered an in-progress stop'

echo '=== TERM INT and EXIT use the shared ordered-stop handler ==='
for signal in TERM INT; do
    : > "$WORK/trap-$signal"
    set +e
    (
        cam_liveness_ordered_stop() { printf '%s\n' "$signal" >> "$WORK/trap-$signal"; }
        cam_liveness_install_traps
        kill -s "$signal" "$BASHPID"
        exit 99
    )
    trap_rc=$?
    set -e
    case "$signal:$trap_rc" in TERM:143|INT:130) ;; *) fail "$signal trap rc=$trap_rc";; esac
    [ "$(wc -l < "$WORK/trap-$signal")" -eq 1 ] || fail "$signal did not use one shared stop path"
done
: > "$WORK/trap-EXIT"
set +e
(
    cam_liveness_ordered_stop() { printf 'EXIT\n' >> "$WORK/trap-EXIT"; }
    cam_liveness_install_traps
    exit 7
)
trap_rc=$?
set -e
[ "$trap_rc" -eq 7 ] || fail "EXIT trap changed rc to $trap_rc"
[ "$(wc -l < "$WORK/trap-EXIT")" -eq 1 ] || fail 'EXIT did not use one shared stop path'

echo '=== daemon and external stop script use the shared primitives ==='
grep -Fq 'source /opt/pim/lib/cam_liveness.sh' "$PIM_BIN/chk_cam_operate.sh" || fail 'daemon does not source liveness library'
grep -Fq 'cam_liveness_install_traps' "$PIM_BIN/chk_cam_operate.sh" || fail 'daemon does not install shared stop traps'

reset_case
cam_liveness_ordered_stop --external
: > "$PIM_CAMERA_CALL_LOG"
PIM_LIB="$PIM_LIB" PIM_BIN="$PIM_BIN" bash "$PIM_BIN/cam_operate_stop.sh"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail 'completed external stop invoked a legacy/managed action'; }

mkdir -p "$WORK/exit-lib"
for library in cam_recovery.sh cam_recovery_actions.sh cam_operate_control.sh; do : > "$WORK/exit-lib/$library"; done
cat > "$WORK/exit-lib/cam_liveness.sh" <<'SH'
cam_liveness_ordered_stop() { return "$STOP_STUB_RC"; }
SH
for stop_rc in 0 69 70 75; do
    set +e
    PIM_LIB="$WORK/exit-lib" PIM_BIN="$PIM_BIN" STOP_STUB_RC="$stop_rc" bash "$PIM_BIN/cam_operate_stop.sh"
    script_rc=$?
    set -e
    [ "$script_rc" -eq "$stop_rc" ] || fail "external stop hid rc=$stop_rc as rc=$script_rc"
done

echo '=== managed stop preserves the exact failing phase rc ==='
for failing_kind in pimcam bg vcm; do
    reset_case
    cam_owner_set_lifecycle STOPPING
    (
        cam_stop_process() { [ "$2" != "$failing_kind" ] || return 69; }
        expect_rc 69 cam_liveness_stop_managed
    )
done

[ -z "$review_failures" ] || fail "review regressions:$review_failures"

echo 'cam stop order: PASS'
