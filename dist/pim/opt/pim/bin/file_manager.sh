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
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
VHL_NAME=$(jq -r '.VHL_CAM.vhl_name' "$FILE_JSON")
if [ ! -z "$VHL_NAME" ]; then
    KEY=$VHL_NAME
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

