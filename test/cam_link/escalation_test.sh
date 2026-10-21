#!/bin/bash
# chk_cam_operate.sh 의 disconnect 에스컬레이션(maybe_init_cam_on_disconnect) 검증
# 사용법: bash test/cam_link/escalation_test.sh
#
# 배경: cam_disconnect_flag != 0 경로는 retry/retry_boot 를 증가시키지 않아 상한 없이
# init_cam 을 반복한다(1호기 로그 17:53~18:04, 11분간 8회). DISCONNECT_MAX_SEC 로
# 시간 상한을 두되 기본값 0(비활성)이라 "Never reboot in disconnect state" 원칙은 유지된다.
# 활성화 시 리부팅 반복 여부는 DISCONNECT_REBOOT_FLAG_DIR 로 정한다 — 기본 /tmp 는
# 부팅 시 지워져 반복 리부팅, 영구 경로로 두면 1회로 묶인다. 플래그를 못 쓰면
# 이력이 남지 않아 리부팅 루프가 되므로 어느 쪽이든 리부팅하지 않는다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
FN="$WORK/maybe_fn.sh"
trap 'rm -rf "$WORK"' EXIT
t_extract_func "$PIM_BIN/chk_cam_operate.sh" maybe_init_cam_on_disconnect "$FN" || exit 1

# $1=설명 $2=max_sec $3=disconnect 경과초 $4=file_chk_reboot $5=플래그 선존재(Y/N)
# $6=기대(REBOOT|NONE) $7=플래그 디렉터리(선택, 쓰기 실패 시나리오용)
run_b() {
    local out rc got
    out=$(
        KEY=RST; tag=chk_cam_operate.sh; ENABLE_VAL="true"
        DISCONNECT_INIT_CAM_GRACE_SEC=60
        DISCONNECT_INIT_CAM_INTERVAL_SEC=180
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state"
        DISCONNECT_REBOOT_FLAG_DIR="${7:-$WORK/flagdir}"
        DISCONNECT_REBOOT_FLAG="$DISCONNECT_REBOOT_FLAG_DIR/reboot.flag"
        DISCONNECT_MAX_SEC="$2"
        file_chk_reboot="$4"
        init_cooldown_sec=40
        NOW=1800000000

        mkdir -p "$DISCONNECT_REBOOT_FLAG_DIR" 2>/dev/null
        rm -f "$DISCONNECT_REBOOT_FLAG"
        [ "$5" = "Y" ] && printf '1' > "$DISCONNECT_REBOOT_FLAG"
        # last_init 을 now 로 두어 주기 init_cam 분기(실제 /opt/pim/bin/init_cam.sh 호출)에
        # 들어가지 않게 한다. 에스컬레이션 판정은 그 앞에서 이뤄지므로 영향 없다.
        printf "%s,%s" "$((NOW - $3))" "$NOW" > "$DISCONNECT_INIT_CAM_STATE_FILE"

        get_cam_disconnect_flag() { echo 1; }   # disconnect 상태로 고정
        read_driver_disconnect()  { echo 0; }
        in_init_cooldown()        { return 1; }
        cam_in_init_cooldown()    { return 1; }
        date()   { echo "$NOW"; }
        sync()   { :; }
        sleep()  { :; }
        cam_submit_internal_action() {
            [ "$1" = reboot_fallback ] && echo "REBOOT_CALLED"
            return 0
        }
        logger() { :; }
        # shellcheck disable=SC1090
        source "$FN"
        maybe_init_cam_on_disconnect                 # 반드시 1회만 호출
    ) 2>&1
    got="NONE"; grep -q REBOOT_CALLED <<<"$out" && got="REBOOT"
    t_eq "$1" "$got" "$6"
}

echo "=== disconnect 에스컬레이션 ==="
run_b "기본값 0 → 비활성(기존 동작 유지)"   0    99999 true  N NONE
run_b "활성, 경과 < 상한 → 리부팅 없음"     1800 100   true  N NONE
run_b "활성, 경과 >= 상한 → 에스컬레이션"   1800 1900  true  N REBOOT
run_b "같은 부팅 안에서 재진입 → 중복 리부팅 없음" 1800 5000  true  Y NONE
run_b "file_check_reboot=false → 리부팅 없음" 1800 1900  false N NONE
run_b "max_sec 비정상값(공백) → 안전측 비활성" ""  99999 true  N NONE
# 플래그를 못 쓰면 이력이 남지 않아 리부팅 루프가 되므로 건너뛰어야 한다.
# 쓰기 실패는 '일반 파일 하위 경로'로 만든다 — mkdir 이 ENOTDIR 로 실패하며,
# 퍼미션 비트를 무시하는 root 로 실행해도 동일하게 실패한다(readonly 디렉터리는
# root 에서 통과해 이 케이스가 조용히 무력화된다).
: > "$WORK/not-a-dir"
run_b "플래그 쓰기 실패 → 리부팅 건너뜀"    1800 1900  true  N NONE "$WORK/not-a-dir/sub"

