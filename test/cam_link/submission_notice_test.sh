#!/usr/bin/env bash
# The two parts of the issue-109 progress-report change, each pinned so that
# reverting it fails here.
#
# 1. cam-recoveryctl must announce the queued request on stderr before it waits,
#    and must leave stdout alone.  "Before it waits" is pinned against the first poll,
#    not against wall-clock time, so the check is deterministic.  The stdout contract
#    is the single CAM_RECOVERY_RESULT line, and recovery_protocol_test.sh compares
#    that capture by exact string while redirecting stdout only.
#    Parts 1b and 1c then run the real program rather than an extracted function, on a
#    file and on a terminal, because suppression at the call site or behind a terminal
#    test is invisible to a check that only reads the function body.
# 2. cam_enable.sh must stop passing start_cam.sh a positional delay it discards.
#
# Hardware-free and hook-free: part 1 extracts wait_for_result from the real file
# with sed and drives it against a stub status reader, so no production seam is
# added for the test's benefit; part 2 reads cam_enable.sh without running it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-submission-notice.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export WORK

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- 1: the notice is on stderr before the wait, once, and stdout stays empty ---
sed -n '/^wait_for_result() {/,/^}/p' "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" > "$WORK/wait_fn.sh"
[ -s "$WORK/wait_fn.sh" ] || fail 'could not extract wait_for_result from cam-recoveryctl'
export NOTICE_ERR="$WORK/notice.err" NOTICE_FIRSTPOLL="$WORK/firstpoll" NOTICE_EARLY="$WORK/early"
cat > "$WORK/notice.sh" <<'SH'
set -u
# Never terminal, so the wait exhausts.  The first poll also records whether the notice
# had already reached stderr by then.  The loop calls this inside a command
# substitution, so that marker has to be a file rather than a shell variable.
cam_recovery_status_json() {
    if [ ! -e "$NOTICE_FIRSTPOLL" ]; then
        : > "$NOTICE_FIRSTPOLL"
        grep -q '^CAM_RECOVERY_SUBMITTED ' "$NOTICE_ERR" && : > "$NOTICE_EARLY"
    fi
    return 69
}
source "$WORK/wait_fn.sh"
wait_for_result 'ID-1234' 'gstapp_stop' "$1"
SH

# Two drives, and two independent properties, because each catches a mutation the
# other lets through.
#
# Count: a zero wait still runs the poll-loop body once, so on its own it cannot tell
# a notice above the loop from one inside it - move the printf to the first statement
# in `while :; do` and the zero-wait drive still sees exactly one line.  The
# two-second drive is what makes the count reject that placement.
#
# Order: a printf deferred onto the timeout return path prints exactly once too, so
# the count accepts it - and that placement emits nothing until the wait has already
# expired, which is the very silence this change exists to end.  The first-poll marker
# rejects it, and does so without depending on timing.
#
# What the order marker does not pin: how soon.  A sleep ahead of the printf still
# precedes the first poll, so promptness is deliberately not asserted here - it would
# need a clock and would make this test timing-dependent for no gain, since the
# reported symptom was a whole action's worth of silence, not a second of it.
for seconds in 0 2; do
    rm -f "$NOTICE_FIRSTPOLL" "$NOTICE_EARLY"
    set +e
    bash "$WORK/notice.sh" "$seconds" > "$WORK/notice.out" 2> "$NOTICE_ERR"
    notice_rc=$?
    set -e
    [ "$notice_rc" -eq 124 ] || fail "an exhausted ${seconds}s wait should return 124, got $notice_rc"
    [ ! -s "$WORK/notice.out" ] || fail "the notice reached stdout: $(cat "$WORK/notice.out")"
    grep -q "^CAM_RECOVERY_SUBMITTED id=ID-1234 type=gstapp_stop (waiting up to ${seconds}s)\$" \
        "$NOTICE_ERR" \
        || { echo "FAIL: no submission notice on stderr for a ${seconds}s wait" >&2
             sed 's/^/  /' "$NOTICE_ERR" >&2; exit 1; }
    # Without a poll the order check below would pass vacuously, so prove one happened.
    [ -e "$NOTICE_FIRSTPOLL" ] \
        || fail "the ${seconds}s drive never polled, so the order check proves nothing"
    [ -e "$NOTICE_EARLY" ] \
        || fail "the notice was not on stderr yet when the ${seconds}s wait first polled"
    notice_count=$(grep -c '^CAM_RECOVERY_SUBMITTED ' "$NOTICE_ERR")
    [ "$notice_count" -eq 1 ] \
        || fail "the ${seconds}s wait should print the notice once, saw $notice_count"
