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
    CACHE_PATH="${PIM_FILE_MANAGER_VHL_CACHE:-${PIM_CAMERA_RUNTIME_JSON}.file-manager-vhl.cache}"
else
    PIM_CAMERA_RUNTIME_JSON="/run/pim-camera/config/pim_runtime.json"
    CACHE_PATH="${PIM_CAMERA_RUNTIME_JSON}.file-manager-vhl.cache"
fi

# Cached stand-in for a runtime that publishes no usable VHL name.  It contains
# characters the VHL validation regex rejects, so a real name can never equal it
# and a cached sentinel can never be promoted into KEY.
VHL_CACHE_EMPTY='@empty@'

config_invalid() {
    logger -p local0.err "[$tag:$LINENO] CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    exit 64
}

runtime_unavailable() {
    logger -p local0.notice "[$tag:$LINENO] RUNTIME_UNAVAILABLE: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    exit 0
}

runtime_path_confirmed_missing() {
    local runtime_path="$PIM_CAMERA_RUNTIME_JSON"
    local probe="$PIM_CAMERA_RUNTIME_JSON"
    local parent

    while [[ ! -e "$probe" ]]; do
        [[ ! -L "$probe" ]] || return 1
        parent=${probe%/*}
        [[ -n "$parent" ]] || parent=/
        [[ "$parent" != "$probe" ]] || return 1
        probe=$parent
    done

    [[ "$probe" != "$runtime_path" && -d "$probe" && -x "$probe" ]]
}

runtime_identity() {
    stat -Lc '%d:%i:%s:%y:%z' -- "$PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
}

cache_destination_safe() {
    [[ "$CACHE_PATH" != "$PIM_CAMERA_RUNTIME_JSON" ]] || return 1
    [[ ! -L "$CACHE_PATH" ]] || return 1
    [[ ! -e "$CACHE_PATH" || -f "$CACHE_PATH" ]] || return 1
    if [[ -e "$CACHE_PATH" && "$CACHE_PATH" -ef "$PIM_CAMERA_RUNTIME_JSON" ]]; then
        return 1
    fi
}

runtime_path_confirmed_missing && runtime_unavailable

command -v jq >/dev/null 2>&1 || config_invalid
cache_destination_safe || config_invalid
runtime_id=$(runtime_identity) || {
    runtime_path_confirmed_missing && runtime_unavailable
    config_invalid
}

cached_id=""
cached_vhl_name=""
cached_extra=""
if [[ -f "$CACHE_PATH" && ! -L "$CACHE_PATH" ]]; then
    # A record that is not newline-terminated is a short write, not a usable
    # entry.  read still assigns whatever it parsed before EOF, and a value
    # truncated mid-name stays a strict prefix of the real one, so trusting it
    # would widen the deletion glob past what the runtime designated.  Discard
    # every field unless the record is complete and fall through to jq.
    IFS=$'\t' read -r cached_id cached_vhl_name cached_extra < "$CACHE_PATH" || {
        cached_id=""
        cached_vhl_name=""
        cached_extra=""
    }
fi

cached_hit=0
if [[ "$cached_id" == "$runtime_id" && -z "$cached_extra" ]]; then
    if [[ "$cached_vhl_name" == "$VHL_CACHE_EMPTY" ]]; then
        VHL_NAME=""
        cached_hit=1
    elif [[ -n "$cached_vhl_name" &&
            "$cached_vhl_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        VHL_NAME=$cached_vhl_name
        cached_hit=1
    fi
fi

if [[ "$cached_hit" == 0 ]]; then
    VHL_NAME=$(jq -ner --slurpfile runtime "$PIM_CAMERA_RUNTIME_JSON" '
        if ($runtime | length) == 1 and
           ($runtime[0] | type) == "object" and
           ($runtime[0].VHL_CAM | type) == "object" and
           ($runtime[0].ORD | type) == "object" and
           ($runtime[0].VCM | type) == "object" and
           (($runtime[0].VHL_CAM.vhl_name // "") | type) == "string"
        then ($runtime[0].VHL_CAM.vhl_name // "")
        else error("invalid camera runtime") end
    ' 2>/dev/null) || {
        runtime_path_confirmed_missing && runtime_unavailable
        config_invalid
    }

    # Cache only a validated answer from an unchanged runtime inode.  The runtime
    # publisher replaces the JSON atomically; if it changes while jq is reading,
    # this invocation keeps its coherent result but the next invocation reparses.
    # A runtime that publishes no usable VHL name is a stable answer too, so it
    # is recorded as an explicit sentinel rather than reparsed every cron tick.
    runtime_id_after=$(runtime_identity || true)
    cache_value=""
    if [[ -z "$VHL_NAME" ]]; then
        cache_value=$VHL_CACHE_EMPTY
    elif [[ "$VHL_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        cache_value=$VHL_NAME
    fi
    if [[ "$runtime_id_after" == "$runtime_id" && -n "$cache_value" ]]; then
        cache_tmp=$(mktemp "${CACHE_PATH}.tmp.XXXXXX" 2>/dev/null || true)
        if [[ -n "$cache_tmp" ]]; then
            if printf '%s\t%s\n' "$runtime_id" "$cache_value" > "$cache_tmp" &&
               chmod 0600 "$cache_tmp" &&
               cache_destination_safe &&
               mv -f -- "$cache_tmp" "$CACHE_PATH"; then
                cache_tmp=""
            fi
            [[ -z "$cache_tmp" ]] || rm -f -- "$cache_tmp"
        fi
    fi
fi
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
