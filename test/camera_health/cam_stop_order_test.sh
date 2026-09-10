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
    local start=${1:-111}
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$start"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
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

export PIM_CAMERA_REAL_FLOCK
PIM_CAMERA_REAL_FLOCK=$(command -v flock)
mkdir -p "$WORK/stub"
cat > "$WORK/stub/systemctl" <<'SH'
#!/bin/sh
printf 'stop-service:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"
if [ "${PIM_CAMERA_STOP_OBSERVE_OWNER:-0}" = 1 ]; then
    [ -e "$PIM_CAMERA_RUN_DIR/owner.json" ] && owner=present || owner=absent
    printf 'managed-owner:systemctl:%s\n' "$owner" >> "$PIM_CAMERA_CALL_LOG"
fi
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
[ "${DAEMON_KILL_KEEP_ALIVE:-0}" = 1 ] || rm -f "$PIM_CAMERA_PROC_ROOT/$2/stat"
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
if [ "${PIM_CAMERA_STOP_OBSERVE_OWNER:-0}" = 1 ]; then
    [ -e "$PIM_CAMERA_RUN_DIR/owner.json" ] && owner=present || owner=absent
    printf 'managed-owner:pkill:%s\n' "$owner" >> "$PIM_CAMERA_CALL_LOG"
fi
target=
for arg; do target=$arg; done
grep -Fvx "$target" "$WORK/stop-procs" > "$WORK/stop-procs.next" 2>/dev/null || :
mv "$WORK/stop-procs.next" "$WORK/stop-procs"
exit 0
SH
cat > "$WORK/stub/sleep" <<'SH'
#!/bin/sh
if [ -n "${PIM_CAMERA_TEST_RETRY_GATE:-}" ] && [ ! -e "$PIM_CAMERA_TEST_RETRY_GATE" ]; then
    : > "$PIM_CAMERA_TEST_RETRY_SEEN"
    while [ ! -e "$PIM_CAMERA_TEST_RETRY_GATE" ]; do /bin/sleep 0.01; done
fi
[ -z "${STOP_STUB_SLEEP_LOG:-}" ] || printf 'sleep:%s\n' "$1" >> "$STOP_STUB_SLEEP_LOG"
exit 0
SH
cat > "$WORK/stub/flock" <<'SH'
#!/bin/sh
if [ -z "${PIM_CAMERA_TEST_FLOCK_LOG:-}" ]; then exec "$PIM_CAMERA_REAL_FLOCK" "$@"; fi
case "$1" in
    -n)
        printf 'nonblock:%s\n' "$2" >> "$PIM_CAMERA_TEST_FLOCK_LOG"
        [ "${PIM_CAMERA_TEST_FLOCK_MODE:-}" != starve ] || exit 1
        exec "$PIM_CAMERA_REAL_FLOCK" "$@"
        ;;
    -E)
        [ "$#" -eq 5 ] && [ "$2" = 75 ] && [ "$3" = -w ] && [ "$4" = 30 ] || exit 70
        printf 'wait:%s\n' "$5" >> "$PIM_CAMERA_TEST_FLOCK_LOG"
        [ "${PIM_CAMERA_TEST_FLOCK_MODE:-}" != starve ] || exit "${PIM_CAMERA_TEST_FLOCK_RC:-0}"
        exec "$PIM_CAMERA_REAL_FLOCK" "$@"
        ;;
    -u)
        printf 'unlock:%s\n' "$2" >> "$PIM_CAMERA_TEST_FLOCK_LOG"
        [ "${PIM_CAMERA_TEST_FLOCK_MODE:-}" != starve ] || exit "${PIM_CAMERA_TEST_FLOCK_UNLOCK_RC:-0}"
        exec "$PIM_CAMERA_REAL_FLOCK" "$@"
        ;;
esac
exit 70
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

echo '=== TERM revalidates the exact daemon and live timeout stays STOPPING ==='
reset_case; cam_owner_set_lifecycle STOPPING; rm -f "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
expect_rc 0 cam_liveness_signal_daemon
! grep -q '^daemon-signal:' "$PIM_CAMERA_CALL_LOG" || fail 'absent exact daemon was signaled'

