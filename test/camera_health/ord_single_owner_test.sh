#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-ord-single-owner.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUNTIME_JSON="$WORK/pim_runtime.json"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_ORD_STATE_FILE="$WORK/ord-state"
export PIM_CAMERA_ORD_POLL_FILE="$WORK/ord-poll"
export PIM_CAMERA_PROCESS_FILE="$WORK/processes"
export PIM_CAMERA_SYSTEMCTL=systemctl
export PATH="$WORK/stub:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() {
    local wanted=$1 got
    shift
    set +e
    "$@"
    got=$?
    set -e
    [ "$got" -eq "$wanted" ] || fail "wanted rc=$wanted got rc=$got: $*"
}

mkdir -p "$WORK/stub"
mkdir -p "$PIM_CAMERA_RUN_DIR"
printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false}},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
: > "$PIM_CAMERA_CALL_LOG"
: > "$PIM_CAMERA_PROCESS_FILE"
printf 'inactive\n' > "$PIM_CAMERA_ORD_STATE_FILE"

cat > "$WORK/stub/systemctl" <<'SH'
#!/bin/sh
printf 'systemctl:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
case "$1" in
    is-active)
        state=$(cat "$PIM_CAMERA_ORD_STATE_FILE") || exit 2
        if [ "$state" = active-then-failed ]; then
            if [ ! -e "$PIM_CAMERA_ORD_POLL_FILE" ]; then
                : > "$PIM_CAMERA_ORD_POLL_FILE"
                printf 'active\n'
                exit 0
            fi
            printf 'failed\n'
            exit 4
        fi
        printf '%s\n' "$state"
        case "$state" in active) exit 0;; inactive) exit 3;; failed) exit 4;; *) exit 2;; esac
        ;;
    show)
        [ "$2" = ord-operate.service ] || exit 64
        [ "$3" = --property=InvocationID ] || exit 64
        [ "$4" = --value ] || exit 64
        printf '%s\n' 0123456789abcdef0123456789abcdef
        ;;
    restart)
        [ "$2" = ord-operate.service ] || exit 64
        [ "${ORD_RESTART_RC:-0}" -eq 0 ] || exit "$ORD_RESTART_RC"
        if [ "${ORD_RESTART_MODE:-ready}" = delayed-fail ]; then
            printf 'active-then-failed\n' > "$PIM_CAMERA_ORD_STATE_FILE"
            rm -f "$PIM_CAMERA_RUN_DIR/ord-ready" "$PIM_CAMERA_ORD_POLL_FILE"
        else
            printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
            printf '%s\n' 0123456789abcdef0123456789abcdef > "$PIM_CAMERA_RUN_DIR/ord-ready"
        fi
        ;;
    stop)
        [ "$2" = ord-operate.service ] || exit 64
        [ "${ORD_STOP_RC:-0}" -eq 0 ] || exit "$ORD_STOP_RC"
        printf 'inactive\n' > "$PIM_CAMERA_ORD_STATE_FILE"
        ;;
    *) exit 64;;
