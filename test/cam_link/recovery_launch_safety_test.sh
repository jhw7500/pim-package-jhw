#!/usr/bin/env bash
# Fast launch/readiness boundary checks using a real recovery owner/request.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/pim-launch-safety.XXXXXX")
trap 'rm -rf "$W"' EXIT

export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUN_DIR="$W/run"
export PIM_CAMERA_STATE_DIR="$W/state"
export PIM_CAMERA_BOOT_ID_FILE="$W/boot-id"
export PIM_CAMERA_PROC_ROOT="$W/owner-proc"
export PIM_CAMERA_RUNTIME_JSON="$W/run/config/pim_runtime.json"
export PIM_CAMERA_PROCESS_ROOT="$W/processes"
export PIM_CAMERA_DEVICE_ROOT="$W/dev"
export PIM_CAMERA_SYSFS_ROOT="$W/sys"
export PIM_CAMERA_CALL_LOG="$W/calls"
export PIM_CAMERA_PROBE_LOG="$W/probes"
export PIM_CAMERA_PRESENT_FILE="$W/present"
export PIM_CAMERA_BG_CHECKER="$W/stub/BG_Check_for_pim.sh"
export PATH="$W/stub:$PATH"
DAEMON_PID=4242

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
assert_no_target_execs() {
    [ ! -s "$PIM_CAMERA_CALL_LOG" ] || {
        cat "$PIM_CAMERA_CALL_LOG" >&2
        fail "$1 executed a target after owner rollover"
    }
}
fake_owner_stat() {
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    {
        printf '%s (cam-operate) S' "$DAEMON_PID"
        for _ in {1..18}; do printf ' 0'; done
        printf ' 111 0\n'
    } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
}
fake_bg_present() {
    local pid=${1:-900} start=${2:-9000}
    mkdir -p "$PIM_CAMERA_PROCESS_ROOT/$pid"
    {
        printf '%s (BG Check) S' "$pid"
        for _ in {1..18}; do printf ' 0'; done
        printf ' %s 0\n' "$start"
    } > "$PIM_CAMERA_PROCESS_ROOT/$pid/stat"
    printf '/bin/bash\000%s\0000\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$pid/cmdline"
}
prepare_context() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR"
    mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROCESS_ROOT"
    printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"app_delay":0,"tmp_path":"'"$W"'/recordings","vhl_name":"VD3001"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
    cam_owner_create "$DAEMON_PID"
    cam_owner_set_lifecycle ACTIVE
    cam_request_submit gstapp_restart launch-safety "boundary test" >/dev/null
    cam_request_claim
    cam_owner_set_lifecycle RECOVERING
    cam_request_transition QUIESCING
    cam_request_transition RUNNING
    cam_executor_set_context
    [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = RECOVERING ] ||
        fail "owner did not enter RECOVERING"
    [ "$(jq -r .status "$PIM_CAMERA_RUN_DIR/recovery/active.json")" = RUNNING ] ||
        fail "request did not become active RUNNING"
    cam_executor_assert_context
}
run_start_cam_and_wait() {
    local rc
    set +e
    (
        trap 'wait || :' EXIT
        set -- 0
        source "$PIM_BIN/start_cam.sh"
    )
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || [ "$rc" -eq 69 ] || fail "start_cam rollover rc=$rc"
}

mkdir -p "$W/stub" "$W/owner-proc" "$W/processes" "$W/dev" "$W/sys" "$W/recordings"
printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_owner_stat
: > "$PIM_CAMERA_CALL_LOG"
: > "$PIM_CAMERA_PRESENT_FILE"
: > "$PIM_CAMERA_PROBE_LOG"

