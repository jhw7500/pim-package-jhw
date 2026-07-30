#!/bin/bash
# chk_cam_operate.sh 의 disconnect 에스컬레이션(maybe_init_cam_on_disconnect) 검증
# 사용법: bash test/cam_link/escalation_test.sh
#
# 배경: cam_disconnect_flag != 0 경로는 retry/retry_boot 를 증가시키지 않아 상한 없이
# init_cam 을 반복한다(1호기 로그 17:53~18:04, 11분간 8회). DISCONNECT_MAX_SEC 로
# 시간 상한을 두되 기본값 0(비활성)이라 "Never reboot in disconnect state" 원칙은 유지된다.
# 활성화 시에도 episode 당 1회만 리부팅하며, 영구 플래그를 못 쓰면 리부팅하지 않는다.
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
        reboot() { echo "REBOOT_CALLED"; }
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
run_b "이미 1회 에스컬레이션 → 재리부팅 없음" 1800 5000  true  Y NONE
run_b "file_check_reboot=false → 리부팅 없음" 1800 1900  false N NONE
run_b "max_sec 비정상값(공백) → 안전측 비활성" ""  99999 true  N NONE
# 영구 플래그를 못 쓰면 재부팅 후 이력이 사라져 리부팅 루프가 되므로 건너뛰어야 한다
run_b "플래그 쓰기 실패 → 리부팅 건너뜀"    1800 1900  true  N NONE /dev/null/cannot-create

t_summary "에스컬레이션"
