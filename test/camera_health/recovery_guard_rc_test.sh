#!/bin/bash
# Exit codes of the recovery ownership guards, accept and reject alike.
#
# recovery_protocol_test.sh already covers the immutable-field arm of
# _cr_record_owner_ready: break the six-field comparison and it fails with
# "expected rc=69, got 0: rollover snapshot race".  It does not cover the
# lifecycle arm - break that and the whole camera_health suite still passes.
# This file closes that gap and pins the reject codes of both guards, because
# folding their jq invocations together is only safe if every rejection still
# yields the code the caller branches on (69 here, 1 for the schema guard).
set -eu

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-guard-rc.XXXXXX")
LIVE=""
cleanup() { [ -z "$LIVE" ] || kill "$LIVE" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

export PIM_CAMERA_RUN_DIR="$WORK/run" PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_RUNTIME_JSON="$WORK/run/config/pim_runtime.json"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot_id"
mkdir -p "$WORK/run/config" "$WORK/run/recovery" "$WORK/state"
printf 'boot-id-for-guard-rc-test\n' > "$PIM_CAMERA_BOOT_ID_FILE"

# shellcheck source=/dev/null
. "$ROOT/dist/pim/opt/pim/lib/cam_recovery.sh"

pass=0; fail=0
check() { # check <expected-rc> <label> <cmd...>
    local want=$1 label=$2 got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then
        printf '  OK   %s\n' "$label"; pass=$((pass + 1))
    else
        printf '  FAIL %s: expected rc=%s, got %s\n' "$label" "$want" "$got" >&2; fail=$((fail + 1))
    fi
}

sleep 600 & LIVE=$!
cam_owner_create "$LIVE" >/dev/null
cam_owner_set_lifecycle ACTIVE >/dev/null
OWNER=$(cat "$WORK/run/owner.json")
cam_request_submit gstapp_restart guard-rc-test guard-rc-test >/dev/null
RECORD=$(cat "$WORK/run/recovery/pending.json")

rec() { jq -c "$1" <<<"$RECORD"; }
own() { jq -c "$1" <<<"$OWNER" > "$WORK/run/owner.json"; }
restore_owner() { printf '%s\n' "$OWNER" > "$WORK/run/owner.json"; }

echo "=== _cr_record_owner_ready ==="
check 0  "accepts a live owner in an allowed lifecycle"  _cr_record_owner_ready "$RECORD" ACTIVE
check 0  "accepts when the lifecycle is one of several"  _cr_record_owner_ready "$RECORD" DEGRADED ACTIVE
# The arm recovery_protocol_test.sh cannot see.
check 69 "rejects a lifecycle outside the allowed set"   _cr_record_owner_ready "$RECORD" DEGRADED
check 69 "rejects when no lifecycle is allowed at all"   _cr_record_owner_ready "$RECORD"
own '.lifecycle="STOPPING"'
check 69 "rejects a STOPPING owner for an ACTIVE guard"  _cr_record_owner_ready "$RECORD" ACTIVE
restore_owner
# The arm that is already covered, pinned here too so both live together.
check 69 "rejects a rolled token"        _cr_record_owner_ready "$(rec '.owner.token="rolled"')" ACTIVE
check 69 "rejects a rolled pid"          _cr_record_owner_ready "$(rec '.owner.pid=1')" ACTIVE
check 69 "rejects a rolled created_at"   _cr_record_owner_ready "$(rec '.owner.created_at=1')" ACTIVE
check 69 "rejects a rolled boot_id"      _cr_record_owner_ready "$(rec '.owner.boot_id="rolled"')" ACTIVE
check 69 "rejects a rolled invocation"   _cr_record_owner_ready "$(rec '.owner.invocation_id="rolled"')" ACTIVE
check 69 "rejects a record without an owner object" _cr_record_owner_ready "$(rec '.owner={}')" ACTIVE
check 69 "rejects a record that is not an object"   _cr_record_owner_ready '"not-a-record"' ACTIVE
own '.token=123'
check 69 "rejects an owner failing its own schema"  _cr_record_owner_ready "$RECORD" ACTIVE
restore_owner
own '.boot_id="a-different-boot"'
check 69 "rejects an owner from another boot"       _cr_record_owner_ready "$RECORD" ACTIVE
restore_owner
own '.pid=999999'
check 69 "rejects an owner whose pid is not alive"  _cr_record_owner_ready "$RECORD" ACTIVE
restore_owner
# Both documents name the same dead pid, so they agree on all six immutable
# fields and only the /proc start-time comparison can reject.  The case above
# changes the owner alone, which the comparison rejects before liveness is
# consulted; without this one the liveness arm can be deleted and every other
# assertion here, and recovery_protocol_test.sh, still passes.
own '.pid=999999'
check 69 "rejects a record and owner agreeing on a dead pid" \
    _cr_record_owner_ready "$(rec '.owner.pid=999999')" ACTIVE
restore_owner
# The record's embedded owner fails its own schema on a field the six-field
# comparison does not look at - lifecycle is not one of the six - so the record
# and the live owner still agree, the live owner is valid, and the lifecycle
# membership check reads the live owner's ACTIVE rather than this value.  Only
# the schema applied to the record's owner can reject.  Without this case that
# clause can be deleted with every other assertion here still green.
check 69 "rejects a record whose own owner snapshot fails the schema" \
    _cr_record_owner_ready "$(rec '.owner.lifecycle="NOT_A_LIFECYCLE"')" ACTIVE
# Both documents agree on a proc_start_time that is not the live pid's actual
# start time.  The six-field comparison passes because they agree, the pid is
# alive so the non-empty check passes, and only the equality against /proc can
# reject.  That equality is the guard's only pid-reuse detector - a different
# process holding the owner's old pid - and deleting it alone leaves every
# other assertion here green.
own '.proc_start_time="1"'
check 69 "rejects a record and owner agreeing on a wrong proc start time" \
    _cr_record_owner_ready "$(rec '.owner.proc_start_time="1"')" ACTIVE
restore_owner
# Reaching the schema check on the *live* owner alone needs the allowed set to
# contain a value the schema itself rejects.  The sanitizer below only limits the
# character class, not the six enum names, so an out-of-enum [A-Z_] value passes
# through: the live owner carries it, membership therefore matches, the record's
# own owner is a normal enum value so its schema passes, and the six immutable
# fields still agree.  Only the live owner's schema can reject.  An earlier
# version of this commit argued that clause was unreachable alone; it is not.
own '.lifecycle="BOGUS_STATE"'
check 69 "rejects a live owner whose lifecycle is outside the enum" \
    _cr_record_owner_ready "$(rec '.owner.lifecycle="ACTIVE"')" BOGUS_STATE
restore_owner
# The sanitizer that keeps caller values out of the hand-built JSON array is the
# only thing between a lifecycle argument and the --argjson payload.  Deleting it
# leaves every other assertion here green, so it gets its own case: a value with
# a quote or a bracket must be dropped, giving an ordinary 69, never a jq failure.
# rc alone cannot see the sanitizer: a junk value that reaches --argjson makes the
# array malformed, jq fails, and the guard returns 69 - the same code a dropped
# value produces.  Pairing junk with a value that should match separates them.
# Sanitized, ACTIVE survives and the guard accepts; unsanitized, the array is
# broken and nothing is accepted.
check 0 "drops a quote and still honours a valid lifecycle"   _cr_record_owner_ready "$RECORD" 'AC"TIVE' ACTIVE
check 0 "drops a bracket and still honours a valid lifecycle" _cr_record_owner_ready "$RECORD" 'ACTIVE]' ACTIVE
check 0 "drops a backslash and still honours a valid one"     _cr_record_owner_ready "$RECORD" 'ACT\\IVE' ACTIVE
# And a junk value on its own is an ordinary rejection, with nothing from jq on
# stderr; a value that escaped into the filter would show a jq diagnostic instead.
sanitizer_err=$(_cr_record_owner_ready "$RECORD" 'AC"TIVE' 2>&1 >/dev/null || true)
if [ -z "$sanitizer_err" ]; then
    printf '  OK   %s\n' "a dropped lifecycle value produces no jq diagnostic"; pass=$((pass + 1))
else
    printf '  FAIL %s: stderr was [%s]\n' "a dropped lifecycle value produces no jq diagnostic" "$sanitizer_err" >&2; fail=$((fail + 1))
fi
# A guard that folds its checks into one jq must still see one document. Read as
# a stream the filter runs per document and accepts if any matches, so a stale
# ACTIVE copy beside the current STOPPING one would certify a lifecycle the
# owner file no longer holds.
{ jq -c '.lifecycle="STOPPING"' <<<"$OWNER"; jq -c '.lifecycle="ACTIVE"' <<<"$OWNER"; } > "$WORK/run/owner.json"
check 69 "rejects an owner file holding two documents"  _cr_record_owner_ready "$RECORD" ACTIVE
{ jq -c '.lifecycle="ACTIVE"' <<<"$OWNER"; jq -c '.lifecycle="STOPPING"' <<<"$OWNER"; } > "$WORK/run/owner.json"
check 69 "rejects two documents in the other order"     _cr_record_owner_ready "$RECORD" ACTIVE
restore_owner
# The record and the live owner agree with each other but name a boot that is
# no longer running, which is what survives a reboot with the run directory
# intact.  The six-field comparison cannot see this because the two documents
# match; only the check against the boot id file can.  Without this case the
# boot check can be deleted and every other assertion here still passes.
own '.boot_id="stale-boot-from-a-previous-run"'
check 69 "rejects a record and owner agreeing on a stale boot" \
    _cr_record_owner_ready "$(rec '.owner.boot_id="stale-boot-from-a-previous-run"')" ACTIVE
restore_owner

echo "=== _cr_request_schema ==="
check 0 "accepts the submitted request"             _cr_request_schema "$RECORD"
check 0 "accepts an optional source_path"           _cr_request_schema "$(rec '.source_path="/x"')"
check 1 "rejects a malformed id"                    _cr_request_schema "$(rec '.id="not-a-uuid"')"
check 1 "rejects an action outside the allowed set" _cr_request_schema "$(rec '.type="evil_action"')"
check 1 "rejects an empty source"                   _cr_request_schema "$(rec '.source=""')"
check 1 "rejects an empty reason"                   _cr_request_schema "$(rec '.reason=""')"
check 1 "rejects created_at of zero"                _cr_request_schema "$(rec '.created_at=0')"
check 1 "rejects an owner failing its own schema"   _cr_request_schema "$(rec '.owner={}')"
check 1 "rejects a negative source_mtime"           _cr_request_schema "$(rec '.source_mtime=-1')"
check 1 "rejects a request that is not an object"   _cr_request_schema '"not-a-request"'
check 1 "rejects a request stream even when one document validates" \
    _cr_request_schema "$(printf '%s\n{"x":1}\n' "$RECORD")"

echo "=== cam_executor_set_context ==="
# This is the only function whose exit-code contract this change altered, and its
# codes are branched on: cam_operate_control.sh feeds the value into
# _coc_fail_active and thence to cam_request_finish FAILED, and three more sites
# propagate it with return $?.  Before the change all four cases below returned 0.
# shellcheck source=/dev/null
. "$ROOT/dist/pim/opt/pim/lib/cam_recovery_actions.sh" 2>/dev/null || true
printf '%s\n' "$RECORD" > "$WORK/run/recovery/active.json"
check 0  "accepts a healthy owner and active document"  cam_executor_set_context
own '.token=123'
check 70 "rejects an owner failing its own schema with 70" cam_executor_set_context
restore_owner
printf 'not json at all\n' > "$WORK/run/recovery/active.json"
check 69 "rejects an unparsable active document with 69"  cam_executor_set_context
printf '42\n' > "$WORK/run/recovery/active.json"
check 69 "rejects a non-object active document with 69"   cam_executor_set_context
printf '%s\n' "$RECORD" > "$WORK/run/recovery/active.json"

printf '\nrecovery guard exit codes: %s passed / %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