esac
SH
cat > "$WORK/stub/ord" <<'SH'
#!/bin/sh
printf 'direct:ord\n' >> "$PIM_CAMERA_CALL_LOG"
SH
cat > "$WORK/stub/vcm" <<'SH'
#!/bin/sh
printf 'direct:vcm\n' >> "$PIM_CAMERA_CALL_LOG"
SH
cat > "$WORK/stub/pgrep" <<'SH'
#!/bin/sh
target=
for arg; do target=$arg; done
printf 'pgrep:%s\n' "$target" >> "$PIM_CAMERA_CALL_LOG"
[ "$target" != ord ] || [ "${ORD_PROBE_RC:-0}" -eq 0 ] || exit "$ORD_PROBE_RC"
grep -Fqx "$target" "$PIM_CAMERA_PROCESS_FILE"
SH
chmod +x "$WORK/stub"/*

cam_owner_assert() { :; }
_cr_test_owner_rollover() {
    [ "${PIM_CAMERA_TEST_OWNER_ROLLOVER:-}" != "$1" ] || return 69
}
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
cam_executor_assert_context() { :; }
cam_validate_runtime() { :; }

echo '=== generic launcher cannot execute ORD ==='
: > "$PIM_CAMERA_CALL_LOG"
set +e
cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" ord
launch_rc=$?
wait
set -e
[ "$launch_rc" -eq 64 ] || fail "generic ORD launch returned $launch_rc instead of 64"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || {
    cat "$PIM_CAMERA_CALL_LOG" >&2
    fail 'generic launcher executed ORD'
}

echo '=== recovery restart has one systemd owner ==='
: > "$PIM_CAMERA_CALL_LOG"
cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"
expected=$'systemctl:restart ord-operate.service\nsystemctl:is-active ord-operate.service\nsystemctl:show ord-operate.service --property=InvocationID --value'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || {
    cat "$PIM_CAMERA_CALL_LOG" >&2
    fail 'ORD restart did not wait for the restarted invocation'
}

: > "$PIM_CAMERA_CALL_LOG"
ORD_RESTART_RC=23 expect_rc 23 cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = 'systemctl:restart ord-operate.service' ] || fail 'ORD restart failure used another path'

: > "$PIM_CAMERA_CALL_LOG"
# shellcheck disable=SC2329  # invoked by sourced cam_wait_ord_ready
sleep() { :; }
ORD_RESTART_MODE=delayed-fail PIM_CAMERA_READY_TIMEOUT_SEC=1 expect_rc 1 cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"
unset -f sleep
[ "$(grep -Fxc 'systemctl:is-active ord-operate.service' "$PIM_CAMERA_CALL_LOG")" -eq 2 ] || fail 'ORD restart did not observe delayed init failure'

: > "$PIM_CAMERA_CALL_LOG"
PIM_CAMERA_TEST_OWNER_ROLLOVER=launch_ord expect_rc 69 cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail 'owner rollover reached systemd restart'

echo '=== readiness follows the systemd owner ==='
eval "$(declare -f cam_process_present | sed '1s/cam_process_present/cam_process_present_real/')"
cam_process_present() {
    printf 'probe:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"
    return 0
}
printf 'inactive\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 1 cam_verify_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
grep -Fqx 'systemctl:is-active ord-operate.service' "$PIM_CAMERA_CALL_LOG" || fail 'readiness did not inspect ORD unit'
! grep -Fqx 'probe:ord' "$PIM_CAMERA_CALL_LOG" || fail 'readiness accepted an arbitrary ORD process'

printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
rm -f "$PIM_CAMERA_RUN_DIR/ord-ready"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 1 cam_verify_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1

printf '%s\n' fedcba9876543210fedcba9876543210 > "$PIM_CAMERA_RUN_DIR/ord-ready"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 1 cam_verify_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1

printf '%s\n' 0123456789abcdef0123456789abcdef > "$PIM_CAMERA_RUN_DIR/ord-ready"
: > "$PIM_CAMERA_CALL_LOG"
cam_verify_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
expected=$'probe:app\nprobe:bg\nsystemctl:is-active ord-operate.service\nsystemctl:show ord-operate.service --property=InvocationID --value\nprobe:vcm'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || fail 'readiness did not require the active ORD invocation marker'
! grep -Fqx 'probe:ord' "$PIM_CAMERA_CALL_LOG" || fail 'active readiness probed arbitrary ORD ownership'

printf 'active-then-failed\n' > "$PIM_CAMERA_ORD_STATE_FILE"
rm -f "$PIM_CAMERA_RUN_DIR/ord-ready" "$PIM_CAMERA_ORD_POLL_FILE"
: > "$PIM_CAMERA_CALL_LOG"
# shellcheck disable=SC2329  # invoked by sourced cam_wait_process_ready
sleep() { :; }
PIM_CAMERA_READY_TIMEOUT_SEC=1 expect_rc 1 cam_wait_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
unset -f sleep
[ "$(grep -Fxc 'systemctl:is-active ord-operate.service' "$PIM_CAMERA_CALL_LOG")" -eq 2 ] || fail 'delayed ORD init failure was not observed'
eval "$(declare -f cam_process_present_real | sed '1s/cam_process_present_real/cam_process_present/')"

echo '=== recovery stop uses systemd and rejects rogue ORD ==='
: > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
cam_stop_ord "$PIM_CAMERA_RUNTIME_JSON"
expected=$'systemctl:stop ord-operate.service\npgrep:ord'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || {
    cat "$PIM_CAMERA_CALL_LOG" >&2
    fail 'ORD stop did not verify systemd-owned shutdown'
}

printf 'ord\n' > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 1 cam_stop_ord "$PIM_CAMERA_RUNTIME_JSON"

: > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
ORD_STOP_RC=23 expect_rc 23 cam_stop_ord "$PIM_CAMERA_RUNTIME_JSON"
! grep -Fqx 'pgrep:ord' "$PIM_CAMERA_CALL_LOG" || fail 'failed systemd stop was reinterpreted by a process probe'

echo '=== liveness stop delegates to guarded ORD shutdown ==='
cam_mark_degraded() { :; }
# shellcheck source=/dev/null
source "$PIM_LIB/cam_liveness.sh"
eval "$(declare -f cam_stop_ord | sed '1s/cam_stop_ord/cam_stop_ord_real/')"
cam_stop_ord() {
    printf 'delegate:ord\n' >> "$PIM_CAMERA_CALL_LOG"
    cam_stop_ord_real "$@"
}
cam_stop_process() {
    printf 'managed:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"
    [ "$2" != "${MANAGED_FAIL_KIND:-}" ] || return "${MANAGED_FAIL_RC:-69}"
}
_cl_stopping_guard() {
    printf 'guard:stopping\n' >> "$PIM_CAMERA_CALL_LOG"
    [ "${STOP_GUARD_RC:-0}" -eq 0 ] || return "$STOP_GUARD_RC"
}

: > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
cam_liveness_stop_managed
expected=$'managed:gstapp\nmanaged:pimcam\nmanaged:bg\nguard:stopping\ndelegate:ord\nsystemctl:stop ord-operate.service\npgrep:ord\nmanaged:vcm'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || fail 'liveness stop bypassed the guarded ORD helper or changed order'
[ -z "${PIM_CAMERA_STOP_EXECUTOR:-}" ] || fail 'liveness stop leaked stop-executor authority'

: > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
ORD_STOP_RC=23 expect_rc 23 cam_liveness_stop_managed
grep -Fqx 'delegate:ord' "$PIM_CAMERA_CALL_LOG" || fail 'systemd stop failure bypassed the shared helper'
! grep -Fqx 'pgrep:ord' "$PIM_CAMERA_CALL_LOG" || fail 'systemd stop failure reached the ORD probe'
! grep -Fqx 'managed:vcm' "$PIM_CAMERA_CALL_LOG" || fail 'systemd stop failure continued into VCM stop'

printf 'ord\n' > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 1 cam_liveness_stop_managed
grep -Fqx 'delegate:ord' "$PIM_CAMERA_CALL_LOG" || fail 'rogue ORD check bypassed the shared helper'
! grep -Fqx 'managed:vcm' "$PIM_CAMERA_CALL_LOG" || fail 'rogue ORD continued into VCM stop'

: > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
ORD_PROBE_RC=23 expect_rc 23 cam_liveness_stop_managed
! grep -Fqx 'managed:vcm' "$PIM_CAMERA_CALL_LOG" || fail 'ORD probe failure continued into VCM stop'

: > "$PIM_CAMERA_CALL_LOG"
STOP_GUARD_RC=69 expect_rc 69 cam_liveness_stop_managed
! grep -Fqx 'delegate:ord' "$PIM_CAMERA_CALL_LOG" || fail 'failed STOPPING guard reached ORD helper'

echo 'ord single owner: PASS'