done

# --- 1b: the real entry point, not an extracted copy ---
# Part 1 drives a sed-extracted wait_for_result, which cannot see two things an
# operator does see.  A guard on the printf that this harness happens to satisfy - the
# drives above all send stderr to a file, so `[ -t 2 ]` is false - and a redirection at
# the call site or the dispatch, which is outside the function body entirely.  Both go
# silent exactly where issue #109 reported silence, so check the program's own stderr.
export SNT_CTL="$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl"
export SNT_LIB="$WORK/lib"
SNT_ID=11111111-2222-3333-4444-555555555555
mkdir -p "$SNT_LIB"

# $1 = the stub's cam_recovery_status_json body; everything after it is the CLI's own
# argv.  Sets cli_rc and cli_notices; leaves stdout in $WORK/cli.out and stderr in
# $WORK/cli.err.
write_stub() {
    { printf '%s\n' '_cr_request_type() { return 0; }'
      printf 'cam_request_submit() { printf %s; }\n' "'$SNT_ID\\n'"
      printf '%s\n' "$1"; } > "$SNT_LIB/cam_recovery.sh"
}
drive_cli() {
    local stub=$1; shift
    write_stub "$stub"
    # env -i: the production process does not inherit this harness's variables, so a
    # guard keyed on one of them must not be able to hide behind the drive.
    set +e
    env -i PATH="$PATH" PIM_LIB="$SNT_LIB" "$SNT_CTL" "$@" \
        > "$WORK/cli.out" 2> "$WORK/cli.err"
    cli_rc=$?
    set -e
    cli_notices=$(grep -c '^CAM_RECOVERY_SUBMITTED ' "$WORK/cli.err" || true)
}
STUB_PENDING='cam_recovery_status_json() { return 69; }'
STUB_OK='cam_recovery_status_json() { printf "{\"status\":\"SUCCEEDED\",\"rc\":0}\n"; }'
STUB_HARD='cam_recovery_status_json() { return 70; }'

# Never terminal: the wait exhausts, stdout stays empty, the notice is still there.
drive_cli "$STUB_PENDING" request gstapp_stop --source test --reason probe --wait 0
[ "$cli_rc" -eq 124 ] || fail "the real CLI should exhaust the wait with 124, got $cli_rc"
[ ! -s "$WORK/cli.out" ] || fail "the real CLI put the notice on stdout: $(cat "$WORK/cli.out")"
[ "$cli_notices" -eq 1 ] \
    || { echo "FAIL: the real CLI printed $cli_notices submission notices on its stderr" >&2
         sed 's/^/  /' "$WORK/cli.err" >&2; exit 1; }

# A hard status error returns straight out of the loop; still exactly one notice.
drive_cli "$STUB_HARD" request gstapp_stop --source test --reason probe --wait 5
[ "$cli_rc" -eq 70 ] || fail "a hard status error should surface as 70, got $cli_rc"
[ "$cli_notices" -eq 1 ] || fail "the error path should print the notice once, saw $cli_notices"

# --- 1c: every production shape, on both stderr kinds and both environments ---
# The six rows are each invocation a production wrapper under dist/ makes, argument for
# argument: the action, the wait and the --source value come from the wrapper rather than
# being invented, because a condition keyed on any of them is silent for the board's real
# invocations while a suite that drives only its own values stays green.  120 and 300 are
# the only waits these wrappers pass; the camera_health suites pass others, which is why
# this says "production wrapper" and not "any caller".  The last row is not a wrapper
# shape - nothing under dist/ invokes apply-config, and 300 is the runbook's operator
# example - it is here because apply-config is a separate dispatch arm and a redirection
# there is invisible to every `request` drive.
#
# Each row is driven in all four cells of {bare environment, inherited environment} x
# {stderr on a file, stderr on a terminal}.  Driving one cell per row is what let earlier
# revisions stay green while a condition on the terminal *and* the wait, or on the
# environment *and* the action, silenced real operator commands: init_cam.sh and
# cam_hard_reset.sh both wait 300, and a guard naming either went unnoticed.  The product
# is small and enumerable, so it is driven rather than argued about.
command -v script >/dev/null 2>&1 \
    || fail 'script(1) is required to drive the notice with stderr on a terminal'
