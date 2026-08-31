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

t_summary "카메라 기동 시간 정책"
