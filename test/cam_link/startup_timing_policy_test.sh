#!/bin/bash
# gstApp 재생 지연과 cold-start 감시 grace가 서로 독립적인지 검증한다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

POLICY="$PIM_LIB/cam_start_policy.sh"
if [ -r "$POLICY" ]; then
    # shellcheck disable=SC1090
    source "$POLICY"
else
    t_bad "공통 카메라 기동 정책 파일 존재 ($POLICY)"
    # 뒤의 동작 검증도 수행할 수 있도록 요구값을 임시로 둔다.
    CAM_APP_PLAY_DELAY_SEC_DEFAULT=5
    CAMERA_STARTUP_GRACE_SEC_DEFAULT=25
fi

t_eq "gstApp 공통 재생 지연" "$CAM_APP_PLAY_DELAY_SEC_DEFAULT" 5
t_eq "cold-start 총 grace" "$CAMERA_STARTUP_GRACE_SEC_DEFAULT" 25

printf '%s\n' '{"ETC":{"camera_startup_grace_sec":30}}' > "$WORK/grace-number.json"
printf '%s\n' '{"ETC":{"camera_startup_grace_sec":"30"}}' > "$WORK/grace-string.json"
printf '%s\n' '{"ETC":{"camera_startup_grace_sec":true}}' > "$WORK/grace-bool.json"
printf '%s\n' '{"ETC":{"camera_startup_grace_sec":-1}}' > "$WORK/grace-negative.json"
t_eq "정수 JSON grace 허용" \
    "$(cam_policy_camera_startup_grace_sec "$WORK/grace-number.json")" 30
t_eq "문자열 grace는 안전 기본값" \
    "$(cam_policy_camera_startup_grace_sec "$WORK/grace-string.json")" 25
t_eq "불리언 grace는 안전 기본값" \
    "$(cam_policy_camera_startup_grace_sec "$WORK/grace-bool.json")" 25
t_eq "음수 grace는 안전 기본값" \
    "$(cam_policy_camera_startup_grace_sec "$WORK/grace-negative.json")" 25

# chk_cam_operate의 실제 설정 해석 함수를 실행하여 카메라 구성에 따라
# app_delay가 다시 11/22초로 갈라지지 않는지 확인한다.
t_extract_func "$PIM_BIN/chk_cam_operate.sh" GetConfig "$WORK/GetConfig.sh" || exit 1
# shellcheck disable=SC1090
source "$WORK/GetConfig.sh"

make_edgeconf() {
    local path="$1" ch0="$2" ch1="$3" ch2="$4" ch3="$5"
    jq -n \
        --argjson ch0 "$ch0" --argjson ch1 "$ch1" \
        --argjson ch2 "$ch2" --argjson ch3 "$ch3" \
        '{VHL_CAM:{app:"gstApp",i2c2:{ch0:{enable:$ch0},ch1:{enable:$ch1}},i2c1:{ch2:{enable:$ch2},ch3:{enable:$ch3}}}}' \
        > "$path"
}

ENABLE_VAL=true

make_edgeconf "$WORK/single.json" true false false false
FILE_JSON="$WORK/single.json"
csi1_en=0; csi2_en=0
GetConfig
t_eq "싱글 CSI의 gstApp 재생 지연" "$app_delay" 5
t_eq "싱글 CSI start-marker timeout 유지" "$rst_time" 25

make_edgeconf "$WORK/dual.json" true false true false
FILE_JSON="$WORK/dual.json"
csi1_en=0; csi2_en=0
GetConfig
t_eq "듀얼 CSI의 gstApp 재생 지연" "$app_delay" 5
t_eq "듀얼 CSI start-marker timeout 유지" "$rst_time" 35

# ---------------------------------------------------------------------------
# 여기까지의 단정은 gstApp 을 실제로 띄우는 경로를 하나도 건드리지 않는다.
# chk_cam_operate 의 app_delay 는 로그 한 줄(:1365)에만 쓰이고 그 파일의
# start_cam.sh 호출은 주석이며(:1293), 정책 상수를 읽은 것은 이 테스트 자신이다.
# 그래서 b6b70a9 가 실행 경로에 `.VHL_CAM.app_delay // 4` 를 심었을 때 이 파일은
# 초록인 채로 남았다. 아래는 그 경로를 직접 구동한다.

printf '%s\n' '{"VHL_CAM":{"app":"gstApp"}}' > "$WORK/no-app-delay.json"
printf '%s\n' '{"VHL_CAM":{"app":"gstApp","app_delay":7}}' > "$WORK/explicit-delay.json"

t_extract_func "$PIM_LIB/cam_recovery_actions.sh" cam_runtime_app_delay \
    "$WORK/cam_runtime_app_delay.sh" || exit 1
# shellcheck disable=SC1090
source "$WORK/cam_runtime_app_delay.sh"

# cam_runtime_app_delay 는 "앱<TAB>지연" 을 돌려준다. 지연만 떼어낸다.
delay_of() {
    local out
    out=$(cam_runtime_app_delay "$1") || return $?
    printf '%s' "${out#*$'\t'}"
}

