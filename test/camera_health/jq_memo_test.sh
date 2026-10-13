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
# 런타임 문서 한 번 읽기 (이슈 #168): 앱·시작 지연·녹화 임시 경로·차량 이름을 jq 한 번으로 읽어
# 파일 정체로 둔다. 같은 파일이면 세 함수가 jq 를 다시 띄우지 않고, 결과는 예전과 같다.
export PIM_CAMERA_SESSION_TIME_FILE="$WORK/no-session-marker"
printf '%s\n' '{"VHL_CAM":{"app":"streamApp","app_delay":7,"tmp_path":"/nonexistent-pim-tmp","vhl_name":"veh1"}}' > "$runtime.next" && mv -f "$runtime.next" "$runtime"
: > "$WORK/jq.log"
_cam_runtime_app_into app "$runtime" || fail "the runtime app was refused for a clean runtime document"
[ "$app" = PIMCAM ] || fail "the runtime app read '$app' from a streamApp document"
delay_info=$(cam_runtime_app_delay "$runtime") || fail "the app delay was refused for a clean runtime document"
[ "$delay_info" = $'PIMCAM\t7' ] || fail "the app delay read '$delay_info'"
cam_cleanup_recording_orphans "$runtime" || fail "the orphan cleanup refused a clean runtime document"
expect_runs 1 'the runtime document was read by jq more than once for one file'
# 깨끗하지 않은 문서(경로가 숫자)는 두지 않는다 — 처음 한 번 더 읽고, 세 함수는 예전처럼 jq 로
# 읽는다(앱 1, 지연 1, 경로·이름 2). 결과는 예전과 같다: 경로가 숫자면 정리를 거부한다(64).
printf '%s\n' '{"VHL_CAM":{"app":"gstApp","app_delay":3,"tmp_path":5,"vhl_name":"veh1"}}' > "$runtime.next" && mv -f "$runtime.next" "$runtime"
: > "$WORK/jq.log"
_cam_runtime_app_into app "$runtime" || fail "the runtime app was refused for a document with a numeric tmp_path"
[ "$app" = gstApp ] || fail "the runtime app read '$app' from a document with a numeric tmp_path"
delay_info=$(cam_runtime_app_delay "$runtime") || fail "the app delay was refused for a document with a numeric tmp_path"
[ "$delay_info" = $'gstApp\t3' ] || fail "the app delay read '$delay_info' from a document with a numeric tmp_path"
rc=0; cam_cleanup_recording_orphans "$runtime" || rc=$?
[ "$rc" -eq 64 ] || fail "the orphan cleanup accepted a numeric tmp_path (rc $rc)"
expect_runs 5 'a runtime document that cannot be kept was read more than once by the one-read path'
# 지연은 예전 검사(^[0-9]+$, 끝 개행 앞에서도 맞음)를 그대로 따른다: "12\n" 은 예전처럼 12 다.
printf '%s\n' '{"VHL_CAM":{"app":"gstApp","app_delay":"12\n","tmp_path":"/nonexistent-pim-tmp","vhl_name":"veh1"}}' > "$runtime.next" && mv -f "$runtime.next" "$runtime"
_cam_runtime_app_into app "$runtime" || fail "the runtime app was refused for a delay ending in a newline"
delay_info=$(cam_runtime_app_delay "$runtime") || fail "the app delay refused a delay ending in a newline"
[ "$delay_info" = $'gstApp\t12' ] || fail "a delay ending in a newline read '$delay_info'"
# 앱 선택·지연 식은 cam_runtime_app·cam_runtime_app_delay·_cam_runtime_doc 세 곳에 있다(앞 둘은
# 혼자 떼어 쓰여 공유 변수에 기대지 않는다). 한 번 읽기가 둔 값은 두 함수가 jq 로 직접 낸 값과 같아야 한다.
for doc in '{"VHL_CAM":{"app":"gstApp","app_delay":4,"tmp_path":"/t","vhl_name":"v"}}' \
           '{"VHL_CAM":{"app":"streamApp","tmp_path":"/t","vhl_name":"v"}}' \
           '{"VHL_CAM":{"app":"PIMCAM","capture":{"enable":true},"app_delay":"9","tmp_path":"/t","vhl_name":"v"}}' \
           '{"VHL_CAM":{"app":"other","app_delay":"x","tmp_path":"/t","vhl_name":"v"}}' \
           '{"VHL_CAM":{"capture":{"enable":"true"},"app_delay":2.5}}'; do
    printf '%s\n' "$doc" > "$runtime.next" && mv -f "$runtime.next" "$runtime"
    _CAM_RUNTIME_DOC_KEY=""; _CAM_RUNTIME_DOC_OK=0
    _cam_runtime_doc "$runtime" || fail "the runtime document was not kept: $doc"
    kept_app=${_CAM_RUNTIME_DOC[0]}; kept_delay=${_CAM_RUNTIME_DOC[1]}
    _CAM_RUNTIME_DOC_OK=0
    direct_app=$(cam_runtime_app "$runtime") || direct_app=""
    direct=$(cam_runtime_app_delay "$runtime" 2>/dev/null) || direct=""
    [ "$kept_app" = "$direct_app" ] || fail "the kept app '$kept_app' differs from cam_runtime_app '$direct_app' for $doc"
    if [ -n "$direct" ]; then
        [ "$kept_app"$'\t'"$kept_delay" = "$direct" ] || fail "the kept app/delay differ from cam_runtime_app_delay '$direct' for $doc"
    else
        [ -z "$kept_app" ] || [[ ! $kept_delay =~ ^[0-9]+$ ]] || fail "the kept app/delay pass where cam_runtime_app_delay refuses for $doc"
    fi