reset_case; cam_owner_set_lifecycle STOPPING; fake_stat 222
expect_rc 69 cam_liveness_signal_daemon
! grep -q '^daemon-signal:' "$PIM_CAMERA_CALL_LOG" || fail 'reused daemon PID was signaled'

reset_case; cam_owner_set_lifecycle STOPPING
expect_rc 0 cam_liveness_signal_daemon
[ "$(grep -c '^daemon-signal:-TERM:4242$' "$PIM_CAMERA_CALL_LOG")" -eq 1 ] || fail 'live exact daemon did not receive exactly one TERM'

reset_case; export DAEMON_KILL_KEEP_ALIVE=1
expect_rc 75 cam_liveness_ordered_stop --external
unset DAEMON_KILL_KEEP_ALIVE
[ -e "$PIM_CAMERA_RUN_DIR/owner.json" ] && [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = STOPPING ] || fail 'live daemon timeout removed STOPPING owner'
! grep -q '^stop:\|^stop-service:' "$PIM_CAMERA_CALL_LOG" || fail 'live daemon timeout continued into managed cleanup'

echo '=== daemon-dead STOPPING resumes and reconciles an abandoned lease ==='
reset_case; cam_owner_set_lifecycle STOPPING; rm -f "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
expect_rc 0 cam_liveness_ordered_stop --external
[ ! -e "$PIM_CAMERA_RUN_DIR/owner.json" ] || fail 'daemon-dead STOPPING owner was not removed after resumed cleanup'

