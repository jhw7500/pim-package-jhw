#!/usr/bin/env bash
# Executor contract: runs only against command/sysfs stubs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-recovery-actions.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_CAMERA_RUNTIME_JSON="$WORK/run/config/pim_runtime.json"
export PIM_CAMERA_SYSFS_ROOT="$WORK/sys"
export PIM_CAMERA_DEVICE_ROOT="$WORK/dev"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_START_CAM="$WORK/start-cam"
export PIM_CAMERA_SHM_DIR="$WORK/shm"
DAEMON_PID=4242

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { "$@" || fail "command failed: $*"; }
expect_rc() { local wanted=$1; shift; set +e; "$@"; local got=$?; set -e; [ "$got" = "$wanted" ] || fail "expected rc=$wanted got=$got: $*"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
runtime() { mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")"; printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"tmp_path":"/tmp"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"; }
owner_active() { rm -f "$PIM_CAMERA_RUN_DIR/owner.json"; cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE; }
prepare_sysfs() {
    local d
    for d in mxc-mipi-csi2-sam mxc-isi isi-capture isi-m2m; do mkdir -p "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d"; : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/unbind"; : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/bind"; done
    mkdir -p "$PIM_CAMERA_DEVICE_ROOT"; : > "$PIM_CAMERA_DEVICE_ROOT/video3"; : > "$PIM_CAMERA_DEVICE_ROOT/video4"
    mkdir -p "$PIM_CAMERA_SHM_DIR"
}
prepare_stubs() {
    mkdir -p "$WORK/stub"; : > "$PIM_CAMERA_CALL_LOG"
    for cmd in kill pkill rmmod modprobe reboot logger sleep; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >> "$PIM_CAMERA_CALL_LOG"\n[ "$(basename "$0")" = modprobe ] && [ "$1" = "${FAIL_MODPROBE:-}" ] && exit 23\nexit 0\n' > "$WORK/stub/$cmd"
        chmod +x "$WORK/stub/$cmd"
    done
    printf '#!/bin/sh\nprintf "pgrep %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\nexit 0\n' > "$WORK/stub/pgrep"
    printf '#!/bin/sh\nprintf "lsmod\\n" >> "$PIM_CAMERA_CALL_LOG"\nexit 0\n' > "$WORK/stub/lsmod"
    printf '#!/bin/sh\nprintf "start_cam\\n" >> "$PIM_CAMERA_CALL_LOG"\nexit 0\n' > "$PIM_CAMERA_START_CAM"
    chmod +x "$WORK/stub/pgrep" "$WORK/stub/lsmod" "$PIM_CAMERA_START_CAM"
    export PATH="$WORK/stub:$PATH"
}

printf 'boot\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat
prepare_stubs
prepare_sysfs
runtime
# This is the RED boundary: Task 3 must provide the only action executor.
source "$PIM_LIB/cam_recovery.sh"
source "$PIM_LIB/cam_recovery_actions.sh"
# Protocol durability is covered separately; avoid repeated disk flush latency here.
_cr_fsync_file() { :; }
_cr_fsync_dir() { :; }

owner_active
expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" gstapp_restart test "restart"
grep -q '^pkill .*gstApp' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "gstapp restart did not quiesce app"; }
grep -q '^pkill .*BG_Check_for_pim.sh' "$PIM_CAMERA_CALL_LOG" || fail "gstapp restart did not quiesce BG child"
grep -q '^start_cam$' "$PIM_CAMERA_CALL_LOG" || fail "gstapp restart did not use internal launcher"
# The first request proves the full lease guard before process side effects.  The
# remaining stub-only order cases do not need to re-run its expensive tuple reads.
cam_executor_assert_context() { return 0; }

owner_active
printf '{bad json}\n' > "$PIM_CAMERA_RUNTIME_JSON"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 64 cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" module_reload test invalid
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail "invalid runtime performed a side effect"
runtime

owner_active
FAIL_MODPROBE=max9296 expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" module_reload test fallback
grep -q '^reboot ' "$PIM_CAMERA_CALL_LOG" || fail "module and hard-reset failure did not request reboot"
[ "$(grep -c '^reboot ' "$PIM_CAMERA_CALL_LOG")" -eq 1 ] || fail "reboot requested more than once"
history=$(grep -rl '"reboot_fallback"' "$PIM_CAMERA_STATE_DIR/recovery/history")
jq -e '[.actions[].action] == ["module_reload","camera_hard_reset","reboot_fallback"]' "$history" >/dev/null || { cat "$history" >&2; fail "fallback actions were not ordered"; }

owner_active
: > "$PIM_CAMERA_CALL_LOG"
expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" camera_hard_reset test hard
unbind=$(grep '^sysfs unbind ' "$PIM_CAMERA_CALL_LOG" | tr '\n' ',')
bind=$(grep '^sysfs bind ' "$PIM_CAMERA_CALL_LOG" | tr '\n' ',')
case "$unbind" in *isi-capture*isi-m2m*mxc-isi*mxc-mipi-csi2-sam*) ;; *) fail "child-first unbind order: $unbind";; esac
case "$bind" in *mxc-mipi-csi2-sam*mxc-isi*) ;; *) fail "parent-first bind order: $bind";; esac
! grep -q 'systemctl .*cam-operate' "$PIM_CAMERA_CALL_LOG" || fail "hard reset controlled cam-operate service"

echo "recovery actions: PASS"
