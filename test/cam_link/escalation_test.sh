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
# $1=설명 $2=앱 상태(UP|DOWN|ERR) $3=상태 파일 선존재(Y/N)
# $4=기대 "state=<KEEP|GONE> mark=<-|held|kept|held,kept> flag=<KEEP|GONE> cleared=<Y|N> submit=<Y|N> error=<Y|N> log=<Y|N>"
# — 두 파일을 따로 단언한다. mark 는 상태 파일의 표시, log 는 보존 로그다. BG 측정 여부(#216)는 호출 앞
# 환경 변수로 준다(기본은 재생 중): MK=P|A|E 시작 마커 있음·없음·빈 파일, R2/R1=i2c2(ch0/1)·i2c1(ch2/3)
# link_status 원시값(none=파일 없음), EN=<csi1><csi2> 활성(기본 11), CAP=rec|caponly 녹화 구성(caponly=capture
# 만 켜고 녹화 끔), ST=미리 둔 상태 파일 내용(기본 1,2).
t_extract_func "$PIM_BIN/chk_cam_operate.sh" cam_app_absent "$WORK/f_app" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" disconnect_episode_open "$WORK/f_ep" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" start_marker_disconnect_path "$WORK/f_sm" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" mark_disconnect_episode_held "$WORK/f_held" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" mark_disconnect_episode_kept "$WORK/f_kept" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" cam_link_unmeasured "$WORK/f_um" || exit 1
# run_c·run_f 가 함께 쓰는 BG 측정 상태 준비. $1=파일 접두사
t_link_fixture() {
    FILE_="$WORK/marker_$1"; SYSFS_LINK_I2C2="$WORK/link2_$1"; SYSFS_LINK_I2C1="$WORK/link1_$1"
    rm -f "$FILE_" "$SYSFS_LINK_I2C2" "$SYSFS_LINK_I2C1"
    case "${MK:-P}" in (P) echo "20261021 15:26:00" > "$FILE_" ;; (E) : > "$FILE_" ;; esac
    [ "${R2:-0}" = none ] || printf '%s\n' "${R2:-0}" > "$SYSFS_LINK_I2C2"
    [ "${R1:-0}" = none ] || printf '%s\n' "${R1:-0}" > "$SYSFS_LINK_I2C1"
    EN=${EN:-11}; csi1_en=${EN:0:1}; csi2_en=${EN:1:1}
    ENABLE_VAL="true"; cap_en=false; cap_record_en=false
    [ "${CAP:-rec}" != caponly ] || cap_en=true
}
run_c() {
    local out got
    out=$(
        exec 2>&1
        KEY=RST; tag=chk_cam_operate.sh
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state_c"
        DISCONNECT_REBOOT_FLAG="$WORK/reboot_c.flag"
        init_cooldown_sec=40
        PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        t_link_fixture c
        rm -f "$DISCONNECT_INIT_CAM_STATE_FILE" "$DISCONNECT_REBOOT_FLAG"
        [ "$3" = "Y" ] && printf '%s' "${ST:-1,2}" > "$DISCONNECT_INIT_CAM_STATE_FILE"
        printf '1' > "$DISCONNECT_REBOOT_FLAG"
        get_cam_disconnect_flag() { echo 0; }
        read_driver_disconnect()  { echo 0; }
        _cam_runtime_app_into()   { printf -v "$1" '%s' gstApp; }
        pgrep() { case "$APP" in (UP) [ "$2" = gstApp ] ;; (ERR) return 2 ;; (*) return 1 ;; esac; }
        cam_submit_internal_action() { echo "SUBMIT:$1"; return 0; }
        logger() { echo "LOG:$*"; }
        APP="$2"
        # shellcheck disable=SC1090
        source "$WORK/f_app"; source "$WORK/f_ep"; source "$WORK/f_held"; source "$WORK/f_kept"
        # shellcheck disable=SC1090
        source "$WORK/f_um"; source "$FN"
        maybe_init_cam_on_disconnect && echo "RC0" || echo "RC1"
        [ -f "$DISCONNECT_INIT_CAM_STATE_FILE" ] && echo "STATE_KEPT=$(cat "$DISCONNECT_INIT_CAM_STATE_FILE")"
        [ -f "$DISCONNECT_REBOOT_FLAG" ] && echo "FLAG_KEPT"
    ) 2>&1
    local s=GONE f=GONE c=N x=N m e=N k=N
    grep -q STATE_KEPT <<<"$out" && s=KEEP
    # 상태 파일의 첫 두 필드(first_seen,last_init) 뒤에 붙은 표시만 남긴다.
    m=$(sed -n 's/^STATE_KEPT=[0-9]*,[0-9]*,\{0,1\}//p' <<<"$out"); m=${m:--}
    grep -q FLAG_KEPT <<<"$out" && f=KEEP
    grep -q 'disconnect state cleared' <<<"$out" && c=Y
    grep -q 'SUBMIT:' <<<"$out" && x=Y
    # 보존 경로가 부르는 도우미가 없으면 셸 오류만 남고 단언은 통과할 수 있으므로 따로 센다.
    grep -q 'command not found' <<<"$out" && e=Y
    grep -q 'disconnect state kept' <<<"$out" && k=Y
    got="state=$s mark=$m flag=$f cleared=$c submit=$x error=$e log=$k"
    t_eq "$1" "$got" "$4"
}

