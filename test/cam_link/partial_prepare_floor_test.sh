#!/bin/bash
# chk_cam_operate.sh 의 PARTIAL 기동 뒤 파일검사 사다리 월반(file_check_partial_floor, #223) 검증
# 사용법: bash test/cam_link/partial_prepare_floor_test.sh
#
# 배경: gstApp 은 기동 중 한 CSI 의 MAX9296 prepare 가 거부되면 그 CSI 만 끄고(PARTIAL) 나머지로 녹화한다.
# 같은 전원 epoch 에서는 실패한 CSI 를 다시 cold init 할 수 없고 정상 CSI 의 전원 참조가 앱 재시작을
# 넘어 남아, gstapp_restart 로는 돌아오지 않는다(gstApp#148: .6 에서 3회 모두 errno=-116). 파일검사
# 사다리는 그런 실행에서 gstapp_restart 구간을 건너뛰고 module_reload 단계 하한으로 올라야 한다.
# 판정은 지금 떠 있는 앱 pid 가 쓴 health 스냅샷의 reason_detail 접두로만 한다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CHK="$PIM_BIN/chk_cam_operate.sh"
t_extract_func "$CHK" file_check_partial_floor "$WORK/floor.sh" || exit 1

# snap <pid> <ch2 reason_detail(빈 값=설정상 끈 채널)> [ch2 code] [schema 값(none=키 없음)]
# ch0·ch1 은 정상, ch2·ch3 은 끈 채널. schema 기본값은 gstApp 이 쓰는 정수 1 이다.
snap() {
    local reason=$2 code=${3:-DISABLED} detail="" schema_kv="\"schema\":${4:-1},"
    [ "${4-}" = none ] && schema_kv=""
    [ -n "$reason" ] && detail=",\"reason_detail\":\"$reason\""
    local off_g="\"status\":\"N/A\",\"code\":\"$code\",\"count\":0,\"evidence\":[{\"name\":\"configured\",\"source\":\"gstApp\",\"value\":$([ -n "$reason" ] && echo true || echo false)}]$detail"
    cat > "$WORK/run/gstApp.json" <<EOF
{${schema_kv}"producer":"gstApp","boot_id":"b","pid":$1,"sequence":7,"status":"OK","observations":[
 {"block":"gstreamer","scope":{"kind":"channel","id":"ch0","channels":[0]},"status":"OK","code":"NONE","count":0,"evidence":[]},
 {"block":"gstreamer","scope":{"kind":"channel","id":"ch1","channels":[1]},"status":"OK","code":"NONE","count":0,"evidence":[]},
 {"block":"gstreamer","scope":{"kind":"channel","id":"ch2","channels":[2]},$off_g},
 {"block":"recording","scope":{"kind":"channel","id":"ch2","channels":[2]},$off_g},
 {"block":"gstreamer","scope":{"kind":"channel","id":"ch3","channels":[3]},$off_g},
 {"block":"recording","scope":{"kind":"channel","id":"ch3","channels":[3]},$off_g}
]}
EOF
}

# run_f <설명> <앱 pid 들(pgrep 결과)> <retry> <retry_boot> <기대 rc> <기대 retry_total> <기대 retry> <빠진 채널...>
# 스냅샷은 호출 전에 snap 으로 만든다(없애려면 rm). 로그는 $WORK/log 에 남는다.
run_f() {
    local desc=$1 pids=$2 out rc total r
    shift 2
    local want_rc=$3 want_total=$4 want_retry=$5 r0=$1 b0=$2
    shift 5
    out=$(
        KEY=RST; tag=chk_cam_operate.sh
        PIM_CAMERA_RUN_DIR="$WORK/run"; PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        PIDS="$pids"
        _cam_runtime_app_into() { printf -v "$1" '%s' gstApp; }
        pgrep() { [ "$1" = -x ] && [ "$2" = gstApp ] && [ -n "$PIDS" ] && printf '%s\n' $PIDS; }
        logger() { printf '%s\n' "$*" >> "$WORK/log"; }
        source "$WORK/floor.sh"
        retry=$r0; retry_boot=$b0; retry_total=$((retry + retry_boot))
        file_check_partial_floor "$@"; rc=$?
        printf '%s %s %s\n' "$rc" "$retry_total" "$retry"
    )
    read -r rc total r <<<"$out"
    t_eq "$desc (rc)" "$rc" "$want_rc"
    t_eq "$desc (retry_total)" "$total" "$want_total"
    t_eq "$desc (retry)" "$r" "$want_retry"
}

mkdir -p "$WORK/run"

