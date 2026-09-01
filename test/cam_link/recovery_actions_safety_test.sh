#!/usr/bin/env bash
# Fast safety matrix for recovery actions; all external effects are stubs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/pim-safety.XXXXXX")
trap 'rm -rf "$W"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib" PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_PROCESS_ROOT="$W/proc" PIM_CAMERA_RUNTIME_JSON="$W/runtime.json"
export PIM_CAMERA_SESSION_TIME_FILE="$W/marker" PIM_CAMERA_CALL_LOG="$W/calls"
export PIM_CAMERA_PGREP_STATE_DIR="$W/pgrep-state"
mkdir -p "$W/stub" "$W/recordings" "$PIM_CAMERA_PROCESS_ROOT" "$PIM_CAMERA_PGREP_STATE_DIR"
export PATH="$W/stub:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local n=$1; shift; set +e; "$@"; local r=$?; set -e; [ "$r" = "$n" ] || fail "wanted $n got $r: $*"; }
runtime() { printf '{"VHL_CAM":{"tmp_path":"%s","vhl_name":"VD3001"}}\n' "$1" > "$PIM_CAMERA_RUNTIME_JSON"; }
statfile() { local p=$1 s=$2; { printf '%s (BG Check) S' "$p"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0\n' "$s"; } > "$PIM_CAMERA_PROCESS_ROOT/$p/stat"; }
bg() {
  local p=$1 s=$2 mode=${3:-shebang}
  mkdir -p "$PIM_CAMERA_PROCESS_ROOT/$p"; statfile "$p" "$s"
  case "$mode" in
    direct) printf '%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$p/cmdline" ;;
    shebang) printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$p/cmdline" ;;
    trailing) printf '/bin/bash\000%s\0004\000extra\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$p/cmdline" ;;
    false) printf '/bin/bash\000other\0004\000%s\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$p/cmdline" ;;
  esac
}
printf '#!/bin/sh\nlast=\nfor arg; do last=$arg; done\nfile="$PIM_CAMERA_PGREP_STATE_DIR/$last"\ncount=$(cat "$file" 2>/dev/null || printf 0)\ncount=$((count + 1))\nprintf "%%s\\n" "$count" > "$file"\nprintf "pgrep %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ncase "${PIM_CAMERA_PGREP_MODE:-absent}" in\n  after_signal_absent) [ "$count" -eq 1 ] && exit 0 || exit 1 ;;\n  still_present) exit 0 ;;\n  probe_error) [ "$count" -eq 1 ] && exit 0 || exit "${PIM_CAMERA_PGREP_ERROR_RC:-8}" ;;\n  *) exit 1 ;;\nesac\n' > "$W/stub/pgrep"
printf '#!/bin/sh\nprintf "pkill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\nexit "${PKILL_RC:-0}"\n' > "$W/stub/pkill"
printf '#!/bin/sh\nprintf "kill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\nif [ "${ROLLOVER_ON_TERM:-0}" = 1 ] && [ "$1" = -TERM ]; then\n  { printf "%%s (BG Check) S" "$2"; i=0; while [ "$i" -lt 18 ]; do printf " 0"; i=$((i + 1)); done; printf " 9999 0\\n"; } > "$PIM_CAMERA_PROCESS_ROOT/$2/stat"\n  printf "%%s\\0004\\000" "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/$2/cmdline"\nelif [ "${IMMORTAL:-0}" != 1 ]; then\n  rm -f "$PIM_CAMERA_PROCESS_ROOT/$2/cmdline"\nfi\n' > "$W/stub/kill"
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
rm -f "$W/marker"
ln -s "$W/recordings" "$W/link"
for bad in / relative ../x "$W/link"; do runtime "$bad"; expect_rc 64 cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"; done
[ -e "$W/recordings/VD3001_20260901_1234-missing.mp4" ] || fail symlink_target
runtime "$W/recordings"
cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"
[ -e "$W/recordings/VD3001_20260901_1234-missing.mp4" ] || fail canonical_missing_marker_delete

# Direct/shebang exact BG layouts pass under pipefail; trailing argv is rejected.
bg 101 1001 shebang; bg 102 1002 direct; bg 103 1003 trailing
records=$(cam_bg_checker_records "$PIM_CAMERA_BG_CHECKER")
[ "$(printf '%s\n' "$records" | wc -l)" -eq 2 ] || fail multi_bg
! printf '%s\n' "$records" | grep -q 103 || fail trailing_argv
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

