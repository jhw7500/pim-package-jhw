#!/bin/bash

if [[ "${PIM_CAMERA_TEST_MODE:-0}" == "1" ]]; then
    PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:?PIM_CAMERA_RUNTIME_JSON is required in test mode}"
    ROTATE_DELAY_SEC="${PIM_CAMERA_ROTATE_DELAY_SEC:?PIM_CAMERA_ROTATE_DELAY_SEC is required in test mode}"
else
    PIM_CAMERA_RUNTIME_JSON="/run/pim-camera/config/pim_runtime.json"
    ROTATE_DELAY_SEC=15
fi

config_invalid() {
    logger -p local0.err "[ROTATE:$LINENO] CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    echo "CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" >&2
    exit 64
}

command -v jq >/dev/null 2>&1 || config_invalid
runtime_json=$(<"$PIM_CAMERA_RUNTIME_JSON") || config_invalid
camera_line=$(jq -er '
    if type == "object" and
       (.VHL_CAM | type) == "object" and
       (.ORD | type) == "object" and
       (.VCM | type) == "object" and
       (.VHL_CAM.cam_ch0 | type) == "boolean" and
       (.VHL_CAM.cam_ch0_rotate | type) == "boolean" and
       (.VHL_CAM.cam_ch1 | type) == "boolean" and
       (.VHL_CAM.cam_ch1_rotate | type) == "boolean" and
       (.VHL_CAM.cam_ch2 | type) == "boolean" and
       (.VHL_CAM.cam_ch2_rotate | type) == "boolean" and
       (.VHL_CAM.cam_ch3 | type) == "boolean" and
       (.VHL_CAM.cam_ch3_rotate | type) == "boolean"
    then [.VHL_CAM.cam_ch0, .VHL_CAM.cam_ch0_rotate,
          .VHL_CAM.cam_ch1, .VHL_CAM.cam_ch1_rotate,
          .VHL_CAM.cam_ch2, .VHL_CAM.cam_ch2_rotate,
          .VHL_CAM.cam_ch3, .VHL_CAM.cam_ch3_rotate] | @tsv
    else error("invalid camera runtime") end
' <<<"$runtime_json") || config_invalid
IFS=$'\t' read -r -a camera_values <<<"$camera_line"
[[ "${#camera_values[@]}" -eq 8 ]] || config_invalid

sleep "$ROTATE_DELAY_SEC"

apply_rotation() {
    local channel=$1
    local enabled=$2
    local rotate=$3
    local bus=$4
    local address=$5
    local value=0x00

    if [[ "$enabled" != "true" ]]; then
        echo "$channel disable"
        return
    fi
    if [[ "$rotate" == "true" ]]; then
        value=0x03
    fi

    i2ctransfer -f -y -a "$bus" "w4@$address" 0x10 0x0c 0x00 "$value"
    echo "$channel set rotate $rotate"
}

apply_rotation cam_ch0 "${camera_values[0]}" "${camera_values[1]}" 2 0x11
apply_rotation cam_ch1 "${camera_values[2]}" "${camera_values[3]}" 2 0x12
apply_rotation cam_ch2 "${camera_values[4]}" "${camera_values[5]}" 1 0x11
apply_rotation cam_ch3 "${camera_values[6]}" "${camera_values[7]}" 1 0x12

timestamp=$(date +"%Y-%m-%d %T,%3N")
echo "$timestamp cam rotation success"
exit 0
