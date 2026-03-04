#!/bin/bash
tag=$(basename "$0")
KEY="CPU"
#list=$1
JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
FILE_JSON=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$FILE_JSON" ] || [ "$f" -nt "$FILE_JSON" ]; then
        FILE_JSON="$f"
    fi
done
logger -p local0.notice "[$key][$tag:$LINENO] json_file : $FILE_JSON"
app=$(jq -r '.VHL_CAM.app' "$FILE_JSON")

limit=$1
#list="$app $2"
service=$app

logger -p local0.notice "[$KEY][$tag:$LINENO] service:$app, limit = $limit"
while true; do
pid=$(pgrep -f $service)
if [ ! -z "$pid" ]; then
    logger -p local0.notice "[$KEY][$tag:$LINENO] $service($pid) cpu limit $limit%"
    cpulimit -p $pid -l $limit
fi
sleep 10
done

logger -p local0.notice "[$KEY][$tag:$LINENO] exit"