export SNT_ARGV=''
SNT_ROWS=0

# fd 3, not stdin: script(1) inside the body reads stdin, and on stdin this heredoc is
# drained after the first row - a measured 1 of 6 rows ran before this was fixed.
while read -r sub act secs src <&3; do
    [ -n "$sub" ] || continue
    SNT_ROWS=$((SNT_ROWS + 1))
    if [ "$sub" = apply-config ]; then
        SNT_ARGV="apply-config --source $src --reason legacy-wrapper --wait $secs"
    else
        SNT_ARGV="request $act --source $src --reason legacy-wrapper --wait $secs"
    fi
    want_notice="CAM_RECOVERY_SUBMITTED id=$SNT_ID type=$act (waiting up to ${secs}s)"
    want_result="CAM_RECOVERY_RESULT id=$SNT_ID type=$act status=SUCCEEDED rc=0"
    write_stub "$STUB_OK"

    for envmode in bare inherit; do
        # stderr on a file: exit code, exact stdout, and exactly one notice.
        set +e
        if [ "$envmode" = bare ]; then
            env -i PATH="$PATH" PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV \
                > "$WORK/cli.out" 2> "$WORK/cli.err"
        else
            PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV > "$WORK/cli.out" 2> "$WORK/cli.err"
        fi
        cli_rc=$?
        set -e
        cli_notices=$(grep -c '^CAM_RECOVERY_SUBMITTED ' "$WORK/cli.err" || true)
        cell="$act/$src wait $secs env=$envmode"
        [ "$cli_rc" -eq 0 ] || fail "$cell file: expected rc 0, got $cli_rc"
        [ "$cli_notices" -eq 1 ] || fail "$cell file: expected one notice, saw $cli_notices"
        grep -qF "$want_notice" "$WORK/cli.err" \
            || { echo "FAIL: $cell file: wrong or missing notice" >&2
                 sed 's/^/  /' "$WORK/cli.err" >&2; exit 1; }
        [ "$(cat "$WORK/cli.out")" = "$want_result" ] \
            || fail "$cell file: stdout was $(cat "$WORK/cli.out")"

        # stderr on a terminal: both streams land on the pty, so check both lines there.
        if [ "$envmode" = bare ]; then
            script -qec 'env -i PATH="$PATH" PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV' \
                /dev/null > "$WORK/pty.raw" 2>&1 || true
        else
            script -qec 'PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV' \
                /dev/null > "$WORK/pty.raw" 2>&1 || true
        fi
        tr -d '\r' < "$WORK/pty.raw" > "$WORK/pty.txt"
        grep -qF "$want_notice" "$WORK/pty.txt" \
            || { echo "FAIL: $cell tty: no submission notice on the terminal" >&2
                 sed 's/^/  /' "$WORK/pty.txt" >&2; exit 1; }
        grep -qF "$want_result" "$WORK/pty.txt" \
            || { echo "FAIL: $cell tty: no result line on the terminal" >&2
                 sed 's/^/  /' "$WORK/pty.txt" >&2; exit 1; }
    done
done 3<<'SHAPES'
request gstapp_stop 120 legacy-kill-test
request gstapp_restart 120 legacy-start-cam
request gstapp_restart 120 legacy-restart-app
request module_reload 300 legacy-init-cam
request camera_hard_reset 300 legacy-cam-hard-reset
apply-config apply_config 300 operator-runbook-example
SHAPES

# The rows above carry the coverage this change leans on hardest, and nothing in a
# `while read` loop fails when it never runs: an empty, truncated or drained heredoc
# would delete every wrapper-shape assertion and still print PASS.  That has already
# happened here once - script(1) in the body read the heredoc off stdin, so only the
# first row ran - so the count is asserted rather than assumed.
[ "$SNT_ROWS" -eq 6 ] \
    || fail "the production-shape table should drive 6 rows, drove $SNT_ROWS"