# #213: gstApp 이 죽은 채 BG 플래그가 0 으로 내려가도 episode 이력을 지우면 안 된다.
# $1=설명 $2=앱 상태(UP|DOWN) $3=상태 파일 선존재(Y/N)
# $4=기대 "state=<KEEP|GONE> flag=<KEEP|GONE> cleared=<Y|N> submit=<Y|N>" — 두 파일을 따로 단언한다.
t_extract_func "$PIM_BIN/chk_cam_operate.sh" cam_app_absent "$WORK/f_app" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" disconnect_episode_open "$WORK/f_ep" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" start_marker_disconnect_path "$WORK/f_sm" || exit 1
run_c() {
    local out got
    out=$(
        KEY=RST; tag=chk_cam_operate.sh
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state_c"
        DISCONNECT_REBOOT_FLAG="$WORK/reboot_c.flag"
        init_cooldown_sec=40
        PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        rm -f "$DISCONNECT_INIT_CAM_STATE_FILE" "$DISCONNECT_REBOOT_FLAG"
        [ "$3" = "Y" ] && printf '1,2' > "$DISCONNECT_INIT_CAM_STATE_FILE"
        printf '1' > "$DISCONNECT_REBOOT_FLAG"
        get_cam_disconnect_flag() { echo 0; }
        read_driver_disconnect()  { echo 0; }
        in_init_cooldown()        { return 1; }
        cam_in_init_cooldown()    { return 1; }
        _cam_runtime_app_into()   { printf -v "$1" '%s' gstApp; }
        pgrep() { [ "$2" = gstApp ] && [ "$APP" = UP ]; }
        cam_submit_internal_action() { echo "SUBMIT:$1"; return 0; }
        logger() { echo "LOG:$*"; }
        APP="$2"
        # shellcheck disable=SC1090
        source "$WORK/f_app"; source "$WORK/f_ep"; source "$FN"
        maybe_init_cam_on_disconnect && echo "RC0" || echo "RC1"
        [ -f "$DISCONNECT_INIT_CAM_STATE_FILE" ] && echo "STATE_KEPT"
        [ -f "$DISCONNECT_REBOOT_FLAG" ] && echo "FLAG_KEPT"
    ) 2>&1
    local s=GONE f=GONE c=N x=N
    grep -q STATE_KEPT <<<"$out" && s=KEEP
    grep -q FLAG_KEPT <<<"$out" && f=KEEP
    grep -q 'disconnect state cleared' <<<"$out" && c=Y
    grep -q 'SUBMIT:' <<<"$out" && x=Y
    got="state=$s flag=$f cleared=$c submit=$x"
    t_eq "$1" "$got" "$4"
}

echo "=== 플래그 0 에서 episode 이력 보존 (#213) ==="
run_c "상태 파일 있음·앱 없음 → 이력 유지, 조치·cleared 로그 없음" DOWN Y "state=KEEP flag=KEEP cleared=N submit=N"
run_c "상태 파일 있음·앱 있음 → 지금처럼 둘 다 지우고 cleared 로그" UP   Y "state=GONE flag=GONE cleared=Y submit=N"
# 상태 파일이 처음부터 없으면 episode 도 없다 — 지금처럼 reboot 플래그를 지운다.
run_c "상태 파일 없음·앱 없음 → 지금처럼 reboot 플래그 지움"      DOWN N "state=GONE flag=GONE cleared=N submit=N"

# $1=설명 $2=플래그 $3=앱 상태 $4=상태 파일 선존재(Y/N) $5=기대(DISC|LADDER)
run_s() {
    local got
    got=$(
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state_s"
        PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        rm -f "$DISCONNECT_INIT_CAM_STATE_FILE"
        [ "$4" = "Y" ] && : > "$DISCONNECT_INIT_CAM_STATE_FILE"
        _cam_runtime_app_into()   { printf -v "$1" '%s' gstApp; }
        pgrep() { [ "$2" = gstApp ] && [ "$APP" = UP ]; }
        APP="$3"
        # shellcheck disable=SC1090
        source "$WORK/f_app"; source "$WORK/f_ep"; source "$WORK/f_sm"
        if start_marker_disconnect_path "$2"; then echo DISC; else echo LADDER; fi
    )
    t_eq "$1" "$got" "$5"
}

echo "=== 시작 마커 부재 경로 판정 (#213) ==="
run_s "플래그 ≠ 0 → 끊김"                          3 DOWN N DISC
run_s "플래그 0·episode 열림(상태 파일+앱 없음) → 끊김" 0 DOWN Y DISC
run_s "플래그 0·상태 파일 있으나 앱 있음 → 일반 사다리" 0 UP   Y LADDER
run_s "플래그 0·episode 없음 → 일반 사다리"         0 DOWN N LADDER
t_eq "시작 마커 경로가 판정 함수를 쓴다" \
     "$(grep -c 'elif ! start_marker_disconnect_path' "$PIM_BIN/chk_cam_operate.sh")" 1

t_summary "에스컬레이션"
