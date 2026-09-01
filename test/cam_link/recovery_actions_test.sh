#!/usr/bin/env bash
# Executor contract: runs only against command/sysfs stubs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-recovery-actions.XXXXXX")
export WORK
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
export PIM_CAMERA_PROCESS_ROOT="$WORK/processes"
DAEMON_PID=4242

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { "$@" || fail "command failed: $*"; }
expect_rc() { local wanted=$1; shift; set +e; "$@"; local got=$?; set -e; [ "$got" = "$wanted" ] || fail "expected rc=$wanted got=$got: $*"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
runtime() { mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")"; printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"tmp_path":"'"$WORK"'/recordings","vhl_name":"VD3001"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"; mkdir -p "$WORK/recordings"; printf '%s\n' '20260901 12:34:56' > "$WORK/start-time"; export PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time"; }
owner_active() { rm -f "$PIM_CAMERA_RUN_DIR/owner.json"; cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE; }
prepare_sysfs() {
    local d
    for d in mxc-mipi-csi2-sam mxc-isi isi-capture isi-m2m; do mkdir -p "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d"; : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/unbind"; : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/bind"; done
    mkdir -p "$PIM_CAMERA_DEVICE_ROOT"; : > "$PIM_CAMERA_DEVICE_ROOT/video3"; : > "$PIM_CAMERA_DEVICE_ROOT/video4"
    mkdir -p "$PIM_CAMERA_SHM_DIR"
}
prepare_stubs() {
    mkdir -p "$WORK/stub"; : > "$PIM_CAMERA_CALL_LOG"
    for cmd in rmmod modprobe reboot logger sleep; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >> "$PIM_CAMERA_CALL_LOG"\n[ "$(basename "$0")" = modprobe ] && [ "$1" = "${FAIL_MODPROBE:-}" ] && exit 23\nexit 0\n' > "$WORK/stub/$cmd"
        chmod +x "$WORK/stub/$cmd"
    done
    printf '#!/bin/sh\nprintf "kill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\nrm -f "$PIM_CAMERA_PROCESS_ROOT/$2/cmdline"\nexit 0\n' > "$WORK/stub/kill"
    chmod +x "$WORK/stub/kill"
    printf '#!/bin/sh\nlast=\nfor arg; do last=$arg; done\nprintf "pgrep %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ngrep -Fqx "$last" "$WORK/procs" 2>/dev/null\n' > "$WORK/stub/pgrep"
    printf '#!/bin/sh\nlast=\nfor arg; do last=$arg; done\nprintf "pkill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ngrep -Fvx "$last" "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :\nmv "$WORK/procs.next" "$WORK/procs"\ncase "$last" in *BG_Check_for_pim.sh) rm -f "$PIM_CAMERA_PROCESS_ROOT"/*/cmdline;; esac\n' > "$WORK/stub/pkill"
    printf '#!/bin/sh\nprintf "lsmod\\n" >> "$PIM_CAMERA_CALL_LOG"\nexit 0\n' > "$WORK/stub/lsmod"
    printf '#!/bin/sh\nprintf "start_cam\\n" >> "$PIM_CAMERA_CALL_LOG"\nprintf "gstApp\\n" >> "$WORK/procs"\nmkdir -p "$PIM_CAMERA_PROCESS_ROOT/100"\nprintf "%%s" "100 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1000 0" > "$PIM_CAMERA_PROCESS_ROOT/100/stat"\nprintf "/bin/bash\\000'"$PIM_BIN"'/BG_Check_for_pim.sh\\0004\\000" > "$PIM_CAMERA_PROCESS_ROOT/100/cmdline"\nexit 0\n' > "$PIM_CAMERA_START_CAM"
    for cmd in ord vcm; do printf '#!/bin/sh\nprintf "%%s\\n" "$(basename "$0")" >> "$WORK/procs"\n' > "$WORK/stub/$cmd"; chmod +x "$WORK/stub/$cmd"; done
    chmod +x "$WORK/stub/pgrep" "$WORK/stub/pkill" "$WORK/stub/lsmod" "$PIM_CAMERA_START_CAM"
    export PATH="$WORK/stub:$PATH"
}

printf 'boot\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat
prepare_stubs
enable -n kill
export PIM_CAMERA_BG_CHECKER="$PIM_BIN/BG_Check_for_pim.sh"
printf 'gstApp\n%s\n' "$PIM_CAMERA_BG_CHECKER" > "$WORK/procs"
mkdir -p "$PIM_CAMERA_PROCESS_ROOT/99"
printf '%s' '99 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999 0' > "$PIM_CAMERA_PROCESS_ROOT/99/stat"
printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/99/cmdline"
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
grep -q '^kill -TERM 99$' "$PIM_CAMERA_CALL_LOG" || fail "gstapp restart did not quiesce BG child by exact argv identity"
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
touch "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/isi-capture/32e00000.isi:cap_device"
touch "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/isi-capture/32e02000.isi:cap_device"
touch "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/isi-m2m/32e00000.isi:m2m_device"
expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" camera_hard_reset test hard
unbind=$(grep '^sysfs unbind ' "$PIM_CAMERA_CALL_LOG" | tr '\n' ',')
bind=$(grep '^sysfs bind ' "$PIM_CAMERA_CALL_LOG" | tr '\n' ',')
case "$unbind" in *isi-capture*isi-m2m*mxc-isi*mxc-mipi-csi2-sam*) ;; *) fail "child-first unbind order: $unbind";; esac
case "$bind" in *mxc-mipi-csi2-sam*mxc-isi*) ;; *) fail "parent-first bind order: $bind";; esac
! grep -q 'systemctl .*cam-operate' "$PIM_CAMERA_CALL_LOG" || fail "hard reset controlled cam-operate service"
! grep -q '^sysfs bind 32e00000.isi:cap_device ' "$PIM_CAMERA_CALL_LOG" || fail "auto-bound capture child was bound twice"
! grep -q '^sysfs bind 32e00000.isi:m2m_device ' "$PIM_CAMERA_CALL_LOG" || fail "auto-bound m2m child was bound twice"

