#!/usr/bin/env bash
# _cr_jq_memo (issue #150): an identical jq call is served from memory, a changed
# input or argument runs jq again, and a failed or false run is never cached - a
# cached failure would pin a long-lived daemon's owner guard until the owner file
# changed.  jq runs are counted through a PATH shim.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-jq-memo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_CAMERA_RUN_DIR="$WORK/run" PIM_CAMERA_STATE_DIR="$WORK/state" PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
REAL_JQ=$(command -v jq)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/jq" <<SH
#!/bin/sh
printf 'jq\n' >> "$WORK/jq.log"
if [ -e "$WORK/fail-next" ]; then rm -f "$WORK/fail-next"; exit 5; fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$WORK/bin/jq"
export PATH="$WORK/bin:$PATH"
# shellcheck source=/dev/null
source "${JQ_MEMO_LIB:-$PIM_LIB/cam_recovery.sh}"
# shellcheck source=/dev/null
source "${JQ_MEMO_ACTIONS_LIB:-$PIM_LIB/cam_recovery_actions.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }
runs() { if [ -e "$WORK/jq.log" ]; then wc -l < "$WORK/jq.log"; else echo 0; fi; }
expect_runs() { [ "$(runs)" -eq "$1" ] || fail "$2 (jq ran $(runs) times, expected $1)"; }

active='{"lifecycle":"ACTIVE"}'
_cr_jq_memo out "$active" -r .lifecycle
[ "$out" = ACTIVE ] || fail "first call returned '$out'"
expect_runs 1 'first call did not run jq'
_cr_jq_memo out "$active" -r .lifecycle
[ "$out" = ACTIVE ] || fail "memo returned '$out'"
expect_runs 1 'an identical call ran jq again'

_cr_jq_memo out '{"lifecycle":"STOPPING"}' -r .lifecycle
[ "$out" = STOPPING ] || fail "changed input returned '$out'"
expect_runs 2 'a changed input was served from memory'
_cr_jq_memo out "$active" -c .
[ "$out" = "$active" ] || fail "changed argument returned '$out'"
expect_runs 3 'a changed argument was served from memory'

degraded='{"lifecycle":"DEGRADED"}'
touch "$WORK/fail-next"
rc=0; _cr_jq_memo out "$degraded" -r .lifecycle || rc=$?
[ "$rc" -eq 5 ] || fail "a failing jq returned rc $rc, expected 5"
expect_runs 4 'the failing call did not run jq'
_cr_jq_memo out "$degraded" -r .lifecycle
[ "$out" = DEGRADED ] || fail "retry after a failure returned '$out'"
expect_runs 5 'a failed run was cached'

for _ in 1 2; do rc=0; _cr_jq_memo out "$active" -e .missing || rc=$?; [ "$rc" -eq 1 ] || fail "jq -e on null returned rc $rc"; done
expect_runs 7 'a false (rc 1) result was cached'

_cr_jq_memo out '{"a":1,"b":2}' -r '.a,.b'
[ "$out" = $'1\n2' ] || fail "multi-line output was altered: '$out'"

# _cam_runtime_app_into: the app name is read once per runtime file identity.  The
# hot callers name their variable "app", so a helper local of the same name would
# swallow the assignment - the caller must still see the value.
runtime="$WORK/runtime.json"
printf '%s\n' '{"VHL_CAM":{"app":"gstApp"}}' > "$runtime"
: > "$WORK/jq.log"
probe_caller() { local app=unset; _cam_runtime_app_into app "$runtime" || return $?; printf '%s' "$app"; }
[ "$(probe_caller)" = gstApp ] || fail "caller variable 'app' did not receive the runtime app"
expect_runs 1 'runtime app first read did not run jq'
_cam_runtime_app_into app "$runtime"; _cam_runtime_app_into app "$runtime"
[ "$app" = gstApp ] || fail "cached runtime app returned '$app'"
expect_runs 2 'runtime app was re-read for an unchanged file'
printf '%s\n' '{"VHL_CAM":{"app":"streamApp"}}' > "$runtime.next" && mv -f "$runtime.next" "$runtime"
_cam_runtime_app_into app "$runtime"
[ "$app" = PIMCAM ] || fail "a replaced runtime file returned the stale app '$app'"
expect_runs 3 'a replaced runtime file was served from the cache'

echo "jq memo: PASS"