# --- 1d: no --wait at all ---
# The runbook says a submission without --wait prints no notice and only the request id
# on stdout.  Every drive above passes a --wait, so that sentence had no witness and a
# notice added to the no-wait branch went unnoticed; the wrappers take that branch under
# --no-wait, so the negative is worth pinning.
write_stub "$STUB_OK"
set +e
env -i PATH="$PATH" PIM_LIB="$SNT_LIB" "$SNT_CTL" request gstapp_stop \
    --source legacy-kill-test --reason legacy-wrapper \
    > "$WORK/nw.out" 2> "$WORK/nw.err"
nw_rc=$?
set -e
[ "$nw_rc" -eq 0 ] || fail "a no-wait submission should return 0, got $nw_rc"
[ "$(cat "$WORK/nw.out")" = "$SNT_ID" ] \
    || fail "a no-wait submission should print only the request id, got $(cat "$WORK/nw.out")"
nw_notices=$(grep -c '^CAM_RECOVERY_SUBMITTED ' "$WORK/nw.err" || true)
[ "$nw_notices" -eq 0 ] \
    || { echo "FAIL: a no-wait submission printed $nw_notices submission notices" >&2
         sed 's/^/  /' "$WORK/nw.err" >&2; exit 1; }

# --- 2: cam_enable.sh passes no positional delay to start_cam.sh ---
# start_cam.sh's compatibility path counts a positional and forwards only the
# recovery request - legacy_wrapper_test.sh already pins that forwarding shape - so
# the value never reached anything.  The effective delay comes from the runtime
# document via cam_runtime_app_delay.
# Count, do not merely find: requiring that *an* argument-free call exists lets a second
# line keep the positional and still pass.  Every uncommented invocation must be bare.
CE="$ROOT/dist/pim/opt/pim/bin/cam_enable.sh"
ce_calls=$(grep -cE '^[[:space:]]*[^#[:space:]].*start_cam\.sh' "$CE" || true)
ce_bare=$(grep -cE '^[[:space:]]*/opt/pim/bin/start_cam\.sh[[:space:]]*$' "$CE" || true)
[ "$ce_bare" -ge 1 ] || fail 'cam_enable.sh does not call start_cam.sh without arguments'
[ "$ce_calls" -eq "$ce_bare" ] \
    || fail "cam_enable.sh has $ce_calls start_cam.sh invocations but only $ce_bare without arguments"
if grep -q 'CAM_APP_PLAY_DELAY_SEC_DEFAULT' "$CE"; then
    fail 'cam_enable.sh still reads a delay it cannot forward'
fi

# --- 3: request 의 ACTION 별칭이 정규명으로 바뀌어 전달된다 ---
# 별칭은 CLI 진입점에서만 해석된다.  아래로는 정규명만 흐르므로 lib 의 _cr_request_type,
# 에스컬레이션 case, cam_execute_recovery_request 의 거부 목록은 바뀌지 않았다.
#
# 추출한 함수를 부르지 않고 실제 프로그램을 돌린다 — 매핑 표가 맞아도 호출부가 그 결과를
# 쓰지 않으면 함수 본문만 읽는 검사는 통과한다.  스터브 lib 의 _cr_request_type 은 정규명만
# 받으므로, 정규화를 없애면 별칭 호출이 exit 64 로 떨어져 여기서 실패한다.
ALIAS_LIB="$WORK/alias-lib"
mkdir -p "$ALIAS_LIB"
cat > "$ALIAS_LIB/cam_recovery.sh" <<'SH'
_cr_request_type() {
    case "$1" in
        gstapp_restart|gstapp_stop|module_reload|camera_hard_reset|reboot_fallback|apply_config) return 0;;
    esac
    return 1
}
cam_request_submit() {
    printf '%s\n' "$1" >> "$ALIAS_SEEN"
    printf '%s\n' "$ALIAS_ID"
}
SH
export ALIAS_SEEN="$WORK/alias.seen" ALIAS_ID='11111111-2222-3333-4444-555555555555'
RCTL="$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl"

