#!/usr/bin/env bash
# The rc of each locked request operation when exactly one JSON document it
# reads fails to parse, and which files the call changes - pinned as the code
# behaves today, before the issue #150 redesign.  Today the rc depends on the
# site: a corrupt active record is refused by the owner check (69), any other
# corrupt document by the operation's own validation (70).
#
# Approved change (2): the redesign may unify the rc per operation, except for
# rows already pinned elsewhere, which keep their values:
#   transition/history 70, active written first  request_semantics_test.sh
#   finish/result      70, nothing written       request_semantics_test.sh
#   counter_begin/state 70 (for a schema-invalid state.json)  recovery_protocol_test.sh
# Every other row may change, but only together with the row here.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-request-parse-rc.XXXXXX")
label=setup
on_exit() { local rc=$?; rm -rf "$WORK"; [ "$rc" -eq 0 ] || echo "FAIL: $label: exited rc=$rc" >&2; }
trap on_exit EXIT
export PIM_CAMERA_RUN_DIR="$WORK/run/pim-camera"
export PIM_CAMERA_STATE_DIR="$WORK/var/lib/pim-camera"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot_id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
DAEMON_PID=4242
# REQUEST_PARSE_RC_LIB swaps the library under test (mutation controls).
# shellcheck source=/dev/null
source "${REQUEST_PARSE_RC_LIB:-$PIM_LIB/cam_recovery.sh}"
printf '1700000000\n' > "$WORK/clock"
_cr_now() { local now; now=$(( $(cat "$WORK/clock") + 1 )); printf '%s\n' "$now" > "$WORK/clock"; printf '%s\n' "$now"; }

fail() { echo "FAIL: $label: $*" >&2; exit 1; }
expect_rc() { local expected=$1 actual; shift; set +e +o pipefail; "$@"; actual=$?; set -e -o pipefail; [ "$actual" -eq "$expected" ] || fail "expected rc=$expected, got $actual: $*"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$1"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
fingerprint() { if [ -e "$1" ]; then cksum < "$1"; else echo ABSENT; fi; }
input_file() {
    case $1 in
        pending) printf '%s/recovery/pending.json' "$PIM_CAMERA_RUN_DIR";;
        active) printf '%s/recovery/active.json' "$PIM_CAMERA_RUN_DIR";;
        history) printf '%s/recovery/history/%s.json' "$PIM_CAMERA_STATE_DIR" "$id";;
        result) printf '%s/recovery/results/%s.json' "$PIM_CAMERA_RUN_DIR" "$id";;
        state) printf '%s/recovery/state.json' "$PIM_CAMERA_STATE_DIR";;
    esac
}
FILES=(pending active history result state)

# A counted gstapp_restart brought to the point where OP normally runs, on a
# board whose state.json already exists; sets id.  The request runs in the order
# cam_execute_action_step uses: counter begin and finish while RUNNING.
to_point() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT"
    printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    fake_stat 111
    cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE; _cr_state_init
    id=$(cam_request_submit gstapp_restart operator "parse rc")
    [ "$1" != claim ] || return 0
    cam_request_claim
    [ "$1" != transition ] || return 0
    cam_request_transition QUIESCING; cam_request_transition RUNNING
    [ "$1" != counter_begin ] || return 0
    cam_action_counter_begin gstapp_restart "$id"
    [ "$1" != counter_finish ] || return 0
    cam_action_counter_finish gstapp_restart "$id" SUCCEEDED 0
    cam_request_transition VERIFYING
}
# jq's parse error is expected here; only the operation's stderr is dropped.
call_op() {
    case $1 in
        claim) cam_request_claim;;
        transition) cam_request_transition QUIESCING;;
        counter_begin) cam_action_counter_begin gstapp_restart "$id";;
        counter_finish) cam_action_counter_finish gstapp_restart "$id" SUCCEEDED 0;;
        finish) cam_request_finish SUCCEEDED 0;;
    esac 2>/dev/null
}

# operation       corrupt input  rc   files the call changes (- for none)
ROWS=(
    'claim           pending        70   -'
    'transition      active         69   -'
    'transition      history        70   active'
    'counter_begin   active         69   -'
    'counter_begin   state          70   -'
    'counter_begin   history        70   -'
    'counter_finish  active         69   -'
    'counter_finish  state          70   -'
    'counter_finish  history        70   -'
    'finish          active         69   -'
    'finish          history        70   -'
    'finish          result         70   -'
    'finish          state          70   -'
)

for row in "${ROWS[@]}"; do
    read -r op input rc changes <<<"$row"
    label="$op with a corrupt $input"
    to_point "$op"
    # A result exists only after a finish that crashed once it was written.
    if [ "$input" = result ]; then PIM_CAMERA_TEST_FAILPOINT=request_finish_after_result expect_rc 70 cam_request_finish SUCCEEDED 0; fi
    [ -e "$(input_file "$input")" ] || fail "precondition: $input does not exist"
    printf '{broken\n' > "$(input_file "$input")"
    declare -A before=()
    for f in "${FILES[@]}"; do before[$f]=$(fingerprint "$(input_file "$f")"); done
    expect_rc "$rc" call_op "$op"
    changed=()
    for f in "${FILES[@]}"; do
        [ "${before[$f]}" = "$(fingerprint "$(input_file "$f")")" ] || changed+=("$f")
    done
    [ "${#changed[@]}" -gt 0 ] || changed=(-)
    [ "$(IFS=,; echo "${changed[*]}")" = "$changes" ] || fail "changed: $(IFS=,; echo "${changed[*]}"), expected: $changes"
done

echo "request parse rc: PASS"