# Review regressions: cleanup must be session-scoped and never delete unrelated
# markers; BG identity must use full-command matching; child auto-bind is skipped.
mkdir -p "$WORK/recordings"
printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"tmp_path":"'"$WORK"'/recordings","vhl_name":"VD3001"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
printf '%s\n' '20260901 12:34:56' > "$WORK/start-time"
touch "$WORK/recordings/VD3001_20260901_1234-ch0.mp4" "$WORK/recordings/VD3001_20260901_1235-ch0.mp4" "$WORK/recordings/other_20260901_1234.mp4"
touch "$WORK/session_keep.video_done" "$WORK/session_keep.srt_done"
PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time" cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"
[ ! -e "$WORK/recordings/VD3001_20260901_1234-ch0.mp4" ] || fail "current session recording survived cleanup"
[ -e "$WORK/recordings/VD3001_20260901_1235-ch0.mp4" ] || fail "next session recording was over-deleted"
[ -e "$WORK/recordings/other_20260901_1234.mp4" ] || fail "other vehicle recording was over-deleted"
[ -e "$WORK/session_keep.video_done" ] && [ -e "$WORK/session_keep.srt_done" ] || fail "unrelated session marker was deleted"
printf '%s\n' '../../unsafe' > "$WORK/start-time"
PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time" cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"
[ -e "$WORK/recordings/VD3001_20260901_1235-ch0.mp4" ] || fail "malformed marker deleted a recording"
printf '%s\n' '20260901 12:34:56' > "$WORK/start-time"
ln -s "$WORK/recordings" "$WORK/linked-recordings"
printf '%s\n' '{"VHL_CAM":{"tmp_path":"'"$WORK"'/linked-recordings","vhl_name":"VD3001"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
expect_rc 64 env PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time" bash -c 'source "$PIM_LIB/cam_recovery_actions.sh"; cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"'

echo "recovery actions: PASS"
