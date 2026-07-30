#!/bin/bash
# chk_cam_operate.sh 의 GetConfig_ 기본값 복구 검증
# 사용법: bash test/cam_link/config_default_test.sh
#
# 배경: jq 실패(설정 파일 없음/손상) 시 read 가 모든 변수를 빈 문자열로 채우고,
# 빈 값은 (( )) 산술에서 0으로 취급되어 grace/cooldown 보호가 조용히 사라진다.
# _cfg_num() 이 선언된 기본값으로 되돌리는지, 그 기본값이 패키지 배포 설정
# (config/ord_vcm_conf.json 의 ETC)과 일치하는지 확인한다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
DEFS="$WORK/cfg_defs.sh"
trap 'rm -rf "$WORK"' EXIT

# 상수 선언부 + _cfg_num + GetConfig_ 만 모아 source
sed -n '/^FILE_CHECK_DELAY_DEFAULT=/,/^DISCONNECT_REBOOT_FLAG=/p' "$PIM_BIN/chk_cam_operate.sh" > "$DEFS"
t_extract_func "$PIM_BIN/chk_cam_operate.sh" _cfg_num    "$WORK/f1" || exit 1
t_extract_func "$PIM_BIN/chk_cam_operate.sh" GetConfig_  "$WORK/f2" || exit 1
cat "$WORK/f1" "$WORK/f2" >> "$DEFS"
# shellcheck disable=SC1090
source "$DEFS"

# 패키지 배포 설정에서 기대값을 읽어온다 (하드코딩하지 않는다)
PKG_JSON="$PIM_CFG/ord_vcm_conf.json"
exp_delay=$(jq -r '.ETC.file_check_delay'             "$PKG_JSON")
exp_grace=$(jq -r '.ETC.startup_grace_extra_sec'      "$PKG_JSON")
exp_cool=$(jq  -r '.ETC.init_cooldown_sec'            "$PKG_JSON")
exp_intv=$(jq  -r '.ETC.disconnect_init_interval_sec' "$PKG_JSON")
exp_dgrc=$(jq  -r '.ETC.disconnect_init_grace_sec'    "$PKG_JSON")

check_all() {   # $1=시나리오 설명
    t_eq "$1 · file_check_delay"                 "$file_check_delay"                 "$exp_delay"
    t_eq "$1 · startup_grace_extra_sec"          "$startup_grace_extra_sec"          "$exp_grace"
    t_eq "$1 · init_cooldown_sec"                "$init_cooldown_sec"                "$exp_cool"
    t_eq "$1 · DISCONNECT_INIT_CAM_INTERVAL_SEC" "$DISCONNECT_INIT_CAM_INTERVAL_SEC" "$exp_intv"
    t_eq "$1 · DISCONNECT_INIT_CAM_GRACE_SEC"    "$DISCONNECT_INIT_CAM_GRACE_SEC"    "$exp_dgrc"
}

echo "=== 정상 설정 파일 로드 (기대값은 패키지 배포 설정에서 읽음) ==="
FILE_JSON_="$PKG_JSON"; GetConfig_
check_all "정상"
t_eq "정상 · DISCONNECT_MAX_SEC (배포 설정에 키 없음 → 0)" "$DISCONNECT_MAX_SEC" 0

echo
echo "=== 설정 파일 없음 (jq 실패) → 선언 기본값 복귀 ==="
FILE_JSON_="$WORK/does-not-exist.json"; GetConfig_ 2>/dev/null
check_all "파일없음"

echo
echo "=== 손상된 JSON → 선언 기본값 복귀 ==="
printf '{ this is not json' > "$WORK/broken.json"
FILE_JSON_="$WORK/broken.json"; GetConfig_ 2>/dev/null
check_all "손상JSON"

echo
echo "=== 복구된 값으로 grace 보호가 실제로 동작하는가 ==="
now=1000; first_seen=990
if (( (now - first_seen) < DISCONNECT_INIT_CAM_GRACE_SEC )); then
    t_ok "경과 10s < grace ${DISCONNECT_INIT_CAM_GRACE_SEC}s → grace 적용"
else
    t_bad "grace 무시됨 (GRACE=$DISCONNECT_INIT_CAM_GRACE_SEC)"
fi

echo
echo "=== _cfg_num 경계값 ==="
t_eq "정수"        "$(_cfg_num 40 99)"   40
t_eq "빈 문자열"   "$(_cfg_num '' 99)"   99
t_eq "단위 붙음"   "$(_cfg_num 40s 99)"  99
t_eq "음수"        "$(_cfg_num -5 99)"   99
t_eq "공백"        "$(_cfg_num ' ' 99)"  99
t_eq "0 은 유효"   "$(_cfg_num 0 99)"    0

t_summary "설정 기본값"
