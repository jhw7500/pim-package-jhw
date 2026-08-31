#!/bin/bash
# Camera cold-start timing policy shared by the launch and health scripts.
#
# gstApp -d is only the application's PLAYING transition delay.  It must not
# also define how long health monitoring ignores expected cold-start errors:
# MAX9296/AP1302 power sequencing and driver prepare happen before PLAYING.
CAM_APP_PLAY_DELAY_SEC_DEFAULT=5
CAMERA_STARTUP_GRACE_SEC_DEFAULT=25

cam_policy_nonnegative_or_default() {
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

# Read only a non-negative integer JSON value.  jq -r erases JSON type
# information (the string "30" and the number 30 both print as 30), so type
# validation must happen inside jq before returning text to the shell.
cam_policy_camera_startup_grace_sec() {
    local config_path="$1"
    local value

    value=$(jq -r '
        .ETC.camera_startup_grace_sec as $v
        | if ($v | type) == "number" then
              if ($v >= 0) and (($v | floor) == $v) then $v else empty end
          else empty end
    ' "$config_path" 2>/dev/null)
    cam_policy_nonnegative_or_default \
        "$value" "$CAMERA_STARTUP_GRACE_SEC_DEFAULT"
}