t_eq "런타임 문서에 app_delay 가 없을 때 실제 해석되는 지연" \
    "$(delay_of "$WORK/no-app-delay.json")" 5
t_eq "해석된 지연의 출처가 정책 상수" \
    "$(delay_of "$WORK/no-app-delay.json")" "$CAM_APP_PLAY_DELAY_SEC_DEFAULT"
t_eq "런타임 문서가 값을 주면 그 값이 기본값을 이긴다" \
    "$(delay_of "$WORK/explicit-delay.json")" 7

# 위 세 단정은 추출한 함수를 이 테스트의 환경에서 돌린다 — 정책 파일을 source 한
# 것이 테스트 자신이므로 "라이브러리가 정책을 스스로 읽는가" 는 아직 미검증이다.
# 라이브러리를 통째로 새 셸에서 source 하고 환경에 가짜 값을 심어 확인한다.
# 스스로 읽지 않으면 99 가 나오고, source 를 "이미 설정돼 있으면 건너뜀" 으로
# 감싸 두어도 99 가 나온다.
poisoned=$(CAM_APP_PLAY_DELAY_SEC_DEFAULT=99 PIM_LIB="$PIM_LIB" PIM_BIN="$PIM_BIN" \
    bash -c 'source "$PIM_LIB/cam_recovery_actions.sh"
             cam_runtime_app_delay "$1"' _ "$WORK/no-app-delay.json")
t_eq "환경의 가짜 정책값이 라이브러리 해석을 이기지 못한다" "${poisoned#*$'\t'}" 5

# 위 단정은 정책 파일이 로드되는 경우만 본다. source 는 파일이 없으면 치명적이지
# 않게 실패하고 실행이 계속되므로, 그 조건에서 환경값이 그대로 정책이 될 수 있다 —
# 트리뷰널 A-R1-001 이 파일만 지운 트리에서 delay=777 로 실증한 경로다. 여기서는
# 라이브러리 사본에서 정책 파일만 지우고 같은 환경값을 심어, 값이 새지 않고
# fail-closed 되는지 본다.
mkdir -p "$WORK/nolib"
cp -a "$PIM_LIB/." "$WORK/nolib/"
rm -f "$WORK/nolib/cam_start_policy.sh"
[ -e "$WORK/nolib/cam_recovery_actions.sh" ] && [ ! -e "$WORK/nolib/cam_start_policy.sh" ] \
    || t_bad "전제 실패: 사본에 라이브러리는 있고 정책 파일만 없어야 한다"
: > "$WORK/nolib-action.log"
nofile_out=$(CAM_APP_PLAY_DELAY_SEC_DEFAULT=777 PIM_LIB="$WORK/nolib" PIM_BIN="$PIM_BIN" \
    PIM_CAMERA_ACTION_LOG="$WORK/nolib-action.log" \
    bash -c 'source "$PIM_LIB/cam_recovery_actions.sh" 2>/dev/null
             cam_runtime_app_delay "$1"' _ "$WORK/no-app-delay.json" 2>/dev/null)
nofile_rc=$?
t_eq "정책 파일이 없으면 지연 해석이 fail-closed" "$nofile_rc" 64
t_eq "그때 환경의 777 이 정책으로 새지 않는다" "${nofile_out:-(없음)}" "(없음)"
# rc 64 만으로는 부족하다 — unset 만 있고 명시적 검사가 없으면 빈 --argjson 때문에
# jq 가 실패해 같은 rc 64 가 나온다. 즉 두 단정은 검사 블록의 제거를 구분하지 못한다.
# 이유가 로그에 남는지까지 봐야 그 블록이 하중을 받는다.
t_eq "닫힌 이유가 action 로그에 남는다" \
    "$(grep -c 'app play delay policy unavailable' "$WORK/nolib-action.log")" 1

# 해석된 값이 런처 argv 로 건너가는 한 홉까지 본다. 여기서 끊기면 위 단정이
# 모두 통과해도 gstApp 은 다른 값을 받는다.
t_extract_func "$PIM_LIB/cam_recovery_actions.sh" cam_start_gstapp \
    "$WORK/cam_start_gstapp.sh" || exit 1
# shellcheck disable=SC1090
source "$WORK/cam_start_gstapp.sh"
_cr_timing() { :; }
cam_bg_checker_path() { printf '%s\n' "$WORK/bg-check"; }
cam_side_effect_guard() { return 0; }
printf '#!/bin/sh\nprintf "%%s" "$1" > "%s"\n' "$WORK/launched-delay" > "$WORK/record-start-cam"
chmod +x "$WORK/record-start-cam"
PIM_CAMERA_START_CAM="$WORK/record-start-cam"
rm -f "$WORK/launched-delay"
cam_start_gstapp "$WORK/no-app-delay.json"
if [ -f "$WORK/launched-delay" ]; then
    t_eq "런처가 받은 -d 인자" "$(cat "$WORK/launched-delay")" 5
else
    t_bad "런처가 호출되지 않았다 — 앞 단정들이 공회전한다"
fi

t_summary "카메라 기동 시간 정책"