done

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
# 두 답은 함께 남는다: 메모가 상한 바로 아래여도 lifecycle 답을 넣으며 메모를 비워 먼저
# 넣은 live 답을 지우지 않는다(지우면 접기는 건너뛰고 live 가드가 jq 를 띄운다).
memo_max=${_CR_JQ_MEMO_MAX:-64}
_CR_JQ_MEMO=(); for ((i = 0; i < memo_max - 1; i++)); do _cr_jq_memo_put x "filler$i" -r .; done
[ "${#_CR_JQ_MEMO[@]}" -eq "$((memo_max - 1))" ] || fail "the memo was not filled to one below its cap (${#_CR_JQ_MEMO[@]})"
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
# start_cam 처럼 메모가 빈 새 프로세스의 실행자 가드는 active 의 .id, 레코드 가드의 .owner·ready 를 jq
# 세 번으로 구했다. 셋을 jq 한 번으로 넣는다 (이슈 #168). 넣은 답은 실제 jq 출력과 같아야 하고, 실제
# jq 가 실패할 입력(argv 한 칸을 넘는 .owner 텍스트)에는 ready 를 넣지 않는다.
fold_check() {
    local rec=$1 what=$2 cur want_id want_owner want_ready got
    cur=$(cat "$owner_file")
    _CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
    : > "$WORK/jq.log"
    _cr_active_guard_fold "$rec"
    expect_runs 1 "$what: the active guard fold did not run exactly one jq"
    want_id=$(jq -r .id <<<"$rec"); want_owner=$(jq -c .owner <<<"$rec")
    _cr_jq_memo_has "$rec" -r .id || fail "$what: the fold did not put the record id"
    _cr_jq_memo got "$rec" -r .id
    [ "$got" = "$want_id" ] || fail "$what: the fold put another id than jq prints: '$got' vs '$want_id'"
    _cr_jq_memo_has "$rec" -c .owner || fail "$what: the fold did not put the record owner"
    _cr_jq_memo got "$rec" -c .owner
    [ "$got" = "$want_owner" ] || fail "$what: the fold put another owner than jq prints"
    fold_ready=0
    if _cr_jq_memo_has "$cur" -r -s --argjson a "$want_owner" --arg boot "$boot" --arg ei "" --arg et "" "$ready_program"; then
        fold_ready=1
        want_ready=$(jq -r -s --argjson a "$want_owner" --arg boot "$boot" --arg ei "" --arg et "" "$ready_program" <<<"$cur" 2>/dev/null) ||
            fail "$what: the fold put a ready answer where the guard's jq fails"
        _cr_jq_memo got "$cur" -r -s --argjson a "$want_owner" --arg boot "$boot" --arg ei "" --arg et "" "$ready_program"
        [ "$got" = "$want_ready" ] || fail "$what: the fold put another ready answer than jq prints: '$got' vs '$want_ready'"
    fi
}
fold_check "$record" 'the active record'
[ "$fold_ready" -eq 1 ] || fail 'the fold did not put the ready answer for the active record'
# 두 owner 의 created_at 이 1e1000 이면 가드는 -c .owner 텍스트를 다시 파싱한 값으로 판정한다.
sed -E 's/"created_at":[0-9]+/"created_at":1e1000/' <<<"$owner" > "$owner_file"
huge_ca=$(cat "$owner_file")
[ "$huge_ca" != "$owner" ] || fail 'the created_at fixture did not change the owner'
huge_rec=$(sed -E 's/"created_at":[0-9]+/"created_at":1e1000/g' <<<"$record")
[ "$huge_rec" != "$record" ] || fail 'the created_at fixture did not change the record owner'
fold_check "$huge_rec" 'a created_at of 1e1000 in both owners'
printf '%s\n' "$owner" > "$owner_file"
# 레코드는 128KiB 미만이어도 .owner 텍스트는 넘을 수 있다(1e1000 은 다시 쓰면 길어진다). 가드의
# --argjson 이 실패해 69 이므로 ready 는 넣지 않는다.
printf -v pad '1e1000,%.0s' {1..18000}
wide_rec=${record/'"owner":{'/'"owner":{"pad":['"${pad%,}"'],'}
[ "$wide_rec" != "$record" ] || fail 'the wide owner fixture did not change the record'
wide_bytes=0; _cr_byte_length wide_bytes "$wide_rec"
[ "$wide_bytes" -lt 131072 ] || fail "the wide owner fixture is $wide_bytes bytes, not under one argv slot"
fold_check "$wide_rec" 'an owner text larger than one argv slot'
[ "$fold_ready" -eq 0 ] || fail 'the fold put a ready answer for an owner text larger than one argv slot'
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
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

