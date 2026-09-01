#!/usr/bin/env bash
# Fast safety matrix for recovery actions; all external effects are stubs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/pim-safety.XXXXXX")
trap 'rm -rf "$W"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib" PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_PROCESS_ROOT="$W/proc" PIM_CAMERA_RUNTIME_JSON="$W/runtime.json"
export PIM_CAMERA_SESSION_TIME_FILE="$W/marker" PIM_CAMERA_CALL_LOG="$W/calls"
mkdir -p "$W/stub" "$W/recordings" "$PIM_CAMERA_PROCESS_ROOT"
export PATH="$W/stub:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local n=$1; shift; set +e; "$@"; local r=$?; set -e; [ "$r" = "$n" ] || fail "wanted $n got $r: $*"; }
runtime() { printf '{"VHL_CAM":{"tmp_path":"%s","vhl_name":"VD3001"}}\n' "$1" > "$PIM_CAMERA_RUNTIME_JSON"; }
statfile() { local p=$1 s=$2; { printf '%s (BG Check) S' "$p"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0\n' "$s"; } > "$PIM_CAMERA_PROCESS_ROOT/$p/stat"; }
bg() { local p=$1 s=$2 mode=${3:-real}; mkdir -p "$PIM_CAMERA_PROCESS_ROOT/$p"; statfile "$p" "$s"; case "$mode" in real) printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$p/cmdline";; false) printf '/bin/bash\000other\0004\000%s\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$p/cmdline";; esac; }
printf '#!/bin/sh\nexit 1\n' > "$W/stub/pgrep"
printf '#!/bin/sh\nprintf "kill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\n[ "${IMMORTAL:-0}" = 1 ] || rm -f "$PIM_CAMERA_PROCESS_ROOT/$2/cmdline"\n' > "$W/stub/kill"
printf '#!/bin/sh\nprintf "%%s\\n" "${LSMOD_ROWS:-}"\nexit "${LSMOD_RC:-0}"\n' > "$W/stub/lsmod"
printf '#!/bin/sh\nprintf "rmmod %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\nexit "${RMMOD_RC:-0}"\n' > "$W/stub/rmmod"
printf '#!/bin/sh\nprintf "modprobe %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\n' > "$W/stub/modprobe"
printf '#!/bin/sh\nexit 0\n' > "$W/stub/sleep"
chmod +x "$W/stub"/*
enable -n kill
export PIM_CAMERA_BG_CHECKER="$PIM_BIN/BG_Check_for_pim.sh"
source "$PIM_LIB/cam_recovery_actions.sh"
cam_executor_assert_context() { :; }; cam_validate_runtime() { :; }

# RED before the compact-marker implementation accepted only dashed dates.
runtime "$W/recordings"; printf '20260901 12:34:56\n' > "$W/marker"
touch "$W/recordings/VD3001_20260901_1234-a.mp4" "$W/recordings/VD3001_20260901_1235-b.mp4"
cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"
[ ! -e "$W/recordings/VD3001_20260901_1234-a.mp4" ] || fail compact
[ -e "$W/recordings/VD3001_20260901_1235-b.mp4" ] || fail retained
for marker in missing empty bad; do
  touch "$W/recordings/VD3001_20260901_1234-$marker.mp4"
  case "$marker" in missing) rm -f "$W/marker";; empty) : > "$W/marker";; bad) printf bad > "$W/marker";; esac
  cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"
  [ -e "$W/recordings/VD3001_20260901_1234-$marker.mp4" ] || fail "unsafe marker $marker deleted"
done
printf '20260901 12:34:56\n' > "$W/marker"
ln -s "$W/recordings" "$W/link"
for bad in / relative ../x "$W/link"; do runtime "$bad"; expect_rc 64 cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"; done
[ -e "$W/recordings/VD3001_20260901_1234-missing.mp4" ] || fail symlink_target
runtime "$W/recordings"

# Two real shebang BG processes are found under pipefail; later argv is not identity.
bg 101 1001; bg 102 1002; bg 103 1003 false
records=$(cam_bg_checker_records "$PIM_CAMERA_BG_CHECKER")
[ "$(printf '%s\n' "$records" | wc -l)" -eq 2 ] || fail multi_bg
! printf '%s\n' "$records" | grep -q 103 || fail false_argv
: > "$PIM_CAMERA_CALL_LOG"; cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" bg
grep -q 'kill -TERM 101' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail term; }
grep -q 'kill -TERM 102' "$PIM_CAMERA_CALL_LOG" || fail term_multi

# Reused PID (changed start) is never killed; TERM-ignore reaches KILL; immortal/error block modules.
bg 104 1004; records=$(cam_bg_checker_records "$PIM_CAMERA_BG_CHECKER"); statfile 104 9999
: > "$PIM_CAMERA_CALL_LOG"; cam_signal_process "$PIM_CAMERA_RUNTIME_JSON" -TERM bg "$records" || true
! grep -q '104' "$PIM_CAMERA_CALL_LOG" || fail reused_pid
bg 105 1005; : > "$PIM_CAMERA_CALL_LOG"; IMMORTAL=1 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" bg || true
grep -q 'kill -KILL 105' "$PIM_CAMERA_CALL_LOG" || fail kill_escalation
bg 106 1006; : > "$PIM_CAMERA_CALL_LOG"; IMMORTAL=1 cam_action_module_reload "$PIM_CAMERA_RUNTIME_JSON" || true
! grep -Eq 'rmmod|modprobe|start_cam' "$PIM_CAMERA_CALL_LOG" || fail immortal_side_effect
touch "$PIM_CAMERA_PROCESS_ROOT/.inspect_error"; : > "$PIM_CAMERA_CALL_LOG"; cam_action_module_reload "$PIM_CAMERA_RUNTIME_JSON" || true
! grep -Eq 'rmmod|modprobe|start_cam' "$PIM_CAMERA_CALL_LOG" || fail inspect_side_effect
rm -f "$PIM_CAMERA_PROCESS_ROOT/.inspect_error" "$PIM_CAMERA_PROCESS_ROOT"/*/cmdline

# Module absent, detector error, and real unload refusal are distinct.
: > "$PIM_CAMERA_CALL_LOG"; LSMOD_ROWS= LSMOD_RC=0 cam_unload_module "$PIM_CAMERA_RUNTIME_JSON" max9296
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail absent_unload
: > "$PIM_CAMERA_CALL_LOG"; LSMOD_RC=2 cam_unload_module "$PIM_CAMERA_RUNTIME_JSON" max9296 || r=$?; [ "${r:-0}" = 2 ] || fail detector
: > "$PIM_CAMERA_CALL_LOG"; LSMOD_ROWS='max9296 1 0' RMMOD_RC=7 cam_unload_module "$PIM_CAMERA_RUNTIME_JSON" max9296 || r=$?; [ "${r:-0}" = 7 ] || fail refusal
grep -q '^rmmod max9296' "$PIM_CAMERA_CALL_LOG" || fail refusal_not_called
echo 'recovery actions safety: PASS'