alias_case() {
    local given=$1 want=$2 out rc
    : > "$ALIAS_SEEN"
    set +e
    out=$(PIM_LIB="$ALIAS_LIB" "$RCTL" request "$given" \
        --source alias-test --reason alias-test 2>/dev/null)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "request $given exited $rc; the alias never reached submit"
    [ "$out" = "$ALIAS_ID" ] || fail "request $given printed [$out], want the request id"
    [ "$(cat "$ALIAS_SEEN")" = "$want" ] \
        || fail "request $given submitted [$(cat "$ALIAS_SEEN")], want $want"
}

alias_case restart gstapp_restart
alias_case stop    gstapp_stop
alias_case module  module_reload
alias_case hard    camera_hard_reset
alias_case reboot  reboot_fallback

# 전체 이름도 그대로 통해야 한다 — 기존 래퍼 다섯이 전체 이름을 보내고
# legacy_wrapper_test.sh 가 그 문자열을 정확히 고정한다.
alias_case gstapp_restart    gstapp_restart
alias_case gstapp_stop       gstapp_stop
alias_case module_reload     module_reload
alias_case camera_hard_reset camera_hard_reset
alias_case reboot_fallback   reboot_fallback

# 별칭도 정규명도 아닌 토큰은 거부된다.  오타를 흡수해 다른 action 으로 보내면 안 된다.
for bogus in bogus_action restar rebooot stopp ''; do
    : > "$ALIAS_SEEN"
    set +e
    PIM_LIB="$ALIAS_LIB" "$RCTL" request "$bogus" \
        --source alias-test --reason alias-test >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 64 ] || fail "request '$bogus' exited $rc instead of 64"
    [ ! -s "$ALIAS_SEEN" ] || fail "request '$bogus' submitted [$(cat "$ALIAS_SEEN")]"
done

# 후행 개행이 붙은 토큰은 정규화를 거쳐도 거부돼야 한다.  정규화 결과를 $(...) 로 받으면
# 명령 치환이 그 개행을 깎아서, 전에는 _cr_request_type 이 거부했던 $'reboot_fallback\n' 이
# 정규명으로 통과해 재부팅을 제출한다.  인자는 $'...' 로 만든다 — $(printf ...) 로 만들면
# 개행이 스크립트에 닿기 전에 깎여 이 검사가 조용히 무의미해진다.
for nl_token in $'reboot_fallback\n' $'camera_hard_reset\n' $'reboot\n' $'hard\n'; do
    : > "$ALIAS_SEEN"
    set +e
    PIM_LIB="$ALIAS_LIB" "$RCTL" request "$nl_token" \
        --source alias-test --reason alias-test >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 64 ] || fail "a token with a trailing newline exited $rc instead of 64"
    [ ! -s "$ALIAS_SEEN" ] \
        || fail "a token with a trailing newline submitted [$(cat "$ALIAS_SEEN")]"
done

# apply_config 는 request 로 보낼 수 없고 별칭도 두지 않았다.
: > "$ALIAS_SEEN"
set +e
PIM_LIB="$ALIAS_LIB" "$RCTL" request apply_config \
    --source alias-test --reason alias-test >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 64 ] || fail "request apply_config exited $rc instead of 64"
[ ! -s "$ALIAS_SEEN" ] || fail 'request apply_config reached submit'

# usage 가 다섯 별칭을 전부 적어야 한다.  적지 않으면 호출자는 알 수 없다.
alias_usage=$(PIM_LIB="$ALIAS_LIB" "$RCTL" 2>&1 >/dev/null || true)
for a in restart stop module hard reboot; do
    printf '%s' "$alias_usage" | grep -q "($a)" || fail "usage does not document the $a alias"
done
# 에스컬레이션이 usage 에 남아 있어야 한다 — 이것이 없으면 module 요청자가 재부팅을
# 예상할 수 없다.
printf '%s' "$alias_usage" | grep -q 'camera_hard_reset -> reboot_fallback' \
    || fail 'usage does not state the module_reload escalation'

echo 'submission notice, cam_enable delay, action aliases: PASS'
