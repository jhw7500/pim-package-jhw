#!/bin/bash
INPUT_PATH=$1
LIMIT=$2
SIZE=$3
KEY=$4
FILE_PATH=""
tag=$(basename "$0")
cnt=0
MAX_SIZE=$(($SIZE * 1024 * 1024))
JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
FILE_JSON=""
VHL_NAME_CACHE="/tmp/pim_vhl_name.cache"
VHL_NAME_CACHE_SRC="/tmp/pim_vhl_name.cache.src"
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$FILE_JSON" ] || [ "$f" -nt "$FILE_JSON" ]; then
        FILE_JSON="$f"
    fi
done

VHL_NAME=""
if [ -n "$FILE_JSON" ] && [ -f "$FILE_JSON" ]; then
    if [ -f "$VHL_NAME_CACHE" ] && [ -f "$VHL_NAME_CACHE_SRC" ]; then
        cache_src=$(cat "$VHL_NAME_CACHE_SRC" 2>/dev/null | tr -d '\n')
        if [ "$cache_src" = "$FILE_JSON" ] && [ ! "$FILE_JSON" -nt "$VHL_NAME_CACHE" ]; then
            VHL_NAME=$(cat "$VHL_NAME_CACHE" 2>/dev/null | tr -d '\n')
        fi
    fi

    if [ -z "$VHL_NAME" ]; then
        VHL_NAME=$(jq -r '(.VHL_CAM.vhl_name // "")' "$FILE_JSON" 2>/dev/null | tr -d '\n')
        if [ -n "$VHL_NAME" ] && [ "$VHL_NAME" != "null" ]; then
            printf "%s" "$VHL_NAME" > "$VHL_NAME_CACHE" 2>/dev/null
            printf "%s" "$FILE_JSON" > "$VHL_NAME_CACHE_SRC" 2>/dev/null
        fi
    fi
fi

if [ -n "$VHL_NAME" ] && [ "$VHL_NAME" != "null" ]; then
    KEY="$VHL_NAME"
fi

#echo "========================="
#echo "input path : " $INPUT_PATH

if [ ! -d "$INPUT_PATH" ]; then
    logger -p local0.crit "[$tag:$LINENO] failed : $INPUT_PATH is not directory"
    exit 1
fi

if [ $LIMIT -le 1 ]; then
    logger -p local0.crit "[$tag:$LINENO] failed : LIMIT:$LIMIT greater than 1"
    exit 1
fi

if [ -n "$KEY" ]; then
    FILE_PATH=$INPUT_PATH/$KEY*
    #cnt_cmd="ls -lt $FILE_PATH | grep ^- | wc -l"
else
    FILE_PATH=$INPUT_PATH
    #cnt_cmd="ls -lt $FILE_PATH | grep ^d | wc -l"
fi

#logger -p local0.notice "[$tag:$LINENO] path : $INPUT_PATH, key : $KEY, $limit cnt : $LIMIT, limit size : $SIZE MB"

while :; do
    current_size=$(du -sb $INPUT_PATH | awk '{print $1}')
    if [ $current_size -gt $MAX_SIZE ]; then
        #logger -p local0.info "[$tag:$LINENO] $INPUT_PATH dir $current_size byte over $MAX_SIZE byte!"
        oldest_file=$(ls -tr $FILE_PATH | head -n 1)
        #echo "Deleting oldest log file: $oldest_file"
        logger -p local0.notice "[$tag:$LINENO] $FILE_PATH size ($current_size > $MAX_SIZE) :deleting $oldest_file"
        rm -rf "$oldest_file"
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
    cnt=$(ls -lt $FILE_PATH | grep ^- | wc -l)
    if [ $cnt -gt $LIMIT ]; then
        #logger -p local0.info "[$tag:$LINENO] file cnt $cnt > $LIMIT ($tailcnt)"
        #del=$((cnt - LIMIT))
        #find $FILE_PATH* -maxdepth 1 -type f -printf '%T+ %p\n' | sort | head -n -$LIMIT | cut -d' ' -f2- | xargs -r rm -f
        oldest_file=$(ls -tr $FILE_PATH | head -n 1)
        logger -p local0.notice "[$tag:$LINENO] $FILE_PATH cnt ($cnt > $LIMIT) : deleting $oldest_file"
        rm -rf "$oldest_file"
        #cnt=$(ls -lt $FILE_PATH | grep ^- | wc -l)
        #logger -p local0.info "[$tag:$LINENO] $INPUT_PATH file cnt : $cnt"
        sleep 0.1
        continue
    fi
    break
done