echo "=== 플래그 0 에서 episode 이력 보존 (#213) ==="
run_c "상태 파일 있음·앱 없음 → 이력 유지·보류 표시, 조치·cleared 로그 없음" DOWN Y "state=KEEP mark=held flag=KEEP cleared=N submit=N error=N log=N"
run_c "상태 파일 있음·앱 있음 → 지금처럼 둘 다 지우고 cleared 로그"        UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
# 상태 파일이 처음부터 없으면 episode 도 없다. 그래도 앱이 없으면 BG 는 재지 않았으므로(#216 A-R1-003)
# 재부팅 플래그는 남긴다 — 예전에는 여기서 지웠다.
run_c "상태 파일 없음·앱 없음 → 재지 않은 0 이라 재부팅 플래그 보존"      DOWN N "state=GONE mark=- flag=KEEP cleared=N submit=N error=N log=N"
# pgrep 이 프로세스를 읽지 못하면(rc 2) 앱이 없다고 단정하지 않는다 — 지금처럼 지운다.
run_c "상태 파일 있음·pgrep 오류 → 보존하지 않고 지금처럼 지움"          ERR  Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"

echo "=== BG 가 재지 않은 플래그 0 은 회복이 아니다 (#216) ==="
MK=A run_c "앱 있음·마커 없음 → 이력·재부팅 플래그 보존, 보존 표시"          UP   Y "state=KEEP mark=kept flag=KEEP cleared=N submit=N error=N log=Y"
# 파일 검사는 재생 중 마커를 비운다. 빈 마커는 재생 중이므로 BG 처럼 존재만 본다.
MK=E run_c "앱 있음·빈 마커 → 잰 값이라 지움"                              UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
# module_reload 직후 vcm 이 이전 시각으로 마커를 먼저 쓴다. 활성 버스가 전부 미프로그램(-1)이면 BG 는 재지 않는다.
R2=-1 R1=-1 run_c "마커 있음·활성 버스 모두 -1 → 보존"                      UP   Y "state=KEEP mark=kept flag=KEEP cleared=N submit=N error=N log=Y"
# 한 버스만 -1 이면 BG 는 나머지 버스를 쟀다. 설정만 켠 버스는 영영 -1 이다(#216 A-R1-001).
R2=-1 run_c "마커 있음·i2c2 만 -1 → 다른 버스를 쟀으므로 지움"              UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
R1=-1 run_c "마커 있음·i2c1 만 -1 → 다른 버스를 쟀으므로 지움"              UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
# 한 쌍만 켠 구성: 켠 버스가 -1 이면 잰 버스가 없다. 버스 대응이 뒤바뀌면 아래 넷이 뒤집힌다.
R2=-1 EN=10 run_c "csi1(ch0/1)만 켬·i2c2 -1 → 보존"                       UP   Y "state=KEEP mark=kept flag=KEEP cleared=N submit=N error=N log=Y"
R1=-1 EN=01 run_c "csi2(ch2/3)만 켬·i2c1 -1 → 보존"                       UP   Y "state=KEEP mark=kept flag=KEEP cleared=N submit=N error=N log=Y"
R2=-1 EN=01 run_c "csi1(ch0/1) 꺼짐·i2c2 -1 → 지움"                       UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
R1=-1 EN=10 run_c "csi2(ch2/3) 꺼짐·i2c1 -1 → 지움"                       UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
R2=none R1=none run_c "link_status 파일 없음 → -1 아님(BG 와 같음), 지움"  UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
# 앱 부재는 #213 보류가 먼저 받는다(보류 표시가 붙는다).
MK=A run_c "앱 없음·마커 없음 → #213 보류가 먼저"                          DOWN Y "state=KEEP mark=held flag=KEEP cleared=N submit=N error=N log=N"
MK=A run_c "pgrep 오류·마커 없음 → BG 도 재지 않았으므로 보존"              ERR  Y "state=KEEP mark=kept flag=KEEP cleared=N submit=N error=N log=Y"
# 상태 파일이 없어도 재지 않은 0 으로 재부팅 플래그를 지우지 않는다. 남길 이력이 없으니 로그도 없다.
MK=A run_c "상태 파일 없음·마커 없음 → 재부팅 플래그만 보존"                DOWN N "state=GONE mark=- flag=KEEP cleared=N submit=N error=N log=N"
MK=A run_c "상태 파일 없음·앱 있음·마커 없음 → 재부팅 플래그만 보존"         UP   N "state=GONE mark=- flag=KEEP cleared=N submit=N error=N log=N"
# 이미 보존 중이면 표시를 겹쳐 붙이지 않는다. 보류 뒤 보존이면 두 표시가 함께 남는다(보류의 새 grace 유지).
ST=1,2,kept MK=A run_c "보존 중인 이력·여전히 재지 않음 → 표시 그대로"      UP   Y "state=KEEP mark=kept flag=KEEP cleared=N submit=N error=N log=Y"
ST=1,2,held MK=A run_c "보류 이력·앱 다시 뜸·재지 않음 → 보류+보존"          UP   Y "state=KEEP mark=held,kept flag=KEEP cleared=N submit=N error=N log=Y"
# 녹화 없는 capture 구성은 마커가 생기지 않고 BG 는 드라이버 값만 본다. 마커·앱을 보면 episode 가 닫히지 않는다.
CAP=caponly MK=A run_c "capture 전용·마커 없음 → 마커는 보지 않고 지움"     UP   Y "state=GONE mark=- flag=GONE cleared=Y submit=N error=N log=N"
CAP=caponly MK=A run_c "capture 전용·앱 없음·상태 없음 → 앱은 보지 않고 지움" DOWN N "state=GONE mark=- flag=GONE cleared=N submit=N error=N log=N"
CAP=caponly MK=A R2=-1 R1=-1 run_c "capture 전용·활성 버스 모두 -1 → 보존"  UP   Y "state=KEEP mark=kept flag=KEEP cleared=N submit=N error=N log=Y"