# 메모 상한 (이슈 #168): 요청 한 건이 항목을 20여 개 남긴다 — 오래 도는 데몬이 몇 건마다 메모를
# 통째로 비우지 않도록 상한은 100 건을 넘게 담는다. 상한에 닿으면 비우고 새 항목 하나만 남는다.
_CR_JQ_MEMO=(); for ((i = 0; i < 100; i++)); do _cr_jq_memo_put x "keep$i" -r .; done
[ "${#_CR_JQ_MEMO[@]}" -eq 100 ] || fail "the memo did not keep 100 entries (${#_CR_JQ_MEMO[@]}) - a long-running daemon would clear it every few requests"
for ((i = 100; i < memo_max; i++)); do _cr_jq_memo_put x "keep$i" -r .; done
_cr_jq_memo_put x "one-more" -r .
[ "${#_CR_JQ_MEMO[@]}" -eq 1 ] || fail "the memo was not cleared at its cap (${#_CR_JQ_MEMO[@]})"
# 크기 상한 (이슈 #168): 키에는 입력 문서가 통째로 들어간다. 큰 문서가 이어지면 항목 수가 아니라
# 문자 수로 비워, 오래 도는 데몬이 수십 MiB 를 붙들지 않는다.
big=$(printf '%*s' 30000 '' | tr ' ' x)
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
for ((i = 0; i < 100; i++)); do _cr_jq_memo_put x "$big$i" -r .; done
[ "${#_CR_JQ_MEMO[@]}" -lt 100 ] || fail "the memo kept 100 entries of 30000 characters each (no size bound)"
# 크기는 바이트로 센다: UTF-8 로케일에서 한글 3만 자는 9만 바이트다. 40 개(약 3.6MB)를 담으면 안 된다.
saved_lc_all=${LC_ALL-}; LC_ALL=C.UTF-8
printf -v wide '%*s' 30000 ''; wide=${wide// /가}
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
for ((i = 0; i < 40; i++)); do _cr_jq_memo_put x "$wide$i" -r .; done
wide_kept=${#_CR_JQ_MEMO[@]}
LC_ALL=$saved_lc_all
[ "$wide_kept" -lt 40 ] || fail "the memo kept 40 entries of 30000 Korean characters (about 3.6 MB) - the size bound counted characters, not bytes"
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
# 크기 상한에서도 두 답은 함께 남는다: 첫 답은 들어가고 둘째 답은 넘치게 문자 수를 채워도,
# 넣기 전에 둘의 자리를 함께 잡으므로 둘째 넣기가 첫 답을 지우지 않는다.
printf -v k1 '%s\037' -r --arg boot "$boot" --arg ei "" --arg et "" "$live_program"; k1+=$'\036'"$owner"
pad_len=$(( _CR_JQ_MEMO_BYTE_MAX - ${#k1} - 8 - 1 - 7 ))
pad=$(printf '%*s' "$pad_len" '' | tr ' ' p)
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
_cr_jq_memo_put x "$pad" -r .
_cr_owner_guard_put "$owner" "$boot" "+4242:111" "+ACTIVE"
_cr_jq_memo_has "$owner" -r --arg boot "$boot" --arg ei "" --arg et "" "$live_program" || fail 'the live answer was evicted by the size bound between the two puts'
_cr_jq_memo_has "$owner" -r .lifecycle || fail 'the lifecycle answer was not kept at the size bound'
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
# 이미 있는 키를 다시 넣어도 크기는 그 항목 하나만큼이다: _cr_request_schema 는 같은 요청을 검증할 때마다
# .type 답을 다시 넣는다. 3만 자 키를 100 번 넣어도(두 번 세면 약 3MB) 메모가 비워지면 안 된다.
entry_bytes() { local LC_ALL=C k; printf -v k '%s\037' -r .; k+=$'\036'"$1"; echo $(( ${#k} + ${#2} )); }
_cr_jq_memo_put x "keep-me" -r .
for ((i = 0; i < 100; i++)); do _cr_jq_memo_put x "$big" -r .; done
_cr_jq_memo_has "keep-me" -r . || fail 'putting one key 100 times cleared the memo - the size bound counted the same entry on every put'
[ "$_CR_JQ_MEMO_BYTES" -eq $(( $(entry_bytes keep-me x) + $(entry_bytes "$big" x) )) ] || fail "the size count after re-puts is $_CR_JQ_MEMO_BYTES, not the two entries"
_cr_jq_memo_put yy "$big" -r .
[ "$_CR_JQ_MEMO_BYTES" -eq $(( $(entry_bytes keep-me x) + $(entry_bytes "$big" yy) )) ] || fail "the size count after replacing a value is $_CR_JQ_MEMO_BYTES"
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
# 빈 메모에도 들어가지 않는 항목은 담지 않는다: 누계는 늘 항목 크기의 합이고 상한을 넘지 않는다.
memo_sum() { local LC_ALL=C k s=0; for k in "${!_CR_JQ_MEMO[@]}"; do s=$(( s + ${#k} + ${#_CR_JQ_MEMO[$k]} )); done; echo "$s"; }
memo_sane() {
    [ "$_CR_JQ_MEMO_BYTES" -eq "$(memo_sum)" ] && [ "$_CR_JQ_MEMO_BYTES" -le "$_CR_JQ_MEMO_BYTE_MAX" ] ||
        fail "$1 (count $_CR_JQ_MEMO_BYTES, entries $(memo_sum), cap $_CR_JQ_MEMO_BYTE_MAX)"
}
huge=$(printf '%*s' "$_CR_JQ_MEMO_BYTE_MAX" '' | tr ' ' h)
_cr_jq_memo_put x "keep-me" -r .
_cr_jq_memo_put x "$huge" -r .
_cr_jq_memo_has "keep-me" -r . || fail 'an entry larger than the size cap cleared the memo'
! _cr_jq_memo_has "$huge" -r . || fail 'a put kept an entry larger than the size cap'
memo_sane 'the size count after an oversized put'
: > "$WORK/jq.log"
got=; _cr_jq_memo got "\"$huge\"" -r length
[ "$got" = "$_CR_JQ_MEMO_BYTE_MAX" ] || fail "an oversized jq call returned '$got'"
_cr_jq_memo got "\"$huge\"" -r length
expect_runs 2 'an oversized jq answer was cached'
memo_sane 'the size count after an oversized jq call'
# 이미 있는 키를 담을 수 없는 값으로 바꾸면 옛 값을 남기지 않는다.
_cr_jq_memo_put x "dup" -r .
_cr_jq_memo_put "$huge" "dup" -r .
! _cr_jq_memo_has "dup" -r . || fail 'an old value stayed after its key got a value larger than the size cap'
memo_sane 'the size count after replacing a value with an oversized one'
# 두 답의 자리가 빈 메모에도 없으면 둘 다 넣지 않고 메모도 비우지 않는다(set -e 아래에서도 이어 간다).
_cr_jq_memo_put x "keep-me" -r .
_cr_owner_guard_put "${huge:0:1100000}" "$boot" "+4242:111" "+ACTIVE"
_cr_jq_memo_has "keep-me" -r . || fail 'a pair larger than the size cap cleared the memo'
! _cr_jq_memo_has "${huge:0:1100000}" -r .lifecycle || fail 'a pair larger than the size cap was put'
memo_sane 'the size count after an oversized pair'
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0

# owner lifecycle 을 쓰면 _cr_load_owner_lifecycle 의 캐시(파일 정체)에 그 값을 둔다 (이슈 #168): repair
# 확인·실행 진입·데몬 루프가 방금 쓴 owner 를 jq 로 다시 읽지 않는다. 값은 jq 가 읽는 것과 같다.
cam_owner_set_lifecycle RECOVERING || fail "the lifecycle write to RECOVERING for the cache check was refused"
: > "$WORK/jq.log"
_cr_load_owner_lifecycle || fail "the owner lifecycle could not be loaded after a lifecycle write"
expect_runs 0 'the owner lifecycle written by this process was read again by jq'
[ "$_CR_LIFECYCLE_VAL" = "$(jq -r '.lifecycle // empty' "$owner_file")" ] || fail "the cached lifecycle '$_CR_LIFECYCLE_VAL' differs from the file"
# 같은 쓰기는 갱신본의 export 답(실행 컨텍스트의 여섯 필드)도 넣는다 (이슈 #168): 바로 뒤의
# _cr_owner_export_fields 는 jq 를 띄우지 않고, 넣은 답은 실제 jq 출력과 같다. 프로그램은 필터
# 변수로 직접 만든다 — 라이브러리가 다른 문자열로 넣으면 키가 달라 적중 검사가 실패한다.
export_program="if ($_CR_OWNER_SCHEMA_FILTER) then [.boot_id,.invocation_id,(.pid|tostring),.proc_start_time,.token,(.created_at|tostring)] | join(\"\\n\") else empty end"
written=$(cat "$owner_file")
: > "$WORK/jq.log"
( _cr_owner_export_fields "$written" && [ "$PIM_CAMERA_OWNER_TOKEN" = "$(jq -r .token <<<"$written")" ] ) ||
    fail 'the owner fields could not be exported after a lifecycle write'
expect_runs 1 'the export of the owner this process just wrote ran jq (only the token check may)'
want_fields=$(jq -r "$export_program" <<<"$written")
got_fields=; _cr_jq_memo got_fields "$written" -r "$export_program"
expect_runs 2 'the lifecycle write did not leave the export answer in the memo'
[ "$got_fields" = "$want_fields" ] || fail "the lifecycle write put another export answer than jq prints: '$got_fields' vs '$want_fields'"
cam_owner_set_lifecycle ACTIVE || fail "the lifecycle write back to ACTIVE was refused"
# 다른 쓰기(이 함수를 거치지 않음)는 새 파일이라 키가 달라 다시 읽는다.
jq -c '.lifecycle = "DEGRADED"' "$owner_file" > "$owner_file.next" && mv -f "$owner_file.next" "$owner_file"
: > "$WORK/jq.log"
_cr_load_owner_lifecycle || fail "the owner lifecycle could not be loaded after an outside write"
expect_runs 1 'an owner file replaced outside the lifecycle write was served from the cache'
[ "$_CR_LIFECYCLE_VAL" = DEGRADED ] || fail "the lifecycle after an outside write read '$_CR_LIFECYCLE_VAL'"
printf '%s\n' "$owner" > "$owner_file"

echo "jq memo: PASS"
