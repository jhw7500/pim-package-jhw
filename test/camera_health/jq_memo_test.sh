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
want_owner=$(jq -c .owner <<<"$record"); want_id=$(jq -r .id <<<"$record"); want_status=$(jq -r .status <<<"$record")
got_owner=; got_id=; got_status=
: > "$WORK/jq.log"
_cr_jq_memo got_owner "$record" -c .owner; _cr_jq_memo got_id "$record" -r .id; _cr_jq_memo got_status "$record" -r .status
expect_runs 0 'the transition did not leave .owner, .id and .status of the record it wrote in the memo'
[ "$got_owner" = "$want_owner" ] || fail "the memo holds another .owner than jq prints: '$got_owner' vs '$want_owner'"
[ "$got_id" = "$want_id" ] || fail "the memo holds another .id than jq prints: '$got_id' vs '$want_id'"
[ "$got_status" = "$want_status" ] || fail "the memo holds another .status than jq prints: '$got_status' vs '$want_status'"

# _cr_request_schema answers from the memo, and leaves the request's .type there:
# what it prints is .type as jq -r prints it for the one document it accepted,
# so poll and execution read the type without a jq of their own.
got_type=
: > "$WORK/jq.log"
_cr_request_schema "$record" || fail "the schema check refused the active record"
_cr_request_schema "$record" || fail "the repeated schema check refused the active record"
_cr_jq_memo got_type "$record" -r .type
expect_runs 1 'a repeated schema check or the .type lookup ran jq again'
[ "$got_type" = "$(jq -r .type <<<"$record")" ] || fail "the memo holds another .type than jq prints: '$got_type'"
# The old check read the type through \$(...), which drops a trailing newline, so
# such a type passes; the memo then holds the type as jq -r prints it, stripped.
newline_type=$(jq -c '.type="gstapp_restart\n"' <<<"$record")
_cr_request_schema "$newline_type" || fail "the schema check refused a type that ends in a newline"
_cr_jq_memo got_type "$newline_type" -r .type
[ "$got_type" = "$(jq -r .type <<<"$newline_type")" ] || fail "the memo holds another .type than jq prints for a type ending in a newline"
# A refused request leaves nothing behind: two documents are not one.
two=$(printf '%s\n%s' "$record" "$record")
rc=0; _cr_request_schema "$two" || rc=$?
[ "$rc" -eq 1 ] || fail "the schema check accepted two documents (rc $rc)"
: > "$WORK/jq.log"
_cr_jq_memo got_type "$two" -r .type
expect_runs 1 'a refused request left .type in the memo'

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