printf '#!/bin/sh\nprintf "target %%s %%s\\n" "$(basename "$0")" "$*" >> "$PIM_CAMERA_CALL_LOG"\n' > "$W/stub/gstApp"
cp "$W/stub/gstApp" "$W/stub/BG_Check_for_pim.sh"
cp "$W/stub/gstApp" "$W/stub/ord"
cp "$W/stub/gstApp" "$W/stub/vcm"
printf '#!/bin/sh\nlast=\nfor arg; do last=$arg; done\nprintf "pgrep %%s\\n" "$last" >> "$PIM_CAMERA_PROBE_LOG"\ngrep -Fqx "$last" "$PIM_CAMERA_PRESENT_FILE" 2>/dev/null\n' > "$W/stub/pgrep"
printf '#!/bin/sh\nprintf "rmmod %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\n' > "$W/stub/rmmod"
printf '#!/bin/sh\nprintf "modprobe %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\n' > "$W/stub/modprobe"
printf '#!/bin/sh\nprintf "%%s\\n" "${LSMOD_ROWS:-}"\nexit "${LSMOD_RC:-0}"\n' > "$W/stub/lsmod"
chmod +x "$W/stub"/*

source "$PIM_LIB/cam_recovery.sh"
source "$PIM_LIB/cam_recovery_actions.sh"
# The authorization/state transitions stay real; only durability latency is
# removed from this fast boundary matrix.
_cr_fsync_file() { :; }
_cr_fsync_dir() { :; }

# Missing consumer binaries are rejected before a background child exists.
PATH="$W/no-binaries" expect_rc 127 cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" ord
PATH="$W/no-binaries" expect_rc 127 cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" vcm

# Real owner/request rollover at every launch boundary produces zero target execs.
prepare_context
rm -rf "$PIM_CAMERA_PROCESS_ROOT"/*
fake_bg_present
: > "$PIM_CAMERA_PRESENT_FILE"
: > "$PIM_CAMERA_CALL_LOG"
PIM_CAMERA_TEST_OWNER_ROLLOVER=launch_app run_start_cam_and_wait
assert_no_target_execs launch_app
expect_rc 69 cam_executor_assert_context

prepare_context
rm -rf "$PIM_CAMERA_PROCESS_ROOT"/*
printf 'gstApp\n' > "$PIM_CAMERA_PRESENT_FILE"
: > "$PIM_CAMERA_CALL_LOG"
PIM_CAMERA_TEST_OWNER_ROLLOVER=launch_bg run_start_cam_and_wait
assert_no_target_execs launch_bg
expect_rc 69 cam_executor_assert_context

for consumer in ord vcm; do
    prepare_context
    : > "$PIM_CAMERA_CALL_LOG"
    PIM_CAMERA_TEST_OWNER_ROLLOVER="launch_$consumer" cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" "$consumer"
    child=$!
    expect_rc 69 wait "$child"
    assert_no_target_execs "launch_$consumer"
    expect_rc 69 cam_executor_assert_context
done
unset PIM_CAMERA_TEST_OWNER_ROLLOVER

# Keep the real authorization guard: the final launch rollover left a stale
# context, which must return 69 before any readiness probe.
: > "$PIM_CAMERA_PROBE_LOG"
expect_rc 69 cam_wait_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
[ ! -s "$PIM_CAMERA_PROBE_LOG" ] || fail "guard 69 reached a readiness probe"

# Deterministic probe matrix for app/bg/ord/vcm. Inspection errors are terminal,
# and consumer mode requires all four targets rather than a partial set.
prepare_context
# Authorization was exercised above with the real guard, including rc 69. Keep
# the larger readiness-state matrix focused and fast after that boundary.
cam_side_effect_guard() { :; }
PROBE_MODE=all
PROBE_TARGET=
PROBE_TARGET_COUNT=0
SLEEP_COUNT=0
cam_process_present() {
    local kind=$2
    printf '%s\n' "$kind" >> "$PIM_CAMERA_PROBE_LOG"
    case "$PROBE_MODE:$kind" in
        error:"$PROBE_TARGET") return 7 ;;
        missing:"$PROBE_TARGET") return 1 ;;
        early_exit:"$PROBE_TARGET")
            PROBE_TARGET_COUNT=$((PROBE_TARGET_COUNT + 1))
            return 1
            ;;
        delayed:"$PROBE_TARGET")
            PROBE_TARGET_COUNT=$((PROBE_TARGET_COUNT + 1))
            [ "$PROBE_TARGET_COUNT" -gt 1 ]
            return
            ;;
    esac
    return 0
}
sleep() { SLEEP_COUNT=$((SLEEP_COUNT + 1)); }

for target in app bg ord vcm; do
    PROBE_MODE=error
    PROBE_TARGET=$target
    PROBE_TARGET_COUNT=0
    SLEEP_COUNT=0
    : > "$PIM_CAMERA_PROBE_LOG"
    expect_rc 7 cam_verify_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
    expect_rc 7 cam_wait_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
    [ "$SLEEP_COUNT" -eq 0 ] || fail "$target inspection error was retried as absence"
done

# Exercise both module/hard-reset action modes while leaving their final real
# readiness gate intact. Lower hardware/launch operations are inert fixtures.
cam_quiesce_consumers() { :; }
cam_module_reload() { :; }
cam_verify_camera_ready() { :; }
cam_restart_ord() { :; }
cam_restart_vcm() { :; }
cam_start_gstapp() { :; }
cam_unload_module() { :; }
cam_sysfs_write() { :; }
cam_effect() { :; }
run_required_mode() {
    case "$1" in
        module) cam_action_module_reload "$PIM_CAMERA_RUNTIME_JSON" ;;
        hard-reset) cam_action_camera_hard_reset "$PIM_CAMERA_RUNTIME_JSON" ;;
        *) return 64 ;;
    esac
}

for mode in module hard-reset; do
    PROBE_MODE=all
    PROBE_TARGET=
    PIM_CAMERA_READY_TIMEOUT_SEC=0
    run_required_mode "$mode" || fail "$mode rejected all-present targets"

    for target in app bg ord vcm; do
        PROBE_MODE=missing
        PROBE_TARGET=$target
        PROBE_TARGET_COUNT=0
        PIM_CAMERA_READY_TIMEOUT_SEC=0
        expect_rc 1 run_required_mode "$mode"

        PROBE_MODE=delayed
        PROBE_TARGET=$target
        PROBE_TARGET_COUNT=0
        PIM_CAMERA_READY_TIMEOUT_SEC=1
        run_required_mode "$mode" || fail "$mode did not observe delayed $target"
        [ "$PROBE_TARGET_COUNT" -eq 2 ] || fail "$mode delayed $target was not polled twice"
    done

    for target in app bg ord vcm; do
        PROBE_MODE=early_exit
        PROBE_TARGET=$target
        PROBE_TARGET_COUNT=0
        PIM_CAMERA_READY_TIMEOUT_SEC=1
        expect_rc 1 run_required_mode "$mode"
        [ "$PROBE_TARGET_COUNT" -eq 2 ] || fail "$mode early-exit $target did not fail at timeout"
    done
done

# Restore the production quiesce/action functions for the sequential-stop race.
source "$PIM_LIB/cam_recovery_actions.sh"
STOPPED_ALL=0
STOP_LOG="$W/stops"
: > "$STOP_LOG"
cam_stop_process() {
    printf '%s\n' "$2" >> "$STOP_LOG"
    [ "$2" != vcm ] || STOPPED_ALL=1
    return 0
}
cam_process_present() {
    local kind=$2
    [ "$STOPPED_ALL" -eq 1 ] || fail "aggregate probe ran before all sequential stops"
    case "${AGGREGATE_MODE:-reappear}:$kind" in
        reappear:app) return 0 ;;
        detector:app) return 7 ;;
        *) return 1 ;;
    esac
}

: > "$PIM_CAMERA_CALL_LOG"
AGGREGATE_MODE=reappear expect_rc 1 cam_action_module_reload "$PIM_CAMERA_RUNTIME_JSON"
[ "$(tr '\n' ' ' < "$STOP_LOG")" = 'app bg ord vcm ' ] || fail "unexpected sequential stop order"
! grep -Eq 'rmmod|modprobe|sysfs|target|start' "$PIM_CAMERA_CALL_LOG" || fail "reappearance allowed reset/start side effects"

STOPPED_ALL=0
: > "$STOP_LOG"
: > "$PIM_CAMERA_CALL_LOG"
AGGREGATE_MODE=detector expect_rc 7 cam_action_module_reload "$PIM_CAMERA_RUNTIME_JSON"
! grep -Eq 'rmmod|modprobe|sysfs|target|start' "$PIM_CAMERA_CALL_LOG" || fail "aggregate detector error allowed side effects"

echo 'recovery launch safety: PASS'
