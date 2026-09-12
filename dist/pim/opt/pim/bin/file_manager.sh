#!/bin/bash
INPUT_PATH=$1
LIMIT=$2
SIZE=$3
KEY=$4
FILE_PATH=""
tag=$(basename "$0")
cnt=0
MAX_SIZE=$((SIZE * 1024 * 1024))

if [[ "${PIM_CAMERA_TEST_MODE:-0}" == "1" ]]; then
    PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:?PIM_CAMERA_RUNTIME_JSON is required in test mode}"
else
    PIM_CAMERA_RUNTIME_JSON="/run/pim-camera/config/pim_runtime.json"
fi

config_invalid() {
    logger -p local0.err "[$tag:$LINENO] CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    exit 64
}

runtime_unavailable() {
    logger -p local0.notice "[$tag:$LINENO] RUNTIME_UNAVAILABLE: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    exit 0
}

runtime_path_confirmed_missing() {
    local probe="$PIM_CAMERA_RUNTIME_JSON"
    local parent

    while [[ ! -e "$probe" ]]; do
        [[ ! -L "$probe" ]] || return 1
        parent=${probe%/*}
        [[ -n "$parent" ]] || parent=/
        [[ "$parent" != "$probe" ]] || return 1
        probe=$parent
    done

    [[ -d "$probe" && -x "$probe" ]]
}

runtime_json=$(<"$PIM_CAMERA_RUNTIME_JSON") || {
    runtime_path_confirmed_missing && runtime_unavailable
    config_invalid
}
command -v jq >/dev/null 2>&1 || config_invalid
VHL_NAME=$(jq -er '
    if type == "object" and
       (.VHL_CAM | type) == "object" and
       (.ORD | type) == "object" and
       (.VCM | type) == "object" and
       ((.VHL_CAM.vhl_name // "") | type) == "string"
    then (.VHL_CAM.vhl_name // "") else error("invalid camera runtime") end
' <<<"$runtime_json") || config_invalid
if [[ -n "$VHL_NAME" ]]; then
    KEY="$VHL_NAME"
fi

if [[ "$KEY" == "." || "$KEY" == ".." || ! "$KEY" =~ ^[A-Za-z0-9._-]+$ ]]; then
    logger -p local0.err "[$tag:$LINENO] CONFIG_INVALID: unsafe effective file key" 2>/dev/null
    exit 64
fi

#echo "========================="
#echo "input path : " $INPUT_PATH

if [[ ! -d "$INPUT_PATH" ]]; then
    logger -p local0.crit "[$tag:$LINENO] failed : $INPUT_PATH is not directory"
    exit 1
fi
INPUT_PATH=$(realpath -e -- "$INPUT_PATH") || exit 1

if [[ "$LIMIT" -le 1 ]]; then
    logger -p local0.crit "[$tag:$LINENO] failed : LIMIT:$LIMIT greater than 1"
    exit 1
fi

FILE_PATH="$INPUT_PATH/$KEY*"
shopt -s nullglob

collect_matching_files() {
    MATCHING_FILES=()
    local candidate
    for candidate in "$INPUT_PATH"/"$KEY"*; do
        [[ -f "$candidate" ]] || continue
        candidate=$(realpath -m -- "$candidate") || config_invalid
        [[ "$(dirname -- "$candidate")" == "$INPUT_PATH" ]] || config_invalid
        MATCHING_FILES+=("$candidate")
    done
}

oldest_matching_file() {
    local candidate
    local oldest=""
    for candidate in "${MATCHING_FILES[@]}"; do
        if [[ -z "$oldest" || "$candidate" -ot "$oldest" ]]; then
            oldest="$candidate"
        fi
    done
    printf '%s\n' "$oldest"
}

#logger -p local0.notice "[$tag:$LINENO] path : $INPUT_PATH, key : $KEY, $limit cnt : $LIMIT, limit size : $SIZE MB"

while :; do
    current_size=$(du -sb -- "$INPUT_PATH" | awk '{print $1}')
    if [[ "$current_size" -gt "$MAX_SIZE" ]]; then
        #logger -p local0.info "[$tag:$LINENO] $INPUT_PATH dir $current_size byte over $MAX_SIZE byte!"
        collect_matching_files
        oldest_file=$(oldest_matching_file)
        [[ -n "$oldest_file" ]] || exit 1
        #echo "Deleting oldest log file: $oldest_file"
        logger -p local0.notice "[$tag:$LINENO] $FILE_PATH size ($current_size > $MAX_SIZE) :deleting $oldest_file"
        rm -f -- "$oldest_file"
        #current_size=$(du -sb $INPUT_PATH | awk '{print $1}')
        #logger -p local0.info "[$tag:$LINENO] $INPUT_PATH dir size : $current_size byte"
        sleep 0.1
        continue
    fi
    break
done

while :; do
    #echo "file_path:$FILE_PATH, file_cnt:$cnt"
    #find $FILE_PATH -mindepth 1 -maxdepth 1 | wc -l
    collect_matching_files
    cnt=${#MATCHING_FILES[@]}
    if [[ "$cnt" -gt "$LIMIT" ]]; then
        #logger -p local0.info "[$tag:$LINENO] file cnt $cnt > $LIMIT ($tailcnt)"
        #del=$((cnt - LIMIT))
        #find $FILE_PATH* -maxdepth 1 -type f -printf '%T+ %p\n' | sort | head -n -$LIMIT | cut -d' ' -f2- | xargs -r rm -f
        oldest_file=$(oldest_matching_file)
        logger -p local0.notice "[$tag:$LINENO] $FILE_PATH cnt ($cnt > $LIMIT) : deleting $oldest_file"
        rm -f -- "$oldest_file"
        #cnt=$(ls -lt $FILE_PATH | grep ^- | wc -l)
        #logger -p local0.info "[$tag:$LINENO] $INPUT_PATH file cnt : $cnt"
        sleep 0.1
        continue
    fi
    break
done