reset_case
cam_request_submit gstapp_restart stop-resume interrupted >/dev/null
cam_request_claim
cam_owner_set_lifecycle STOPPING
abandoned_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/active.json")
rm -f "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
expect_rc 0 cam_liveness_ordered_stop --external
[ ! -e "$PIM_CAMERA_RUN_DIR/owner.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail 'resumed stop left owner or lease behind'
jq -e '.status=="FAILED" and .rc==70' "$PIM_CAMERA_RUN_DIR/recovery/results/$abandoned_id.json" >/dev/null || fail 'abandoned active lease was not terminalized'
jq -e '.request.status=="FAILED" and .request.rc==70' "$PIM_CAMERA_STATE_DIR/recovery/history/$abandoned_id.json" >/dev/null || fail 'abandoned active history was not terminalized'
fake_stat
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail 'next daemon owner inherited an orphan lease'

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
rm -f "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
_cl_stop_event() { printf 'resumed:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"; }
expect_rc 0 cam_liveness_ordered_stop --external
[ ! -e "$PIM_CAMERA_RUN_DIR/owner.json" ] || fail 'later external stop stranded a durable STOPPING owner'
grep -q '^resumed:owner_removed$' "$PIM_CAMERA_CALL_LOG" || fail 'resumed STOPPING did not finish with owner removal last'

echo '=== partial managed cleanup is resumable ==='
reset_case
rm -f "$WORK/managed-failed-once"
_cl_stop_event() { printf 'partial:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"; }
cam_stop_process() {
    printf 'partial-stop:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"
    if [ "$2" = bg ] && [ ! -e "$WORK/managed-failed-once" ]; then : > "$WORK/managed-failed-once"; return 69; fi
    return 0
}
expect_rc 69 cam_liveness_ordered_stop --external
[ -e "$PIM_CAMERA_RUN_DIR/owner.json" ] && [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = STOPPING ] || fail 'managed cleanup failure did not retain STOPPING owner'
cam_stop_process() { printf 'resumed-stop:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; return 0; }
expect_rc 0 cam_liveness_ordered_stop --external
[ ! -e "$PIM_CAMERA_RUN_DIR/owner.json" ] || fail 'managed cleanup retry stranded STOPPING owner'
[ "$(tail -n 1 "$PIM_CAMERA_CALL_LOG")" = partial:owner_removed ] || fail 'managed cleanup retry did not remove owner last'

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

echo '=== systemd stop uses one bounded queued lock acquisition ==='
reset_case
rm -f "$PIM_CAMERA_RUN_DIR/owner.json"
: > "$WORK/fair-flock-calls"
set +e
PIM_CAMERA_TEST_FLOCK_MODE=starve PIM_CAMERA_TEST_FLOCK_LOG="$WORK/fair-flock-calls" \
PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 bash "$PIM_BIN/cam_operate_stop.sh" --systemd
fair_stop_rc=$?
set -e
[ "$fair_stop_rc" -eq 0 ] || fail "fair queued systemd stop returned rc=$fair_stop_rc"
[ "$(grep -c '^wait:' "$WORK/fair-flock-calls")" -eq 1 ] || fail 'systemd stop did not acquire through one bounded waiter'
[ "$(grep -c '^unlock:' "$WORK/fair-flock-calls")" -eq 1 ] || fail 'systemd stop did not unlock its queued acquisition'
! grep -q '^nonblock:' "$WORK/fair-flock-calls" || fail 'systemd stop leaked nonblocking polling'

echo '=== queued lock preserves acquisition and callback status ==='
fair_lock_callback() { : > "$WORK/fair-lock-callback"; return "${FAIR_LOCK_CALLBACK_RC:-0}"; }
rm -f "$WORK/fair-lock-callback"
: > "$WORK/fair-flock-calls"
(
    export PIM_CAMERA_TEST_FLOCK_MODE=starve PIM_CAMERA_TEST_FLOCK_LOG="$WORK/fair-flock-calls"
    export PIM_CAMERA_TEST_FLOCK_RC=75
    expect_rc 75 _cr_lock_call_wait 30 fair_lock_callback
)
[ ! -e "$WORK/fair-lock-callback" ] || fail 'timed-out queued lock invoked its callback'
[ "$(grep -c '^wait:' "$WORK/fair-flock-calls")" -eq 1 ] || fail 'queued lock timeout changed the acquisition boundary'
! grep -q '^unlock:' "$WORK/fair-flock-calls" || fail 'timed-out queued lock unlocked an unowned lock'

rm -f "$WORK/fair-lock-callback"
: > "$WORK/fair-flock-calls"
(
    export PIM_CAMERA_TEST_FLOCK_MODE=starve PIM_CAMERA_TEST_FLOCK_LOG="$WORK/fair-flock-calls"
    export FAIR_LOCK_CALLBACK_RC=69
    expect_rc 69 _cr_lock_call_wait 30 fair_lock_callback
)
[ -e "$WORK/fair-lock-callback" ] || fail 'queued lock skipped its acquired callback'
[ "$(grep -c '^wait:' "$WORK/fair-flock-calls")" -eq 1 ] || fail 'queued lock repeated acquisition before callback'
[ "$(grep -c '^unlock:' "$WORK/fair-flock-calls")" -eq 1 ] || fail 'queued lock did not unlock after callback failure'

echo '=== systemd BUSY retries retain one queued lock ==='
rm -f "$WORK/fair-retry-count"
: > "$WORK/fair-flock-calls"; : > "$WORK/stop-stub-sleeps"
(
    _cl_ordered_stop_locked() {
        local probe_fd contender_rc
        exec {probe_fd}>"$PIM_CAMERA_RUN_DIR/recovery.lock"
        if "$PIM_CAMERA_REAL_FLOCK" -n "$probe_fd"; then
            contender_rc=0
            "$PIM_CAMERA_REAL_FLOCK" -u "$probe_fd"
        else
            contender_rc=$?
        fi
        exec {probe_fd}>&-
        printf 'contender:%s\n' "$contender_rc" >> "$WORK/fair-flock-calls"
        [ "$contender_rc" -eq 1 ] || return 70

        count=0
        [ ! -e "$WORK/fair-retry-count" ] || count=$(cat "$WORK/fair-retry-count")
        count=$((count + 1))
        printf '%s\n' "$count" > "$WORK/fair-retry-count"
        [ "$count" -ge 3 ] && return 0
        return 75
    }
    export PIM_CAMERA_TEST_FLOCK_MODE=observe PIM_CAMERA_TEST_FLOCK_LOG="$WORK/fair-flock-calls"
    export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 STOP_STUB_SLEEP_LOG="$WORK/stop-stub-sleeps"
    expect_rc 0 cam_liveness_ordered_stop_systemd
)
exec {post_stop_fd}>"$PIM_CAMERA_RUN_DIR/recovery.lock"
if "$PIM_CAMERA_REAL_FLOCK" -n "$post_stop_fd"; then
    post_stop_rc=0
    "$PIM_CAMERA_REAL_FLOCK" -u "$post_stop_fd"
else
    post_stop_rc=$?
fi
exec {post_stop_fd}>&-
[ "$post_stop_rc" -eq 0 ] || fail 'systemd BUSY retry retained its lock after returning'
[ "$(cat "$WORK/fair-retry-count")" -eq 3 ] || fail 'systemd stop did not resume BUSY while holding its lock'
[ "$(grep -c '^wait:' "$WORK/fair-flock-calls")" -eq 1 ] || fail 'systemd BUSY retry reacquired the queued lock'
[ "$(grep -c '^unlock:' "$WORK/fair-flock-calls")" -eq 1 ] || fail 'systemd BUSY retry did not release its single lock'
[ "$(grep -c '^contender:1$' "$WORK/fair-flock-calls")" -eq 3 ] || fail 'systemd BUSY callback ran without exclusive lock ownership'
! grep -q '^nonblock:' "$WORK/fair-flock-calls" || fail 'systemd BUSY retry fell back to nonblocking acquisition'
[ "$(grep -c '^sleep:1$' "$WORK/stop-stub-sleeps")" -eq 2 ] || fail 'systemd in-lock BUSY cadence is not exact'

echo '=== systemd stop waits for an ordinary recovery lock then owns cleanup ==='
reset_case
pending_id=$(cam_request_submit gstapp_restart stop-lock 'systemd lock retry')
printf 'gstApp\nPIMCAM\nvcm\n' > "$WORK/stop-procs"
rm -f "$WORK/lock-holder-ready" "$WORK/lock-holder-release"
(
    exec 9> "$PIM_CAMERA_RUN_DIR/recovery.lock"
    flock 9
    : > "$WORK/lock-holder-ready"
    while [ ! -e "$WORK/lock-holder-release" ]; do /bin/sleep 0.01; done
) & lock_holder_pid=$!
for _ in $(seq 1 500); do
    [ ! -e "$WORK/lock-holder-ready" ] || break
    /bin/sleep 0.01
done
[ -e "$WORK/lock-holder-ready" ] || {
    : > "$WORK/lock-holder-release"
    wait "$lock_holder_pid" 2>/dev/null || :
    fail 'ordinary recovery lock holder did not become ready'
}
PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 PIM_CAMERA_STOP_OBSERVE_OWNER=1 \
    bash "$PIM_BIN/cam_operate_stop.sh" --systemd & systemd_stop_pid=$!
for _ in $(seq 1 50); do
    kill -0 "$systemd_stop_pid" 2>/dev/null || break
    /bin/sleep 0.01
done
if ! kill -0 "$systemd_stop_pid" 2>/dev/null; then
    : > "$WORK/lock-holder-release"
    wait "$lock_holder_pid"
    set +e
    wait "$systemd_stop_pid"; early_stop_rc=$?
    set -e
    fail "systemd stop exited rc=$early_stop_rc instead of waiting behind ordinary lock contention"
fi
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail 'queued lock wait mutated owner before acquisition'
[ -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail 'queued lock wait lost pending request before acquisition'
: > "$WORK/lock-holder-release"
wait "$lock_holder_pid"
wait "$systemd_stop_pid"
[ ! -e "$PIM_CAMERA_RUN_DIR/owner.json" ] || fail 'systemd stop retained owner after lock release'
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail 'systemd stop retained a recovery lease'
[ ! -s "$WORK/stop-procs" ] || fail 'systemd stop left managed children running'
[ "$(grep -c '^managed-owner:.*:present$' "$PIM_CAMERA_CALL_LOG")" -eq 4 ] || fail 'systemd stop did not keep owner through every managed cleanup'
! grep -q '^managed-owner:.*:absent$' "$PIM_CAMERA_CALL_LOG" || fail 'systemd stop removed owner before managed cleanup'
history_path="$PIM_CAMERA_STATE_DIR/recovery/history/$pending_id.json"
jq -e '.request.status=="FAILED" and .request.rc==70 and .request.interrupted==true' "$history_path" >/dev/null || fail 'pending request was not terminalized to persistent interrupted history'
history_before=$(cksum "$history_path")
calls_before=$(cksum "$PIM_CAMERA_CALL_LOG")
PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 expect_rc 0 bash "$PIM_BIN/cam_operate_stop.sh" --systemd
[ "$history_before" = "$(cksum "$history_path")" ] || fail 'completed stop rewrote interrupted history'
[ "$calls_before" = "$(cksum "$PIM_CAMERA_CALL_LOG")" ] || fail 'completed stop repeated managed cleanup'

echo '=== systemd waiter converges behind a competing stop coordinator ==='
reset_case
rm -f "$WORK/concurrent-ready" "$WORK/concurrent-release"
concurrent_id=$(cam_request_submit gstapp_restart stop-race 'concurrent winner')
_cl_stop_event() { printf 'concurrent:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"; }
cam_stop_process() {
    printf 'concurrent-stop:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"
    if [ "$2" = gstapp ]; then
        : > "$WORK/concurrent-ready"
        while [ ! -e "$WORK/concurrent-release" ]; do /bin/sleep 0.01; done
    fi
    return 0
}
cam_liveness_ordered_stop --external & first_stop_pid=$!
for _ in $(seq 1 1000); do [ ! -e "$WORK/concurrent-ready" ] || break; /bin/sleep 0.01; done
[ -e "$WORK/concurrent-ready" ] || { : > "$WORK/concurrent-release"; wait "$first_stop_pid" 2>/dev/null || :; fail 'first concurrent stop did not reach managed cleanup'; }
expect_rc 75 cam_liveness_ordered_stop --external
PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 bash "$PIM_BIN/cam_operate_stop.sh" --systemd & waiting_stop_pid=$!
for _ in $(seq 1 50); do
    kill -0 "$waiting_stop_pid" 2>/dev/null || break
    /bin/sleep 0.01
done
kill -0 "$waiting_stop_pid" 2>/dev/null || {
    : > "$WORK/concurrent-release"
    wait "$first_stop_pid" 2>/dev/null || :
    set +e
    wait "$waiting_stop_pid"; waiting_stop_rc=$?
    set -e
    fail "systemd waiter returned rc=$waiting_stop_rc behind a stop coordinator"
}
: > "$WORK/concurrent-release"
wait "$first_stop_pid"
wait "$waiting_stop_pid"
[ ! -e "$PIM_CAMERA_RUN_DIR/owner.json" ] || fail 'concurrent stop winner stranded owner'
[ "$(grep -c '^concurrent:owner_removed$' "$PIM_CAMERA_CALL_LOG")" -eq 1 ] || fail 'concurrent stops removed owner more than once'
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail 'concurrent stops stranded a lease'
[ "$(find "$PIM_CAMERA_STATE_DIR/recovery/history" -type f -name "$concurrent_id.json" | wc -l)" -eq 1 ] || fail 'concurrent stops duplicated persistent history'
jq -e '.request.status=="FAILED" and .request.rc==70 and .request.interrupted==true' "$PIM_CAMERA_STATE_DIR/recovery/history/$concurrent_id.json" >/dev/null || fail 'concurrent winner did not terminalize pending history'

mkdir -p "$WORK/exit-lib"
for library in cam_recovery.sh cam_recovery_actions.sh cam_operate_control.sh; do : > "$WORK/exit-lib/$library"; done
cat > "$WORK/exit-lib/cam_liveness.sh" <<'SH'
stop_stub_call() {
    route=$1
    shift
    count=0
    [ ! -e "$STOP_STUB_COUNT_FILE" ] || count=$(cat "$STOP_STUB_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$STOP_STUB_COUNT_FILE"
    printf 'call:%s:%s\n' "$route" "$*" >> "$STOP_STUB_CALL_LOG"
    rc=${STOP_STUB_RC:-70}
    if [ -n "${STOP_STUB_SEQUENCE_FILE:-}" ]; then
        sequence_rc=$(sed -n "${count}p" "$STOP_STUB_SEQUENCE_FILE")
        [ -z "$sequence_rc" ] || rc=$sequence_rc
    fi
    return "$rc"
}
cam_liveness_ordered_stop() { stop_stub_call external "$@"; }
cam_liveness_ordered_stop_systemd() { stop_stub_call systemd "$@"; }
SH
for route in no-arg external; do
    for stop_rc in 0 69 70 75; do
        rm -f "$WORK/stop-stub-count"
        : > "$WORK/stop-stub-calls"
        set +e
        if [ "$route" = no-arg ]; then
            PIM_LIB="$WORK/exit-lib" PIM_BIN="$PIM_BIN" STOP_STUB_RC="$stop_rc" \
                STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" \
                bash "$PIM_BIN/cam_operate_stop.sh"
        else
            PIM_LIB="$WORK/exit-lib" PIM_BIN="$PIM_BIN" STOP_STUB_RC="$stop_rc" \
                STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" \
                bash "$PIM_BIN/cam_operate_stop.sh" --external
        fi
        script_rc=$?
        set -e
        [ "$script_rc" -eq "$stop_rc" ] || fail "$route stop hid rc=$stop_rc as rc=$script_rc"
        [ "$(cat "$WORK/stop-stub-count")" -eq 1 ] || fail "$route stop retried rc=$stop_rc"
        [ "$(cat "$WORK/stop-stub-calls")" = 'call:external:--external' ] || fail "$route stop changed the external library boundary"
    done
done

for stop_rc in 0 69 70 75; do
    rm -f "$WORK/stop-stub-count"
    : > "$WORK/stop-stub-calls"
    PIM_LIB="$WORK/exit-lib" PIM_BIN="$PIM_BIN" STOP_STUB_RC="$stop_rc" \
        STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" \
        expect_rc "$stop_rc" bash "$PIM_BIN/cam_operate_stop.sh" --systemd
    [ "$(cat "$WORK/stop-stub-count")" -eq 1 ] || fail "systemd wrapper repeated entrypoint rc=$stop_rc"
    [ "$(cat "$WORK/stop-stub-calls")" = 'call:systemd:' ] || fail 'systemd wrapper bypassed its liveness entrypoint'
done

ordered_stop_retry_stub() {
    count=0
    [ ! -e "$STOP_STUB_COUNT_FILE" ] || count=$(cat "$STOP_STUB_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$STOP_STUB_COUNT_FILE"
    printf 'call:%s\n' "$*" >> "$STOP_STUB_CALL_LOG"
    rc=${STOP_STUB_RC:-70}
    if [ -n "${STOP_STUB_SEQUENCE_FILE:-}" ]; then
        sequence_rc=$(sed -n "${count}p" "$STOP_STUB_SEQUENCE_FILE")
        [ -z "$sequence_rc" ] || rc=$sequence_rc
    fi
    return "$rc"
}

echo '=== only systemd retries exact BUSY with a fixed bound ==='
printf '75\n75\n0\n' > "$WORK/stop-stub-sequence"
rm -f "$WORK/stop-stub-count"
: > "$WORK/stop-stub-calls"; : > "$WORK/stop-stub-sleeps"
(
    _cl_ordered_stop_locked() { ordered_stop_retry_stub "$@"; }
    PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 STOP_STUB_RC=70 \
        STOP_STUB_SEQUENCE_FILE="$WORK/stop-stub-sequence" STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" \
        STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" STOP_STUB_SLEEP_LOG="$WORK/stop-stub-sleeps" \
        expect_rc 0 _cl_ordered_stop_systemd_locked
)
[ "$(cat "$WORK/stop-stub-count")" -eq 3 ] || fail 'systemd stop did not retry BUSY to success'
[ "$(grep -c '^call:1$' "$WORK/stop-stub-calls")" -eq 3 ] || fail 'systemd retry changed the external stop argument'
[ "$(grep -c '^sleep:1$' "$WORK/stop-stub-sleeps")" -eq 2 ] || fail 'systemd BUSY retry sleep is not exact'

for stop_rc in 0 69 70; do
    rm -f "$WORK/stop-stub-count"
    : > "$WORK/stop-stub-calls"; : > "$WORK/stop-stub-sleeps"
    (
        _cl_ordered_stop_locked() { ordered_stop_retry_stub "$@"; }
        PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 STOP_STUB_RC="$stop_rc" \
            STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" \
            STOP_STUB_SLEEP_LOG="$WORK/stop-stub-sleeps" \
            expect_rc "$stop_rc" _cl_ordered_stop_systemd_locked
    )
    [ "$(cat "$WORK/stop-stub-count")" -eq 1 ] || fail "systemd stop retried rc=$stop_rc"
    [ ! -s "$WORK/stop-stub-sleeps" ] || fail "systemd stop slept after rc=$stop_rc"
done

printf '75\n75\n75\n75\n75\n75\n75\n69\n' > "$WORK/stop-stub-sequence"
rm -f "$WORK/stop-stub-count"
: > "$WORK/stop-stub-calls"; : > "$WORK/stop-stub-sleeps"
(
    _cl_ordered_stop_locked() { ordered_stop_retry_stub "$@"; }
    PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7 STOP_STUB_RC=69 \
        STOP_STUB_SEQUENCE_FILE="$WORK/stop-stub-sequence" STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" \
        STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" STOP_STUB_SLEEP_LOG="$WORK/stop-stub-sleeps" \
        expect_rc 75 _cl_ordered_stop_systemd_locked
)
[ "$(cat "$WORK/stop-stub-count")" -eq 7 ] || fail 'systemd retry bound was removed or disabled'
[ "$(grep -c '^sleep:1$' "$WORK/stop-stub-sleeps")" -eq 6 ] || fail 'systemd retry exhaustion slept outside the bound'

echo '=== unsafe systemd attempt overrides fall back to the bounded default ==='
: > "$WORK/stop-stub-sequence"
for _ in $(seq 1 30); do printf '75\n' >> "$WORK/stop-stub-sequence"; done
printf '69\n' >> "$WORK/stop-stub-sequence"
override_failures=
for override_case in absent malformed low-one low-six high-31 high-100 zero negative leading-zero oversized; do
    case "$override_case" in
        absent) unset PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS ;;
        malformed) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=7x ;;
        low-one) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=1 ;;
        low-six) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=6 ;;
        high-31) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=31 ;;
        high-100) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=100 ;;
        zero) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=0 ;;
        negative) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=-7 ;;
        leading-zero) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=07 ;;
        oversized) export PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS=99999999999999999999999999999999999999999999 ;;
    esac
    rm -f "$WORK/stop-stub-count"
    : > "$WORK/stop-stub-calls"; : > "$WORK/stop-stub-sleeps"
    rm -f "$WORK/stop-stub-rc"
    (
        _cl_ordered_stop_locked() { ordered_stop_retry_stub "$@"; }
        set +e
        STOP_STUB_RC=69 STOP_STUB_SEQUENCE_FILE="$WORK/stop-stub-sequence" \
            STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" \
            STOP_STUB_SLEEP_LOG="$WORK/stop-stub-sleeps" _cl_ordered_stop_systemd_locked
        override_rc=$?
        set -e
        printf '%s\n' "$override_rc" > "$WORK/stop-stub-rc"
    )
    override_rc=$(cat "$WORK/stop-stub-rc")
    override_calls=$(cat "$WORK/stop-stub-count" 2>/dev/null || printf 0)
    override_sleeps=$(wc -l < "$WORK/stop-stub-sleeps")
    if [ "$override_rc" -ne 75 ] || [ "$override_calls" -ne 30 ] || [ "$override_sleeps" -ne 29 ]; then
        override_failures="$override_failures $override_case:rc=$override_rc/calls=$override_calls/sleeps=$override_sleeps"
    fi
done
unset PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS
[ -z "$override_failures" ] || fail "unsafe attempt overrides escaped 7..30:$override_failures"

printf '75\n75\n75\n75\n75\n75\n0\n' > "$WORK/stop-stub-sequence"
rm -f "$WORK/stop-stub-count"
: > "$WORK/stop-stub-calls"; : > "$WORK/stop-stub-sleeps"
(
    _cl_ordered_stop_locked() { ordered_stop_retry_stub "$@"; }
    STOP_STUB_RC=70 STOP_STUB_SEQUENCE_FILE="$WORK/stop-stub-sequence" \
        STOP_STUB_COUNT_FILE="$WORK/stop-stub-count" STOP_STUB_CALL_LOG="$WORK/stop-stub-calls" \
        STOP_STUB_SLEEP_LOG="$WORK/stop-stub-sleeps" \
        expect_rc 0 _cl_ordered_stop_systemd_locked
)
[ "$(cat "$WORK/stop-stub-count")" -eq 7 ] || fail 'default systemd retry budget does not exceed the five-second stop wait'
[ "$(grep -c '^sleep:1$' "$WORK/stop-stub-sleeps")" -eq 6 ] || fail 'default systemd retry cadence is not fixed'

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