# claim 은 pending 을 읽는 jq 에서, poll 이 같은 텍스트로 띄우던 요청 스키마 검사와 jq -r .reason
# 의 답도 내어 메모에 미리 넣는다 (이슈 #150): poll 이 읽는 active 는 claim 이 옮긴 같은 바이트다.
# 미리 넣은 값은 실제 jq 출력과 같아야 한다. 개행이 든 reason 은 넣지 않으므로 jq 가 다시 돈다.
claim_fresh() {
    rm -f "$PIM_CAMERA_RUN_DIR/recovery/active.json"
    cam_request_submit gstapp_restart operator "$1" >/dev/null || fail "the submit for '$1' was refused"
    if [ -n "${2:-}" ]; then
        jq -c "$2" "$PIM_CAMERA_RUN_DIR/recovery/pending.json" > "$WORK/pending.next"
        mv "$WORK/pending.next" "$PIM_CAMERA_RUN_DIR/recovery/pending.json"
    fi
    cam_request_claim || fail "the claim for '$1' was refused"
    [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "the claim for '$1' left the pending request"
    record=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json")
}
# _cr_request_schema 의 프로그램을 필터 변수로 직접 만든다 — 라이브러리가 다른 문자열로 미리
# 넣으면 키가 달라 아래 적중 검사가 실패한다.
schema_program="if (length == 1) then .[0] | if (($_CR_REQUEST_SCHEMA_FILTER)) and (.owner | ($_CR_OWNER_SCHEMA_FILTER)) then .type else empty end else empty end"
cam_owner_set_lifecycle ACTIVE
claim_fresh '재시작 요청'
want_schema=$(jq -r -s "$schema_program" <<<"$record"); want_type=$(jq -r .type <<<"$record"); want_reason=$(jq -r .reason <<<"$record")
got_schema=; got_type=; got_reason=
: > "$WORK/jq.log"
_cr_request_schema "$record" || fail "the schema check refused the claimed record"
_cr_jq_memo got_schema "$record" -r -s "$schema_program"; _cr_jq_memo got_type "$record" -r .type; _cr_jq_memo got_reason "$record" -r .reason
expect_runs 0 'the claim did not leave the request check and .reason of the record it moved in the memo'
[ "$got_schema" = "$want_schema" ] || fail "the memo holds another request check answer than jq prints: '$got_schema' vs '$want_schema'"
[ "$got_type" = "$want_type" ] || fail "the memo holds another .type than jq prints: '$got_type' vs '$want_type'"
[ "$got_reason" = "$want_reason" ] || fail "the memo holds another .reason than jq prints: '$got_reason' vs '$want_reason'"
claim_fresh 'two lines' '.reason = "first line\nsecond line\n"'
want_reason=$(jq -r .reason <<<"$record"); got_reason=
: > "$WORK/jq.log"
_cr_request_schema "$record" || fail "the schema check refused a claimed record whose reason has newlines"
_cr_jq_memo got_reason "$record" -r .reason
expect_runs 1 'a reason with newlines was put in the memo, or the request check was not'
[ "$got_reason" = "$want_reason" ] || fail "a reason with newlines reads back as '$got_reason', jq prints '$want_reason'"
# 끝 개행이 붙은 type 은 예전처럼 claim 과 스키마 검사를 통과한다. 줄 하나로 옮겨지지 않으므로
# 미리 넣지 않는다 — 넣으면 claim 의 출력 줄이 늘어 claim 이 70 으로 거부한다.
claim_fresh 'newline type' '.type = "gstapp_restart\n"'
want_type=$(jq -r .type <<<"$record"); got_type=
: > "$WORK/jq.log"
_cr_request_schema "$record" || fail "the schema check refused a claimed record whose type ends in a newline"
expect_runs 1 'a type ending in a newline was put in the memo'
_cr_jq_memo got_type "$record" -r .type
[ "$got_type" = "$want_type" ] || fail "a type ending in a newline reads back as '$got_type', jq prints '$want_type'"
# 스키마를 통과하지 못하는 요청도 claim 은 예전처럼 받아 옮긴다 — 거부는 poll 의 스키마 검사가
# 한다. claim 의 jq 가 더 내는 줄 때문에 판정이 앞당겨지지 않는다.
claim_fresh 'bad created_at' '.created_at = "x"'
rc=0; _cr_request_schema "$record" || rc=$?
[ "$rc" -eq 1 ] || fail "the schema check accepted a claimed record with a string created_at (rc $rc)"

# _cr_owner_lifecycle_in 의 두 가드(live 판정, -r .lifecycle)는 owner 텍스트가 메모에 처음이면
# jq 한 번으로 두 답을 구해 넣는다 (이슈 #150): submit 은 새 프로세스라 늘 처음이고, owner 를
# 쓰면 텍스트가 바뀐다. 넣은 답은 실제 jq 출력과 같아야 한다. live 프로그램은 필터 변수로 직접
# 만든다 — 라이브러리가 다른 문자열로 넣으면 키가 달라 적중 검사가 실패한다.
owner_file="$PIM_CAMERA_RUN_DIR/owner.json"
owner=$(cat "$owner_file"); boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE")
live_program="if (($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_LIVE_MATCH_FILTER)) then [(.pid|tostring), .proc_start_time] | join(\"\\n\") else empty end"
want_live=$(jq -r --arg boot "$boot" --arg ei "" --arg et "" "$live_program" <<<"$owner"); want_lc=$(jq -r .lifecycle <<<"$owner")
_CR_JQ_MEMO=()
: > "$WORK/jq.log"
_cr_owner_lifecycle_in ACTIVE DEGRADED || fail "the owner guard refused the live ACTIVE owner"
expect_runs 1 'the owner guard ran two jq on an owner text it met for the first time'
got_live=; got_lc=
_cr_jq_memo got_live "$owner" -r --arg boot "$boot" --arg ei "" --arg et "" "$live_program"; _cr_jq_memo got_lc "$owner" -r .lifecycle
expect_runs 1 'the owner guard did not leave the live answer and .lifecycle in the memo'
[ "$got_live" = "$want_live" ] || fail "the memo holds another live answer than jq prints: '$got_live' vs '$want_live'"
[ "$got_lc" = "$want_lc" ] || fail "the memo holds another .lifecycle than jq prints: '$got_lc' vs '$want_lc'"
_cr_owner_lifecycle_in ACTIVE || fail "the warm owner guard refused the live ACTIVE owner"
expect_runs 1 'a warm owner guard ran jq'
# 문서가 둘인 owner 는 넣지 않는다 — 두 가드가 예전처럼 jq 로 판정한다(접기 1 + 가드 2).
printf '%s\n%s\n' "$owner" "$owner" > "$owner_file"
: > "$WORK/jq.log"
rc=0; _cr_owner_lifecycle_in ACTIVE || rc=$?
[ "$rc" -eq 69 ] || fail "the owner guard accepted an owner file holding two documents (rc $rc)"
expect_runs 3 'an owner file holding two documents was put in the memo'
# 스키마의 ^[0-9]+$ 는 끝 개행 앞에서도 맞아 proc_start_time "111\n" 인 owner 도 통과한다. live
# 답은 줄 하나로 옮겨지지 않으므로 넣지 않고(접기 1 + live 1), 판정은 예전과 같다.
jq -c '.proc_start_time = "111\n"' <<<"$owner" > "$owner_file"
: > "$WORK/jq.log"
_cr_owner_lifecycle_in ACTIVE || fail "the owner guard refused an owner whose proc_start_time ends in a newline"
expect_runs 2 'the live answer of a proc_start_time ending in a newline was put in the memo'
printf '%s\n' "$owner" > "$owner_file"
# boot 가 다르면 live 프로그램은 아무것도 내지 않는다 — 넣는 답도 빈 값이어야 한다.
printf 'other-boot\n' > "$PIM_CAMERA_BOOT_ID_FILE"
want_live=$(jq -r --arg boot other-boot --arg ei "" --arg et "" "$live_program" <<<"$owner")
_CR_JQ_MEMO=()
: > "$WORK/jq.log"
rc=0; _cr_owner_lifecycle_in ACTIVE || rc=$?
[ "$rc" -eq 69 ] || fail "the owner guard accepted an owner from another boot (rc $rc)"
got_live='(none)'
_cr_jq_memo got_live "$owner" -r --arg boot other-boot --arg ei "" --arg et "" "$live_program"
expect_runs 1 'the empty live answer of an owner from another boot was not put in the memo'
[ "$got_live" = "$want_live" ] || fail "the memo holds another live answer than jq prints for another boot: '$got_live' vs '$want_live'"
printf '%s\n' "$boot" > "$PIM_CAMERA_BOOT_ID_FILE"
# 실패 경로는 예전과 같다: 깨진 owner 의 jq 오류는 가드의 jq 가 한 번만 낸다(접기의 오류는
# 버린다). owner 파일이 없으면 접기는 jq 를 띄우지 않는다.
printf '%s\n' '{"lifecycle":' > "$owner_file"
_CR_JQ_MEMO=()
rc=0; _cr_owner_lifecycle_in ACTIVE 2> "$WORK/guard.err" || rc=$?
[ "$rc" -eq 69 ] || fail "the owner guard accepted a broken owner file (rc $rc)"
[ "$(grep -c 'parse error' "$WORK/guard.err")" -eq 1 ] || { cat "$WORK/guard.err" >&2; fail 'a broken owner file did not print exactly one jq parse error'; }
rm -f "$owner_file"
: > "$WORK/jq.log"
rc=0; _cr_owner_lifecycle_in ACTIVE 2>/dev/null || rc=$?
[ "$rc" -eq 69 ] || fail "the owner guard accepted a missing owner file (rc $rc)"
expect_runs 1 'the owner guard ran more jq than before for a missing owner file'
printf '%s\n' "$owner" > "$owner_file"

# owner 를 쓰는 jq 는 쓴 owner 텍스트의 두 가드 답도 내어 넣는다 (이슈 #150): 쓴 직후의 가드는
# jq 를 띄우지 않는다. 넣은 답은 실제 jq 출력과 같아야 한다.
cam_owner_set_lifecycle RECOVERING || fail "the lifecycle write to RECOVERING was refused"
written=$(cat "$owner_file")
want_live=$(jq -r --arg boot "$boot" --arg ei "" --arg et "" "$live_program" <<<"$written"); want_lc=$(jq -r .lifecycle <<<"$written")
: > "$WORK/jq.log"
_cr_owner_lifecycle_in RECOVERING || fail "the owner guard refused the owner the lifecycle write had just written"
got_live=; got_lc=
_cr_jq_memo got_live "$written" -r --arg boot "$boot" --arg ei "" --arg et "" "$live_program"; _cr_jq_memo got_lc "$written" -r .lifecycle
expect_runs 0 'the owner guard ran jq on the owner text the lifecycle write had just written'
[ "$got_live" = "$want_live" ] || fail "the lifecycle write put another live answer than jq prints: '$got_live' vs '$want_live'"
[ "$got_lc" = "$want_lc" ] || fail "the lifecycle write put another .lifecycle than jq prints: '$got_lc' vs '$want_lc'"
# 출력이 정확히 네 줄일 때만 넣는다: 첫 문서의 lifecycle 에 개행이 있으면 줄이 밀려 셋째·넷째 줄이
# 쓴 텍스트의 답이 아니다. 가드 판정은 메모를 비우고 다시 판정한 것과 같아야 한다.
shifted=$(jq -c '.lifecycle = "RECOVERING"' <<<"$owner")
{ jq -c --arg l "ACTIVE"$'\n'"$shifted" '.lifecycle = $l' <<<"$owner"; printf '%s\n' "$owner"; } > "$owner_file"
rc=0; cam_owner_set_lifecycle RECOVERING || rc=$?
[ "$rc" -eq 0 ] || fail "the lifecycle write behind a shifted line returned rc $rc"
rc=0; _cr_owner_lifecycle_in RECOVERING || rc=$?
_CR_JQ_MEMO=()
fresh=0; _cr_owner_lifecycle_in RECOVERING || fresh=$?
[ "$rc" -eq "$fresh" ] || fail "a shifted line of the lifecycle write was put in the memo (rc $rc, $fresh without the memo)"
printf '%s\n' "$owner" > "$owner_file"
# 두 답은 함께 남는다: 메모가 상한 바로 아래(63개)여도 lifecycle 답을 넣으며 메모를 비워 먼저
# 넣은 live 답을 지우지 않는다(지우면 접기는 건너뛰고 live 가드가 jq 를 띄운다).
_CR_JQ_MEMO=(); for ((i = 0; i < 63; i++)); do _cr_jq_memo_put x "filler$i" -r .; done
[ "${#_CR_JQ_MEMO[@]}" -eq 63 ] || fail "the memo was not filled to 63 entries (${#_CR_JQ_MEMO[@]})"
_cr_owner_guard_put "$owner" "$boot" "+4242:111" "+ACTIVE"
_cr_jq_memo_has "$owner" -r --arg boot "$boot" --arg ei "" --arg et "" "$live_program" || fail 'the live answer was evicted by the lifecycle answer put after it'
_cr_jq_memo_has "$owner" -r .lifecycle || fail 'the lifecycle answer was not kept'

# 레코드 가드 두 개(_cr_owner_immutable_equal, _cr_record_owner_ready)는 같은 두 owner 로 jq 를
# 하나씩 띄운다. 그 쌍이 메모에 처음이면 jq 한 번으로 두 답을 구해 넣는다 (이슈 #168). 넣은 답은
# 실제 jq 출력과 같아야 한다. 프로그램은 필터 변수로 직접 만든다 — 라이브러리가 다른 문자열로
# 넣으면 키가 달라 적중 검사가 실패한다.
record=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json"); current=$(cat "$owner_file")
imm_program="(\$a | ($_CR_OWNER_SCHEMA_FILTER)) and (\$b | ($_CR_OWNER_SCHEMA_FILTER)) and $_CR_OWNER_IMMUTABLE_EQ_FILTER"
ready_program="if (length == 1) then .[0] | if ((\$a | ($_CR_OWNER_SCHEMA_FILTER)) and ($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_LIVE_MATCH_FILTER) and (. as \$b | $_CR_OWNER_IMMUTABLE_EQ_FILTER)) then [.lifecycle, (.pid|tostring), .proc_start_time] | join(\"\\n\") else empty end else empty end"
rec_owner=$(jq -c .owner <<<"$record")
want_imm=$(jq -e -n --argjson a "$rec_owner" --argjson b "$current" "$imm_program")
want_ready=$(jq -r -s --argjson a "$rec_owner" --arg boot "$boot" --arg ei "" --arg et "" "$ready_program" <<<"$current")
_CR_JQ_MEMO=()
_cr_owner_lifecycle_in ACTIVE DEGRADED || fail "the owner guard refused the live ACTIVE owner before the record guards"
_cr_jq_memo got_owner "$record" -c .owner
: > "$WORK/jq.log"
_cr_record_owner_matches "$record" || fail "the record guard refused the active record"
_cr_record_owner_ready "$record" ACTIVE DEGRADED || fail "the ready guard refused the active record"
expect_runs 1 'the record guards ran two jq on an owner pair they met for the first time'
got_imm=; got_ready=
_cr_jq_memo got_imm "" -e -n --argjson a "$rec_owner" --argjson b "$current" "$imm_program"
_cr_jq_memo got_ready "$current" -r -s --argjson a "$rec_owner" --arg boot "$boot" --arg ei "" --arg et "" "$ready_program"
expect_runs 1 'the record guards did not leave both answers in the memo'
[ "$got_imm" = "$want_imm" ] || fail "the memo holds another immutable answer than jq prints: '$got_imm' vs '$want_imm'"
[ "$got_ready" = "$want_ready" ] || fail "the memo holds another ready answer than jq prints: '$got_ready' vs '$want_ready'"
# 지금 owner 파일에 문서가 둘이면 넣지 않는다 — 가드가 예전처럼 jq 로 거부한다(접기 1 + 가드 1).
printf '%s\n%s\n' "$owner" "$owner" > "$owner_file"
_CR_JQ_MEMO=()
_cr_jq_memo got_owner "$record" -c .owner
: > "$WORK/jq.log"
rc=0; _cr_record_owner_matches "$record" 2>/dev/null || rc=$?
[ "$rc" -eq 1 ] || fail "the record guard accepted an owner file holding two documents (rc $rc)"
expect_runs 2 'the record guard pair was put in the memo for an owner file holding two documents'
printf '%s\n' "$owner" > "$owner_file"
# 불변 필드가 다르면(owner 가 바뀜) immutable 답은 거짓이다 — 거짓은 넣지 않고, 가드는 예전처럼
# 거부한다. 참으로 넣으면 다른 owner 의 레코드를 받아들인다(fail-open).
jq -c '.created_at += 1' <<<"$owner" > "$owner_file"
_CR_JQ_MEMO=()
_cr_jq_memo got_owner "$record" -c .owner
rc=0; _cr_record_owner_matches "$record" || rc=$?
[ "$rc" -eq 1 ] || fail "the record guard accepted an owner whose created_at changed (rc $rc)"
printf '%s\n' "$owner" > "$owner_file"
# submit 의 jq 는 쓰기 가드(_cr_record_owner_ready)가 같은 owner 텍스트로 낼 답도 내어 넣는다
# (이슈 #168): submit 은 jq 두 번(owner 가드 접기, submit)으로 끝난다. 넣은 답은 실제 jq 출력과 같다.
rm -f "$PIM_CAMERA_RUN_DIR/recovery/active.json" "$PIM_CAMERA_RUN_DIR/recovery/pending.json"
_CR_JQ_MEMO=()
: > "$WORK/jq.log"
# cam-recoveryctl 처럼 owner 컨텍스트를 물려받지 않은 submit 이다(물려받으면 그 대조에 jq 1회가 더 든다).
PIM_CAMERA_OWNER_INVOCATION='' cam_request_submit gstapp_restart operator 'submit ready' >/dev/null || fail "the submit for the write guard check was refused"
expect_runs 2 'the submit ran the write guard jq itself'
pending=$(cat "$PIM_CAMERA_RUN_DIR/recovery/pending.json"); current=$(cat "$owner_file")
rec_owner=$(jq -c .owner <<<"$pending")
want_ready=$(jq -r -s --argjson a "$rec_owner" --arg boot "$boot" --arg ei "" --arg et "" "$ready_program" <<<"$current")
: > "$WORK/jq.log"
got_ready=; _cr_jq_memo got_ready "$current" -r -s --argjson a "$rec_owner" --arg boot "$boot" --arg ei "" --arg et "" "$ready_program"
expect_runs 0 'the submit did not leave the write guard answer in the memo'
[ "$got_ready" = "$want_ready" ] || fail "the submit put another write guard answer than jq prints: '$got_ready' vs '$want_ready'"
rm -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json"

echo "jq memo: PASS"
