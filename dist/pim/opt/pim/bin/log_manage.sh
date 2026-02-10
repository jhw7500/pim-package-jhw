#!/bin/bash
KEY=DOT
INPUT_PATH=$1
LIMIT=$2
tag=$(basename "$0")
cnt=0
if [ -z "$INPUT_PATH" ];then
    logger -p local0.crit "[$KEY][$tag:$LINENO] failed : you should input path"
    exit 1
fi

#echo "========================="
#echo "input path : " $INPUT_PATH
logger -p local0.notice "[$KEY][$tag:$LINENO] dot path : $INPUT_PATH/dot, gst path : $INPUT_PATH/gst, limit cnt : $LIMIT, limit size : $3 GB"

if [ ! -d "$INPUT_PATH/dot" ]; then
    logger -p local0.crit "[$KEY][$tag:$LINENO] failed : $INPUT_PATH/dot is not directory"
    exit 1
fi

if [ ! -d "$INPUT_PATH/gst" ]; then
    logger -p local0.crit "[$KEY][$tag:$LINENO] failed : $INPUT_PATH/gst is not directory"
    exit 1
fi

if [ $LIMIT -le 1 ]; then
    logger -p local0.crit "[$KEY][$tag:$LINENO] failed : LIMIT:$LIMIT greater than 1"
    exit 1
fi

cnt=$(ls -lt $1/dot | grep ^- | wc -l)
echo "dot:$cnt"
if [ $cnt -gt $LIMIT ]; then
    logger -p local0.info "[$KEY][$tag:$LINENO] dot file cnt $cnt > $LIMIT ($tailcnt)"
    #ls -pr $INPUT_PATH | grep -v '/$' | tail -n 1 | xargs -t -I %% sh -c '{ rm -f /var/log/cantops/dot/%%; }'
    #find $INPUT_PATH/dot -maxdepth 1 -type f | sort -r | tail -$tailcnt| xargs rm -f
    find $INPUT_PATH/dot -maxdepth 1 -type f -printf '%T+ %p\n' | sort | head -n -$LIMIT | cut -d' ' -f2- | xargs -r rm -f
fi

cnt=$(ls -lt $1/gst | grep ^- | wc -l)
echo "gst:$cnt"
if [ $cnt -gt $LIMIT ]; then
    logger -p local0.info "[$KEY][$tag:$LINENO] gst file cnt $cnt > $LIMIT ($tailcnt)"
    #ls -pr $INPUT_PATH | grep -v '/$' | tail -n 1 | xargs -t -I %% sh -c '{ rm -f /var/log/cantops/dot/%%; }'
    #find $INPUT_PATH/gst -maxdepth 1 -type f | sort -r | tail -$tailcnt| xargs rm -f
    find $INPUT_PATH/gst -maxdepth 1 -type f -printf '%T+ %p\n' | sort | head -n -$LIMIT | cut -d' ' -f2- | xargs -r rm -f
fi

MAX_SIZE=$(($3 * 1024 * 1024 * 1024))
current_size=$(du -sb $INPUT_PATH | awk '{print $1}')
if [ $current_size -gt $MAX_SIZE ]; then
    logger -p local0.err "[$KEY][$tag:$LINENO] $INPUT_PATH dir $current_size byte over $MAX_SIZE byte!"
    oldest_file=$(ls $INPUT_PATH | grep -E '\log-[0-9]{8}\.gz$' | sort | head -n 1)
    #echo "Deleting oldest log file: $oldest_file"
    logger -p local0.err "[$KEY][$tag:$LINENO] deleting oldest log file: $oldest_file"
    rm -f "$INPUT_PATH/$oldest_file"
    current_size=$(du -sb $INPUT_PATH | awk '{print $1}')
    logger -p local0.err "[$KEY][$tag:$LINENO] $INPUT_PATH dir $current_size byte"
fi
