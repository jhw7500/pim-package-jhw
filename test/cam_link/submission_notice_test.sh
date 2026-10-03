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
#
# 이 네 셀이 다루는 축은 **isatty(1) 과 isatty(2) 의 불리언 조합**뿐이다.  TERM 값,
# 창 크기(TIOCGWINSZ), job control 처럼 pty 의 다른 성질에 키를 둔 가드는 네 셀로도
# 못 잡는다 — script(1) 이 실제 pty 를 주므로 isatty 는 참이지만 그 pty 가 운영자
# 세션과 같게 보이는지는 별개다.  지금 cam-recoveryctl 에는 터미널 검사가 아예 없어서
# (grep -E '-t [0-9]|isatty|TIOCGWINSZ|SIGWINCH' 가 0건) 이 셀들은 현재 가드의 검증이
# 아니라 미래 가드에 대한 회귀 방지다.  범위를 넓히는 것은 지금 과잉이고, 이 경계를
# 적어 두는 것은 다음 사람이 네 셀을 "완전한 터미널 시뮬레이션"으로 읽지 않게 하려는
# 것이다.
command -v script >/dev/null 2>&1 \
    || fail 'script(1) is required to drive the notice with stderr on a terminal'
export SNT_ARGV=''
SNT_ROWS=0
SNT_DRIVEN=''

# fd 3, not stdin: script(1) inside the body reads stdin, and on stdin this heredoc is
# drained after the first row - a measured 1 of 6 rows ran before this was fixed.
while read -r sub act secs src <&3; do
    [ -n "$sub" ] || continue
    SNT_ROWS=$((SNT_ROWS + 1))
    SNT_DRIVEN="$SNT_DRIVEN$sub $act $secs $src
