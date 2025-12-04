#!/usr/bin/env bash

tag=$(basename "$0")
KEY=PKG
JSON_PREFIX="ord_vcm_"
JOSN_SUFFIX=".json"
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')

if ! command -v jq &> /dev/null
then
    logger -p local0.err "[$KEY][$tag:$LINENO] jq could not be found. Please install jq to run this script."
    exit 1
fi

echo -e "\e[32mplease wait for update $FILE_JSON\e[0m"
logger -p local0.notice "[$KEY][$tag:$LINENO] please wait for update $FILE_JSON$"
#clean for jq format
jq '.ORD |= if . == null then . else . end' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"

echo "ORD check"
jq '.ORD.vib_enable |= if . == null then false else . end |
.ORD.ovl_buffering |= if . == null then 0 else . end |
.ORD.evt_copy_delay |= if . == null then 15 else . end |
.ORD.err_send_period |= if . == null then 300 else . end' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"

echo "VCM check"
jq 'del (.VCM.file_time_recording)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
jq '.VCM.file_time_check |= if . == null then true else . end |
.VCM.srt_delay |= if . == null then 0 else . end |
.VCM.srt_buffering |= if . == null then 0 else . end |
.VCM.ops_enable |= if . == null then false else . end |
.VCM.ops_period |= if . == null then 0 else . end |
.VCM.ops_buffering |= if . == null then 0 else . end |
.VCM.ops_delay |= if . == null then 0 else . end |
.VCM.vib_test |= if . == null then false else . end' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"

echo "ETC check"
jq '.ETC.file_check_delay |= if . == null then 10 else . end |
.ETC.file_check_reboot |= if . == null then true else . end' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"


sync
echo -e "\e[32mcomplete update $FILE_JSON\e[0m"
logger -p local0.notice "[$KEY][$tag:$LINENO] complete update $FILE_JSON$"
