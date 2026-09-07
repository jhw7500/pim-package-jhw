#!/usr/bin/env bash
tag=$(basename "$0")
KEY=FTP

logger -p local0.notice "[$KEY][$tag:$LINENO] $tag start"

FTP_SERVER="192.168.1.129"
#FTP_SERVER="100.100.100.100"
USERNAME="jhw"
PASSWORD="jhw"
REMOTE_DIR="/opt/sda/Downloads"
#REMOTE_DIR="D:\Downloads"

FILE_TO_TRANSFER=0
INTERVAL=5
transfer_check=""

TEST_MODE=0
MAX_ITERATIONS=0
if [[ "${PIM_CAMERA_TEST_MODE:-0}" == "1" ]]; then
    TEST_MODE=1
    PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:?PIM_CAMERA_RUNTIME_JSON is required in test mode}"
    PATH_TO_TRANSFER="${PIM_NCSFTP_TRANSFER_PATH:?PIM_NCSFTP_TRANSFER_PATH is required in test mode}"
    FILE_CHECK="${PIM_NCSFTP_FILE_CHECK:?PIM_NCSFTP_FILE_CHECK is required in test mode}"
    MAX_ITERATIONS="${PIM_NCSFTP_MAX_ITERATIONS:?PIM_NCSFTP_MAX_ITERATIONS is required in test mode}"
else
    PIM_CAMERA_RUNTIME_JSON="/run/pim-camera/config/pim_runtime.json"
    PATH_TO_TRANSFER="/mnt/sd_cam"
    FILE_CHECK="/tmp/file_check"
fi

config_invalid() {
    logger -p local0.err "[$KEY][$tag:$LINENO] CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    exit 64
}

command -v jq >/dev/null 2>&1 || config_invalid
runtime_json=$(<"$PIM_CAMERA_RUNTIME_JSON") || config_invalid
runtime_values=$(jq -er '
    if type == "object" and
       (.VHL_CAM | type) == "object" and
       (.ORD | type) == "object" and
       (.VCM | type) == "object" and
       (.VHL_CAM.recording_time | type) == "number" and
       (.VHL_CAM.vhl_name | type) == "string" and
       (.VHL_CAM.vhl_name | length) > 0
    then [.VHL_CAM.recording_time, .VHL_CAM.vhl_name] | @tsv
    else error("invalid camera runtime") end
' <<<"$runtime_json") || config_invalid
IFS=$'\t' read -r rec_time vhl_name <<<"$runtime_values"
if [[ "$vhl_name" == "." || "$vhl_name" == ".." || ! "$vhl_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    config_invalid
fi
transfer_root=$(realpath -m -- "$PATH_TO_TRANSFER") || config_invalid
logger -p local0.notice "[$KEY][$tag:$LINENO] ip:$FTP_SERVER, id:$USERNAME, pwd:$PASSWORD, remote_dir:$REMOTE_DIR, json:$PIM_CAMERA_RUNTIME_JSON, rec_time:$rec_time vhl_name:$vhl_name"

iteration=0
while true; do
    #if [[ $cur_min -ne $(date '+%M') && $(date '+%S') -ge 5 ]]; then
    file_check=$(tr -d '\n' < "$FILE_CHECK" 2>/dev/null)
    #if [ "$transfer_check" == "OK"  ]; then
    if [[ -n "$file_check" ]]; then
        logger -p local0.info "[$KEY][$tag:$LINENO] file_check : $file_check"
        FILE_TO_TRANSFER=$(date '+%Y%m%d_%H%M00' -d "$rec_time min ago")
        transfer_prefix="$transfer_root/${vhl_name}_${FILE_TO_TRANSFER}"
        [[ "$(dirname -- "$(realpath -m -- "$transfer_prefix")")" == "$transfer_root" ]] \
            || config_invalid
        shopt -s nullglob
        transfer_candidates=("$transfer_prefix"*)
        shopt -u nullglob
        for candidate in "${transfer_candidates[@]}"; do
            [[ "$(dirname -- "$(realpath -m -- "$candidate")")" == "$transfer_root" ]] \
                || config_invalid
        done
        logger -p local0.notice "[$KEY][$tag:$LINENO] ncftpput -u $USERNAME -p $PASSWORD $FTP_SERVER $REMOTE_DIR $PATH_TO_TRANSFER/${vhl_name}_${FILE_TO_TRANSFER}*"
        if [[ "${#transfer_candidates[@]}" -gt 0 ]]; then
            ncftpput -u "$USERNAME" -p "$PASSWORD" "$FTP_SERVER" "$REMOTE_DIR" \
                "${transfer_candidates[@]}"
        else
            ncftpput -u "$USERNAME" -p "$PASSWORD" "$FTP_SERVER" "$REMOTE_DIR" \
                "$transfer_prefix"*
        fi
        #logger -p local0.notice "[$KEY][$tag:$LINENO] sshpass -p $PASSWORD scp $PATH_TO_TRANSFER/$vhl_name_$FILE_TO_TRANSFER* $USERNAME@$FTP_SERVER:$REMOTE_DIR"
        #sshpass -p "$PASSWORD" scp $PATH_TO_TRANSFER/"$vhl_name"_"$FILE_TO_TRANSFER"* $USERNAME@$FTP_SERVER:$REMOTE_DIR
        logger -p local0.notice "[$KEY][$tag:$LINENO] ncftp end"
        : > "$FILE_CHECK"
        #cur_min=$(date '+%M')
    fi

    iteration=$((iteration + 1))
    if [[ "$TEST_MODE" == "1" && "$iteration" -ge "$MAX_ITERATIONS" ]]; then
        break
    fi
    sleep "$INTERVAL"
done