"
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
        # script -e 는 자식의 종료코드를 그대로 돌려준다.  `|| true` 로 버리면 두 줄을
        # 다 찍고 nonzero 로 끝나는 tty 전용 회귀가 이 셀을 통과한다 (Codex 지적).
        # 파일 셀이 이미 rc 0 을 어서트하므로 tty 셀도 같은 수준으로 맞춘다.
        set +e
        if [ "$envmode" = bare ]; then
            script -qec 'env -i PATH="$PATH" PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV' \
                /dev/null > "$WORK/pty.raw" 2>&1
        else
            script -qec 'PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV' \
                /dev/null > "$WORK/pty.raw" 2>&1
        fi
        pty_rc=$?
        set -e
        [ "$pty_rc" -eq 0 ] || fail "$cell tty: expected rc 0, got $pty_rc"
        tr -d '\r' < "$WORK/pty.raw" > "$WORK/pty.txt"
        # grep -qF 만 보면 **stderr 가 터미널일 때만** 알림을 한 번 더 찍는 회귀가
        # 통과한다 — 파일 셀의 개수는 1 로 남기 때문이다 (Codex 지적, 실측: 변이본이
        # tty 2회 / file 1회인데 이 스위트가 rc 0 으로 통과했다).  mixed-B 가 이미
        # 개수를 세므로 터미널이 받는 나머지 두 셀도 같은 수준으로 맞춘다.
        pty_notices=$(grep -c '^CAM_RECOVERY_SUBMITTED ' "$WORK/pty.txt" || true)
        [ "$pty_notices" -eq 1 ] \
            || { echo "FAIL: $cell tty: expected one notice, saw $pty_notices" >&2
                 sed 's/^/  /' "$WORK/pty.txt" >&2; exit 1; }
        grep -qF "$want_notice" "$WORK/pty.txt" \
            || { echo "FAIL: $cell tty: no submission notice on the terminal" >&2
                 sed 's/^/  /' "$WORK/pty.txt" >&2; exit 1; }
        # 결과줄도 같은 보호가 필요하다.  결과줄이 **파일**로 가는 두 셀(file, mixed-A)은
        # 전체 내용 정확 비교라 중복이 자동으로 걸리지만, **pty** 로 가는 두 셀(여기와
        # mixed-B)은 grep -qF 존재 확인뿐이었다.  그래서 stdout 이 터미널일 때만 결과줄을
        # 중복하는 회귀가 통과한다 — stdout 계약은 한 줄인데도 (Codex 재현 확인).
        # pty 캡처는 에코 등 다른 바이트가 섞여 전체 일치를 쓸 수 없으므로 알림과 같은
        # 카운트 방식을 쓴다.
        pty_results=$(grep -c '^CAM_RECOVERY_RESULT ' "$WORK/pty.txt" || true)
        [ "$pty_results" -eq 1 ] \
            || { echo "FAIL: $cell tty: expected one result line, saw $pty_results" >&2
                 sed 's/^/  /' "$WORK/pty.txt" >&2; exit 1; }
        grep -qF "$want_result" "$WORK/pty.txt" \
            || { echo "FAIL: $cell tty: no result line on the terminal" >&2
                 sed 's/^/  /' "$WORK/pty.txt" >&2; exit 1; }

        # 혼합 스트림: 두 셀 다 '양쪽이 같은 종류'가 아니다.  위 두 셀은 둘 다 파일이거나
        # 둘 다 pty 여서, **stderr 만 터미널**일 때(또는 그 반대) 알림을 숨기는 가드가
        # 살아남는다 (PR #115 advisory, reviewer B, MEDIUM).  운영자가 파이프로 거르는
        # `cam-recoveryctl ... 2>&1 | tee` 류가 정확히 이 모양이다.
        #
        # script(1) 안에서 한쪽만 리다이렉트하면 나머지는 pty 에 남는다.
        # A: stdout 은 파일, stderr 는 터미널 -> 알림은 pty, 결과줄은 파일
        : > "$WORK/mixA.out"
        set +e
        if [ "$envmode" = bare ]; then
            script -qec 'env -i PATH="$PATH" PIM_LIB="$SNT_LIB" WORK="$WORK" "$SNT_CTL" $SNT_ARGV > "$WORK/mixA.out"' \
                /dev/null > "$WORK/mixA.raw" 2>&1
        else
            script -qec 'PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV > "$WORK/mixA.out"' \
                /dev/null > "$WORK/mixA.raw" 2>&1
        fi
        mixa_rc=$?
        set -e
        [ "$mixa_rc" -eq 0 ] \
            || fail "$cell mixed(out=file,err=tty): expected rc 0, got $mixa_rc"
        tr -d '\r' < "$WORK/mixA.raw" > "$WORK/mixA.tty"
        mixa_notices=$(grep -c '^CAM_RECOVERY_SUBMITTED ' "$WORK/mixA.tty" || true)
        [ "$mixa_notices" -eq 1 ] \
            || { echo "FAIL: $cell mixed(out=file,err=tty): expected one notice, saw $mixa_notices" >&2
                 sed 's/^/  /' "$WORK/mixA.tty" >&2; exit 1; }
        grep -qF "$want_notice" "$WORK/mixA.tty" \
            || { echo "FAIL: $cell mixed(out=file,err=tty): no notice on the terminal" >&2
                 sed 's/^/  /' "$WORK/mixA.tty" >&2; exit 1; }
        [ "$(tr -d '\r' < "$WORK/mixA.out")" = "$want_result" ] \
            || fail "$cell mixed(out=file,err=tty): stdout was $(tr -d '\r' < "$WORK/mixA.out")"

        # B: stderr 는 파일, stdout 은 터미널 -> 알림은 파일, 결과줄은 pty
        : > "$WORK/mixB.err"
        set +e
        if [ "$envmode" = bare ]; then
            script -qec 'env -i PATH="$PATH" PIM_LIB="$SNT_LIB" WORK="$WORK" "$SNT_CTL" $SNT_ARGV 2> "$WORK/mixB.err"' \
                /dev/null > "$WORK/mixB.raw" 2>&1
        else
            script -qec 'PIM_LIB="$SNT_LIB" "$SNT_CTL" $SNT_ARGV 2> "$WORK/mixB.err"' \
                /dev/null > "$WORK/mixB.raw" 2>&1
        fi
        mixb_rc=$?
        set -e
        [ "$mixb_rc" -eq 0 ] \
            || fail "$cell mixed(out=tty,err=file): expected rc 0, got $mixb_rc"
        tr -d '\r' < "$WORK/mixB.raw" > "$WORK/mixB.tty"
        mixb_notices=$(tr -d '\r' < "$WORK/mixB.err" | grep -c '^CAM_RECOVERY_SUBMITTED ' || true)
        [ "$mixb_notices" -eq 1 ] \
            || { echo "FAIL: $cell mixed(out=tty,err=file): expected one notice, saw $mixb_notices" >&2
                 sed 's/^/  /' "$WORK/mixB.err" >&2; exit 1; }
        grep -qF "$want_notice" "$WORK/mixB.err" \
            || { echo "FAIL: $cell mixed(out=tty,err=file): wrong or missing notice" >&2
                 sed 's/^/  /' "$WORK/mixB.err" >&2; exit 1; }
        mixb_results=$(grep -c '^CAM_RECOVERY_RESULT ' "$WORK/mixB.tty" || true)
        [ "$mixb_results" -eq 1 ] \
            || { echo "FAIL: $cell mixed(out=tty,err=file): expected one result line, saw $mixb_results" >&2
                 sed 's/^/  /' "$WORK/mixB.tty" >&2; exit 1; }
        grep -qF "$want_result" "$WORK/mixB.tty" \
            || { echo "FAIL: $cell mixed(out=tty,err=file): no result line on the terminal" >&2
                 sed 's/^/  /' "$WORK/mixB.tty" >&2; exit 1; }
    done