# TERM rollover changes both the start time and exact argv layout before KILL.
# The reused PID receives no KILL, remains visible to the final barrier, and
# blocks every later direct/module side effect.
cam_cleanup_recording_orphans() { printf 'cleanup\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_cleanup_shm_overflow() { printf 'shm\n' >> "$PIM_CAMERA_CALL_LOG"; }
cam_start_gstapp() { printf 'start\n' >> "$PIM_CAMERA_CALL_LOG"; }
for action in direct module; do
  rm -rf "$PIM_CAMERA_PROCESS_ROOT"/*
  bg 107 1007 shebang
  : > "$PIM_CAMERA_CALL_LOG"
  case "$action" in
    direct) ROLLOVER_ON_TERM=1 PIM_CAMERA_QUIESCE_TIMEOUT_SEC=0 expect_rc 1 cam_action_gstapp_restart "$PIM_CAMERA_RUNTIME_JSON" ;;
    module) ROLLOVER_ON_TERM=1 PIM_CAMERA_QUIESCE_TIMEOUT_SEC=0 expect_rc 1 cam_action_module_reload "$PIM_CAMERA_RUNTIME_JSON" ;;
  esac
  grep -q '^kill -TERM 107$' "$PIM_CAMERA_CALL_LOG" || fail "$action rollover TERM missing"
  ! grep -q '^kill -KILL 107$' "$PIM_CAMERA_CALL_LOG" || fail "$action reused PID received KILL"
  ! grep -Eq 'cleanup|shm|rmmod|modprobe|sysfs|start' "$PIM_CAMERA_CALL_LOG" || fail "$action rollover allowed later effect"
done
rm -rf "$PIM_CAMERA_PROCESS_ROOT"/*

# Module absent, detector error, and real unload refusal are distinct.
: > "$PIM_CAMERA_CALL_LOG"; LSMOD_ROWS= LSMOD_RC=0 cam_unload_module "$PIM_CAMERA_RUNTIME_JSON" max9296
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail absent_unload
: > "$PIM_CAMERA_CALL_LOG"; LSMOD_RC=2 cam_unload_module "$PIM_CAMERA_RUNTIME_JSON" max9296 || r=$?; [ "${r:-0}" = 2 ] || fail detector
: > "$PIM_CAMERA_CALL_LOG"; LSMOD_ROWS='max9296 1 0' RMMOD_RC=7 cam_unload_module "$PIM_CAMERA_RUNTIME_JSON" max9296 || r=$?; [ "${r:-0}" = 7 ] || fail refusal
grep -q '^rmmod max9296' "$PIM_CAMERA_CALL_LOG" || fail refusal_not_called

# An initial exact app/ORD/VCM match followed by pkill rc=1 is ambiguous.
# Re-probe decides success/continued presence/error; owner errors are terminal.
export PKILL_RC=1
for kind in app ord vcm; do
  target=$kind; [ "$kind" != app ] || target=gstApp

  rm -f "$PIM_CAMERA_PGREP_STATE_DIR"/*; : > "$PIM_CAMERA_CALL_LOG"
  PIM_CAMERA_PGREP_MODE=after_signal_absent expect_rc 0 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" "$kind"
  grep -q "^pkill -TERM -x $target$" "$PIM_CAMERA_CALL_LOG" || fail "$kind exact TERM missing"
  [ "$(cat "$PIM_CAMERA_PGREP_STATE_DIR/$target")" -ge 2 ] || fail "$kind disappearance was not re-probed"

  rm -f "$PIM_CAMERA_PGREP_STATE_DIR"/*; : > "$PIM_CAMERA_CALL_LOG"
  PIM_CAMERA_PGREP_MODE=still_present expect_rc 1 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" "$kind"
  [ "$(cat "$PIM_CAMERA_PGREP_STATE_DIR/$target")" -eq 2 ] || fail "$kind still-present rc1 was not confirmed"

  rm -f "$PIM_CAMERA_PGREP_STATE_DIR"/*; : > "$PIM_CAMERA_CALL_LOG"
  PIM_CAMERA_PGREP_MODE=probe_error PIM_CAMERA_PGREP_ERROR_RC=8 expect_rc 8 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" "$kind"
  [ "$(cat "$PIM_CAMERA_PGREP_STATE_DIR/$target")" -eq 2 ] || fail "$kind probe error was not returned immediately"
done

rm -f "$PIM_CAMERA_PGREP_STATE_DIR"/*; : > "$PIM_CAMERA_CALL_LOG"
cam_executor_assert_context() { return 69; }
PIM_CAMERA_PGREP_MODE=after_signal_absent expect_rc 69 cam_stop_process "$PIM_CAMERA_RUNTIME_JSON" app
[ "$(cat "$PIM_CAMERA_PGREP_STATE_DIR/gstApp")" -eq 1 ] || fail "owner error was reinterpreted by another probe"
cam_executor_assert_context() { :; }
unset PKILL_RC
echo 'recovery actions safety: PASS'
