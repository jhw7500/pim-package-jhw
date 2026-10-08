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

# cam_executor_assert_context runs before every side effect (camera_hard_reset
# calls it 27 times) and the active record does not change in between.  Once
# warm, repeating it must not spawn jq: the executor snapshot is cached by owner
# file identity, the owner guard by _cr_jq_memo, and the active id by
# _cr_jq_memo too.  Only the extraction is memoized, never the comparison, so a
# different request id is still refused.
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
mkdir -p "$PIM_CAMERA_PROC_ROOT/4242"
{ printf '%s' '4242 (cam operate) S'; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/4242/stat"
printf 'memo-boot\n' > "$PIM_CAMERA_BOOT_ID_FILE"
cam_owner_create 4242; cam_owner_set_lifecycle ACTIVE
cam_request_submit gstapp_restart operator 'executor memo' >/dev/null
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING
cam_owner_set_lifecycle RECOVERING
cam_executor_set_context
cam_executor_assert_context || fail "the executor context was refused before warming"
: > "$WORK/jq.log"
for _ in 1 2 3 4 5; do cam_executor_assert_context || fail "the warm executor context was refused"; done
expect_runs 0 'a repeated executor check against an unchanged active record spawned jq'
rc=0; PIM_CAMERA_REQUEST_ID=00000000-0000-4000-8000-000000000000 cam_executor_assert_context || rc=$?
[ "$rc" -eq 69 ] || fail "a warm executor check accepted another request id (rc $rc)"

# _cr_record_owner_ready reads only .owner from the record, so its memo is keyed
# on that and not on the whole record (issue #150 (a)): a record that differs
# only in status, whose .owner _cr_record_owner_matches already extracted, is
# judged without another jq - and the lifecycle set is still compared per call.
record=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json")
next=$(jq -c '.status="VERIFYING" | .updated_at += 1' <<<"$record")
_cr_record_owner_matches "$record" || fail "the owner check refused the active record"
_cr_record_owner_ready "$record" RECOVERING || fail "the owner guard refused the active record"
: > "$WORK/jq.log"
_cr_record_owner_matches "$next" || fail "the owner check refused the next record"
_cr_record_owner_ready "$next" RECOVERING APPLYING_CONFIG || fail "the owner guard refused the next record"
expect_runs 1 'the owner guard re-ran jq for a record whose owner it had already judged'
rc=0; _cr_record_owner_ready "$next" ACTIVE || rc=$?
[ "$rc" -eq 69 ] || fail "a verdict for one lifecycle set was reused for another (rc $rc)"
expect_runs 1 'comparing another lifecycle set spawned jq'
# The /proc start time is read on every call and never memoized: with every memo
# warm, a restarted owner process is still refused, and noticing it needs no jq.
{ printf '%s' '4242 (cam operate) S'; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 222 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/4242/stat"
rc=0; _cr_record_owner_ready "$next" RECOVERING || rc=$?
[ "$rc" -eq 69 ] || fail "a changed /proc start time was not noticed while warm (rc $rc)"
expect_runs 1 'noticing a changed /proc start time spawned jq'

# A transition writes the next active record from one jq and puts that jq's
# answers for the record's .id and .owner into the memo, so the guards and the
# next operation find them without a jq of their own.  A put value must be the
# exact bytes the jq call would print - check it against real jq.
{ printf '%s' '4242 (cam operate) S'; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/4242/stat"
cam_request_transition VERIFYING || fail "the transition to VERIFYING was refused"
record=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json")
want_owner=$(jq -c .owner <<<"$record"); want_id=$(jq -r .id <<<"$record")
got_owner=; got_id=
: > "$WORK/jq.log"
_cr_jq_memo got_owner "$record" -c .owner; _cr_jq_memo got_id "$record" -r .id
expect_runs 0 'the transition did not leave .owner and .id of the record it wrote in the memo'
[ "$got_owner" = "$want_owner" ] || fail "the memo holds another .owner than jq prints: '$got_owner' vs '$want_owner'"
[ "$got_id" = "$want_id" ] || fail "the memo holds another .id than jq prints: '$got_id' vs '$want_id'"

# The put values are taken from the written text parsed back, because the next
# operation's jq -c .owner reads the file.  jq 1.7 prints a number it parsed from
# text in its own form (1.7976931348623157E+308) and one it computed
# (Infinity) as 1.7976931348623157e+308, so values derived from the record in
# memory would differ from what jq prints for the file.  jq 1.6 prints both
# alike, so this only fails on 1.7 if the derivation regresses.
sed 's/"owner":{/"owner":{"x":Infinity,/' "$PIM_CAMERA_RUN_DIR/recovery/active.json" > "$WORK/active.next"
mv "$WORK/active.next" "$PIM_CAMERA_RUN_DIR/recovery/active.json"
cam_request_transition SUCCEEDED || fail "the transition to SUCCEEDED was refused"
record=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json"); got_owner=
_cr_jq_memo got_owner "$record" -c .owner
[ "$got_owner" = "$(jq -c .owner <<<"$record")" ] || fail "the memo holds another .owner than jq prints for the written record: '$got_owner'"

echo "jq memo: PASS"
