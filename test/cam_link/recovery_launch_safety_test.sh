#!/usr/bin/env bash
# Fast launch/readiness boundary checks using only PATH/proc stubs.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib" PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUNTIME_JSON="$W/runtime.json" PIM_CAMERA_PROCESS_ROOT="$W/proc" PIM_CAMERA_CALL_LOG="$W/calls"
mkdir -p "$W/stub" "$W/proc"; export PATH="$W/stub:$PATH"
printf '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false}}}\n' > "$PIM_CAMERA_RUNTIME_JSON"
printf '#!/bin/sh\ncase "$*" in *gstApp*|*ord*|*vcm*) exit 1;; esac\nexit 2\n' > "$W/stub/pgrep"
printf '#!/bin/sh\nprintf "exec %s\\n" "$(basename "$0")" >> "$PIM_CAMERA_CALL_LOG"\n' > "$W/stub/ord"
cp "$W/stub/ord" "$W/stub/vcm"; chmod +x "$W/stub"/*
source "$PIM_LIB/cam_recovery_actions.sh"
cam_validate_runtime() { :; }; cam_executor_assert_context() { return "${GUARD_RC:-0}"; }
_cr_test_owner_rollover() { [ "${ROLLOVER_STAGE:-}" = "$1" ] && return 69 || return 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local n=$1; shift; set +e; "$@"; local r=$?; set -e; [ "$r" = "$n" ] || fail "$* rc=$r"; }

# Missing binaries fail synchronously and guard/rollover happen inside launch subshell.
PATH="$W/none" expect_rc 127 cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" ord
PATH="$W/none" expect_rc 127 cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" vcm
: > "$PIM_CAMERA_CALL_LOG"; ROLLOVER_STAGE=launch_ord cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" ord; wait || true
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail rollover_ord
: > "$PIM_CAMERA_CALL_LOG"; ROLLOVER_STAGE=launch_vcm cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" vcm; wait || true
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail rollover_vcm
GUARD_RC=69 expect_rc 69 cam_wait_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
echo 'recovery launch safety: PASS'