done 3<<'SHAPES'
request gstapp_stop 120 legacy-kill-test
request gstapp_restart 120 legacy-start-cam
request gstapp_restart 120 legacy-restart-app
request module_reload 300 legacy-init-cam
request camera_hard_reset 300 legacy-cam-hard-reset

apply-config apply_config 300 operator
request gstapp_restart 120 operator
request gstapp_stop 120 operator
request module_reload 300 operator
request camera_hard_reset 300 operator
request gstapp_restart 120 operator-manual-test
SHAPES

# The rows above carry the coverage this change leans on hardest, and nothing in a
# `while read` loop fails when it never runs: an empty, truncated or drained heredoc
# would delete every wrapper-shape assertion and still print PASS.  That has already
# happened here once - script(1) in the body read the heredoc off stdin, so only the
# first row ran - so the count is asserted rather than assumed.
[ "$SNT_ROWS" -eq 11 ] \
    || fail "the production-shape table should drive 11 rows, drove $SNT_ROWS"

# 행 수만 고정하면 내용은 자유롭다 — action, wait, source 중 무엇을 바꿔도 11 은 11 이다
# (PR #115 advisory, reviewer B, LOW).  그 세 값이 바로 가드가 키로 쓸 수 있는 값이므로
# 구동한 shape 집합을 그대로 못박는다.
#
# 앞 다섯은 dist/ 래퍼 모양이고, 뒤 여섯은 런북이 운영자에게 **실제로 타라고 적은** 명령
# 전부다 (cam-recovery-operations.md 의 apply-config + request 네 개, 그리고 수동 runtime
# 편집 절차의 operator-manual-test).  운영자 모양을 하나만 두면
# `apply_config`/`operator` 나 `gstapp_stop`/`operator` 같은 조합에 키를 둔 억제가 모든
# 스트림 모드에서 통과한다 — 문서화된 production 명령인데도 그렇다 (Codex 지적).
# 합성값 operator-runbook-example 은 문서에 없는 값이어서 실제 operator 로 바꿨다.
SNT_EXPECTED='apply-config apply_config 300 operator
request camera_hard_reset 300 legacy-cam-hard-reset
request camera_hard_reset 300 operator
request gstapp_restart 120 legacy-restart-app
request gstapp_restart 120 legacy-start-cam
request gstapp_restart 120 operator
request gstapp_restart 120 operator-manual-test
request gstapp_stop 120 legacy-kill-test
request gstapp_stop 120 operator
request module_reload 300 legacy-init-cam
request module_reload 300 operator'
SNT_GOT=$(printf '%s' "$SNT_DRIVEN" | LC_ALL=C sort)
[ "$SNT_GOT" = "$SNT_EXPECTED" ] || {
    echo 'FAIL: the production-shape table changed content' >&2
    diff <(printf '%s\n' "$SNT_EXPECTED") <(printf '%s\n' "$SNT_GOT") | sed 's/^/  /' >&2
    exit 1
}

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

# 수용 집합 드리프트(ACTION 이 _cr_public_action 에 추가됐는데 usage 가 안 따라오는 것)를
# 잡는 검사는 두 구현을 시도한 끝에 제거했다. 리뷰 5 라운드에서 지적 6 건이 나왔고 전부
# 그 검사 자신의 결함이었다 — 실제 드리프트를 잡은 적은 없다.
#
# 구조적 이유: 집합을 usage 산문에서 읽으면 포맷 변경에 거짓 실패하고(숫자 든 이름, 두 칸
# 들여쓴 설명줄, 탭 구분자), 함수에서 읽으면 어느 함수를 어디까지 보느냐로 양쪽에 걸린다.
# declare -f 전체 비교는 동작이 같은 리팩터(패턴 재배열, *) return 1;; 로 이동)에 거짓
# 실패하고, 그렇다고 _cr_public_action 만 보면 CLI 가 실제로 쓰는 _cr_request_type 에
# 예외가 붙는 경로를 놓친다(둘 다 실측 확인). 조이면 거짓 실패, 풀면 거짓 통과다.
#
# Codex 는 집합을 프로덕션에 기계가 읽을 선언으로 두자고 제안했는데, 이 파일 머리말의
# "테스트를 위한 프로덕션 seam 을 더하지 않는다"와 어긋나므로 택하지 않았다.
#
# 드리프트는 리뷰가 잡는다 — action 을 더하면 _cr_public_action, 에스컬레이션 case,
# cam_execute_recovery_request 세 곳을 동시에 건드려야 하고, 그 diff 를 보는 리뷰어는
# usage 도 본다. 이 PR 자체가 그 증거다.

echo 'submission notice, cam_enable delay, action aliases: PASS'