# $1=설명 $2=플래그 $3=앱 상태 $4=상태 파일 선존재(Y/N) $5=기대(DISC|LADDER). ST=상태 파일 내용(기본 빈 파일)
run_s() {
    local got
    got=$(
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state_s"
        PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        rm -f "$DISCONNECT_INIT_CAM_STATE_FILE"
        [ "$4" = "Y" ] && printf '%s' "${ST:-}" > "$DISCONNECT_INIT_CAM_STATE_FILE"
        _cam_runtime_app_into()   { printf -v "$1" '%s' gstApp; }
        pgrep() { case "$APP" in (UP) [ "$2" = gstApp ] ;; (ERR) return 2 ;; (*) return 1 ;; esac; }
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
run_s "플래그 0·상태 파일 있음·pgrep 오류 → 일반 사다리" 0 ERR  Y LADDER
ST=1,2,held run_s "플래그 0·보류(held) 이력·앱 없음 → 끊김" 0 DOWN Y DISC
# #216 AC2: 재지 않은 0 으로 보존 중인 이력은 예전이면 지워졌을 것이다. 시작 마커 경로는 지금처럼 사다리를 탄다.
ST=1,2,kept run_s "플래그 0·보존(kept) 이력·앱 없음 → 일반 사다리"      0 DOWN Y LADDER
ST=1,2,held,kept run_s "플래그 0·보류 뒤 보존 이력·앱 없음 → 일반 사다리" 0 DOWN Y LADDER
t_eq "시작 마커 경로가 판정 함수를 쓴다" \
     "$(grep -c -F 'if ! start_marker_disconnect_path "$cam_disconnect_flag"; then' "$PIM_BIN/chk_cam_operate.sh")" 1

# #213 A-R1-001: 앱이 없는 동안 보존한 episode 는 그 부재 시간을 grace·interval·max_sec 에 넣지 않는다.
# 표본 1개 → 앱 부재(플래그 0) → 부재가 grace 를 넘긴 뒤 표본 1개. master 처럼 새 grace 를 열고 제출하지 않아야 한다.
# $1=설명 $2=max_sec $3=마지막 표본 시각 $4=기대 제출(NONE 또는 action 이름)
run_h() {
    local got
    got=$(
        KEY=RST; tag=chk_cam_operate.sh; ENABLE_VAL="true"; file_chk_reboot=true
        DISCONNECT_INIT_CAM_GRACE_SEC=60; DISCONNECT_INIT_CAM_INTERVAL_SEC=180; DISCONNECT_MAX_SEC="$2"
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state_h"
        DISCONNECT_REBOOT_FLAG_DIR="$WORK/flag_h"; DISCONNECT_REBOOT_FLAG="$WORK/flag_h/reboot.flag"
        init_cooldown_sec=40; PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        rm -rf "$DISCONNECT_INIT_CAM_STATE_FILE" "$DISCONNECT_REBOOT_FLAG_DIR"
        get_cam_disconnect_flag() { echo "$FLAG"; }
        read_driver_disconnect()  { echo 0; }
        date() { echo "$NOW"; }
        sync() { :; }; sleep() { :; }
        _cam_runtime_app_into()   { printf -v "$1" '%s' gstApp; }
        pgrep() { case "$APP" in (UP) [ "$2" = gstApp ] ;; (ERR) return 2 ;; (*) return 1 ;; esac; }
        cam_submit_internal_action() { echo "SUBMIT:$1"; return 0; }
        logger() { :; }
        # shellcheck disable=SC1090
        source "$WORK/f_app"; source "$WORK/f_ep"; source "$WORK/f_held"; source "$FN"
        for s in "1000 1 UP" "1002 0 DOWN" "$3 1 UP"; do
            set -- $s; NOW=$1; FLAG=$2; APP=$3
            maybe_init_cam_on_disconnect
        done
    )
    got=$(grep -o 'SUBMIT:[a-z_]*' <<<"$got" | sed 's/SUBMIT://' | tr '\n' ' ' | sed 's/ $//')
    t_eq "$1" "${got:-NONE}" "$4"
}
echo "=== 보존된 episode 는 부재 시간을 세지 않는다 (#213 A-R1-001) ==="
run_h "부재가 grace 를 넘긴 뒤 표본 1개 → 새 grace, 제출 없음"            0    1070 NONE
run_h "max_sec 설정·부재 2000초 뒤 표본 1개 → reboot_fallback 없음"      1800 3000 NONE

# #216: module_reload 뒤 BG 가 재지 않은 0 이 이력을 지우지 않아 180초 간격과 max_sec 누적이 이어지는지 본다.
# 표본은 "시각 플래그 앱 마커(P|A) i2c2원시값"(i2c1 은 R1, 기본 0). 끝에서 시작 마커 경로 판정(플래그 0,
# 마지막 표본의 앱)도 본다.
# $1=설명 $2=max_sec $3=기대 "<제출 목록> log=<보존 로그 수> state=… flag=… path=<DISC|LADDER>" $4…=표본
run_f() {
    local desc=$1 max=$2 want=$3 out got subs
    shift 3
    out=$(
        exec 2>&1
        KEY=RST; tag=chk_cam_operate.sh; file_chk_reboot=true
        DISCONNECT_INIT_CAM_GRACE_SEC=60; DISCONNECT_INIT_CAM_INTERVAL_SEC=180; DISCONNECT_MAX_SEC="$max"
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state_f"
        DISCONNECT_REBOOT_FLAG_DIR="$WORK/flag_f"; DISCONNECT_REBOOT_FLAG="$WORK/flag_f/reboot.flag"
        PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        t_link_fixture f
        rm -rf "$DISCONNECT_INIT_CAM_STATE_FILE" "$DISCONNECT_REBOOT_FLAG_DIR"
        get_cam_disconnect_flag() { echo "$FLAG"; }
        read_driver_disconnect()  { echo 0; }
        date() { echo "$NOW"; }
        sync() { :; }; sleep() { :; }
        _cam_runtime_app_into()   { printf -v "$1" '%s' gstApp; }
        pgrep() { case "$APP" in (UP) [ "$2" = gstApp ] ;; (*) return 1 ;; esac; }
        cam_submit_internal_action() { echo "SUBMIT:$1"; return 0; }
        logger() { echo "LOG:$*"; }
        # shellcheck disable=SC1090
        source "$WORK/f_app"; source "$WORK/f_ep"; source "$WORK/f_held"; source "$WORK/f_kept"
        # shellcheck disable=SC1090
        source "$WORK/f_um"; source "$WORK/f_sm"; source "$FN"
        for s in "$@"; do
            set -- $s; NOW=$1; FLAG=$2; APP=$3
            if [ "$4" = P ]; then echo "x" > "$FILE_"; else rm -f "$FILE_"; fi
            printf '%s\n' "$5" > "$SYSFS_LINK_I2C2"
            maybe_init_cam_on_disconnect
        done
        if start_marker_disconnect_path 0; then echo "PATH:DISC"; else echo "PATH:LADDER"; fi
        [ -f "$DISCONNECT_INIT_CAM_STATE_FILE" ] && echo "STATE_KEPT"
        [ -f "$DISCONNECT_REBOOT_FLAG" ] && echo "FLAG_KEPT"
    )
    subs=$(grep -o 'SUBMIT:[a-z_]*' <<<"$out" | sed 's/SUBMIT://' | tr '\n' ' ' | sed 's/ $//')
    got="${subs:-NONE} log=$(grep -c 'disconnect state kept' <<<"$out")"
    got="$got state=$(grep -q STATE_KEPT <<<"$out" && echo KEEP || echo GONE)"
    got="$got flag=$(grep -q FLAG_KEPT <<<"$out" && echo KEEP || echo GONE)"
    got="$got path=$(grep -o 'PATH:[A-Z]*' <<<"$out" | sed 's/PATH://')"
    grep -q 'command not found' <<<"$out" && got="$got error=Y"
    t_eq "$desc" "$got" "$want"
}
echo "=== module_reload 뒤 재지 않은 0 을 건너 간격·max_sec 유지 (#216) ==="
# 1060 조치 → 1062·1064 재지 않은 0(앱 있음, 마커 없음) → 끊김 표본. master 는 1062 에 이력을 지워
# 1100 에 새 grace 를 열고 1160 에 module_reload 를 다시 낸다(약 60초+α 주기). 수정본은 첫 표본(1000)부터
# max_sec 200 을 세어 1200 에 reboot_fallback, 마지막 조치(1060)부터 180초인 1240 에 module_reload 를 낸다.
# 1300 에 재생 중(마커 있음, i2c2 0) 0 이 오면 그때 지운다. 보존 로그는 재지 않은 창마다 한 번이다.
run_f "끊김 지속 → 180초 간격·max_sec 누적, 재생 확인 뒤 지움" 200 \
      "module_reload reboot_fallback module_reload log=1 state=GONE flag=GONE path=LADDER" \
      "1000 1 UP P 0" "1060 1 UP P 0" "1062 0 UP A -1" "1064 0 UP A -1" \
      "1100 1 UP P 0" "1160 1 UP P 0" "1200 1 UP P 0" "1240 1 UP P 0" "1300 0 UP P 0"
# 보존한 뒤 앱이 재생 전에 죽어도 보존 표시가 있는 이력은 열린 episode 가 아니다. 시작 마커 경로는 master 처럼
# 일반 사다리로 간다(AC2). 이력은 남아 다음 끊김 표본에서 180초 간격이 이어진다.
run_f "보존 뒤 앱이 재생 전에 죽음 → 이력은 남고 시작 마커 경로는 일반 사다리" 0 \
      "module_reload log=1 state=KEEP flag=GONE path=LADDER" \
      "1000 1 UP P 0" "1060 1 UP P 0" "1062 0 UP A -1" "1064 0 DOWN A -1"
# #216 A-R1-001: 설정만 켜고 스트리밍하지 않는 버스(i2c1)는 영영 -1 이다. 다른 버스를 잰 0 이면 이력을 지우고,
# 한참 뒤의 끊김 표본 하나는 새 grace 를 연다(묵은 first_seen 으로 곧바로 조치하지 않는다).
R1=-1 run_f "한 버스가 영영 -1·다른 버스는 잰 0 → 이력 지움, 다음 끊김은 새 grace" 1800 \
      "NONE log=0 state=KEEP flag=GONE path=LADDER" \
      "1000 1 UP P 0" "1002 0 UP P 0" "100000 1 UP P 0"
# 앱 부재로 보류(#213)한 뒤 앱이 다시 떴지만 아직 재지 않아 보존 표시가 겹쳐도, 다음 끊김 표본은 보류처럼
# 새 grace 를 연다(부재 시간을 세지 않는다).
run_f "보류 뒤 보존 이력 → 다음 끊김 표본에서 새 grace" 0 \
      "NONE log=1 state=KEEP flag=GONE path=LADDER" \
      "1000 1 UP P 0" "1002 0 DOWN P 0" "1004 0 UP A 0" "1070 1 UP P 0"

# #216 A-R1-002: module_reload 뒤 앱이 재생 전에 죽기를 되풀이해도(플래그 0, drv 0, 버스 모두 -1) 시작 마커
# 경로가 master 처럼 세는 사다리(gstapp_restart ×2 → module_reload ×2 → reboot_fallback)를 타 끝나는지 본다.
# 끊김 분기로 가면 조치 횟수를 세지 않는 module_reload 가 끝없이 돈다. 이력은 끝까지 남는다.
# $1=설명 $2=기대 "<제출 목록> state=<KEEP|GONE>"
run_l() {
    local out got subs
    out=$(
        exec 2>&1
        KEY=RST; tag=chk_cam_operate.sh; file_chk_reboot=true
        DISCONNECT_INIT_CAM_GRACE_SEC=60; DISCONNECT_INIT_CAM_INTERVAL_SEC=180; DISCONNECT_MAX_SEC=600
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/state_l"
        DISCONNECT_REBOOT_FLAG_DIR="$WORK/flag_l"; DISCONNECT_REBOOT_FLAG="$WORK/flag_l/reboot.flag"
        PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        MK=A R2=-1 R1=-1 t_link_fixture l
        rm -rf "$DISCONNECT_INIT_CAM_STATE_FILE" "$DISCONNECT_REBOOT_FLAG_DIR"
        get_cam_disconnect_flag() { echo "$FLAG"; }
        read_driver_disconnect()  { echo 0; }
        date() { echo "$NOW"; }
        sync() { :; }; sleep() { :; }; logger() { :; }
        _cam_runtime_app_into()   { printf -v "$1" '%s' gstApp; }
        pgrep() { [ "$APP" = UP ]; }
        # 조치는 앱을 다시 띄운다.
        cam_submit_internal_action() { echo "SUBMIT:$1"; APP=UP; return 0; }
        # shellcheck disable=SC1090
        source "$WORK/f_app"; source "$WORK/f_ep"; source "$WORK/f_held"; source "$WORK/f_kept"
        # shellcheck disable=SC1090
        source "$WORK/f_um"; source "$WORK/f_sm"; source "$FN"
        NOW=1000; FLAG=1; APP=UP; maybe_init_cam_on_disconnect
        NOW=1060; maybe_init_cam_on_disconnect
        FLAG=0; rb=0
        for _ in 1 2 3 4 5 6 7 8; do
            NOW=$((NOW + 4)); maybe_init_cam_on_disconnect
            APP=DOWN; NOW=$((NOW + 30)); maybe_init_cam_on_disconnect
            if start_marker_disconnect_path 0; then
                cam_submit_internal_action module_reload
            else
                rb=$((rb + 1))
                if (( rb <= 2 )); then cam_submit_internal_action gstapp_restart
                elif (( rb <= 4 )); then cam_submit_internal_action module_reload
                else cam_submit_internal_action reboot_fallback; break; fi
            fi
        done
        [ -f "$DISCONNECT_INIT_CAM_STATE_FILE" ] && echo "STATE_KEPT"
    )
    subs=$(grep -o 'SUBMIT:[a-z_]*' <<<"$out" | sed 's/SUBMIT://' | tr '\n' ' ' | sed 's/ $//')
    got="$subs state=$(grep -q STATE_KEPT <<<"$out" && echo KEEP || echo GONE)"
    grep -q 'command not found' <<<"$out" && got="$got error=Y"
    t_eq "$1" "$got" "$2"
}
run_l "재기동마다 재생 전에 죽음 → master 와 같은 사다리로 reboot_fallback, 이력 유지" \
      "module_reload gstapp_restart gstapp_restart module_reload module_reload reboot_fallback state=KEEP"

t_summary "에스컬레이션"