echo "=== 월반하는 경우 ==="
snap 4242 "MAX9296 prepare failed (errno=-5)"
: > "$WORK/log"
run_f "현재 앱이 ch2·ch3 을 끄고 떴고 그 채널이 빠짐, 첫 실패" 4242   1 0  0 4 4  ch2 ch3
grep -q 'skip gstapp_restart' "$WORK/log"; t_eq "월반 이유가 local0 에 남는다" "$?" 0
grep -q 'ch2,ch3' "$WORK/log"; t_eq "로그에 월반 근거 채널이 남는다" "$?" 0
run_f "retry_boot 가 있어도 합계를 4 로 맞춘다"                      4242   1 2  0 4 2  ch2 ch3
run_f "빠진 채널 일부만 겹쳐도 월반"                                 4242   2 0  0 4 4  ch0 ch3
run_f "앱 pid 가 여럿이어도 스냅샷 pid 가 그중 하나면 월반"          "9 4242" 1 0  0 4 4  ch2
snap 4242 "MAX9296 prepare failed (errno=-116)" BLOCKED
run_f "code 가 바뀌어도(#222) reason_detail 접두로 월반"             4242   1 0  0 4 4  ch2 ch3

echo "=== 월반하지 않는 경우(기존 사다리 그대로) ==="
snap 4242 "MAX9296 prepare failed (errno=-5)"
run_f "이전 실행이 쓴 스냅샷(pid 불일치)"                            5555   1 0  1 1 1  ch2 ch3
run_f "앱이 떠 있지 않음"                                            ""     1 0  1 1 1  ch2 ch3
run_f "빠진 채널이 끈 채널과 겹치지 않음"                            4242   1 0  1 1 1  ch0
run_f "이미 module_reload 구간(retry_total=4)"                       4242   4 0  1 4 4  ch2 ch3
run_f "reboot 구간(retry_total=6)은 손대지 않는다"                    4242   6 0  1 6 6  ch2 ch3
snap 4242 "VideoBin build failed"
run_f "다른 기동 실패 사유"                                          4242   1 0  1 1 1  ch2 ch3
snap 4242 ""
run_f "설정상 끈 채널(reason_detail 없음)"                           4242   1 0  1 1 1  ch2 ch3
# 알 수 없는 schema 는 정상으로 해석하지 않는다(docs/camera-health/health-contract-v1.md §2).
snap 4242 "MAX9296 prepare failed (errno=-5)" DISABLED 99
run_f "알 수 없는 schema(99)"                                        4242   1 0  1 1 1  ch2 ch3
snap 4242 "MAX9296 prepare failed (errno=-5)" DISABLED '"camera-health.v1"'
run_f "schema 가 정수 1 이 아님(문자열)"                             4242   1 0  1 1 1  ch2 ch3
snap 4242 "MAX9296 prepare failed (errno=-5)" DISABLED none
run_f "schema 없음"                                                  4242   1 0  1 1 1  ch2 ch3
rm -f "$WORK/run/gstApp.json"
run_f "스냅샷 없음"                                                  4242   1 0  1 1 1  ch2 ch3
printf 'not json' > "$WORK/run/gstApp.json"
run_f "스냅샷이 JSON 이 아님"                                        4242   1 0  1 1 1  ch2 ch3

echo "=== 사다리 호출 위치 ==="
# 파일검사 사다리(끊김 플래그 0 분기)의 retry_total 계산과 gstapp_restart 판정 사이에서 한 번만 부른다.
# 기동 마커 누락 사다리는 PARTIAL 과 무관하므로 부르지 않는다.
calls=$(grep -n 'file_check_partial_floor "${missing_chs\[@\]}"' "$CHK" | cut -d: -f1)
t_eq "호출 지점은 하나" "$(printf '%s\n' "$calls" | grep -c .)" 1
req=$(grep -n 'next: module_reload at total>3' "$CHK" | head -1 | cut -d: -f1)
tot=$(awk -v n="$req" 'NR < n && /retry_total=\$\(\(\$retry\+\$retry_boot\)\)/ { l = NR } END { print l }' "$CHK")
disc=$(awk -v n="$req" 'NR < n && /if \(\( cam_disconnect_flag == 0x0 \)\); then/ { l = NR } END { print l }' "$CHK")
order=no
[ -n "$calls" ] && [ -n "$req" ] && [ -n "$tot" ] && [ -n "$disc" ] &&
    [ "$disc" -lt "$tot" ] && [ "$tot" -lt "$calls" ] && [ "$calls" -lt "$req" ] && order=yes
t_eq "끊김 0 분기 안, retry_total 계산 뒤·gstapp_restart 판정 앞" "$order" yes

t_summary "PARTIAL 월반"
