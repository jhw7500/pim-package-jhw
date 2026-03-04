#!/usr/bin/env bash

tag=$(basename "$0")
KEY=PKG

set -Ee -o pipefail

err_report() {
    local ec=$?
    local line=${BASH_LINENO[0]:-0}
    local cmd=${BASH_COMMAND}
    trap - ERR
    echo "[$KEY][$tag:$line] update failed (exit=$ec): $cmd" >&2
    logger -p local0.err "[$KEY][$tag:$line] update failed (exit=$ec): $cmd"
    exit "$ec"
}

trap err_report ERR
JSON_PREFIX="ord_vcm_"
JSON_SUFFIX=".json"
FILE_JSON=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$FILE_JSON" ] || [ "$f" -nt "$FILE_JSON" ]; then
        FILE_JSON="$f"
    fi
done

if [ -z "$FILE_JSON" ] || [ ! -f "$FILE_JSON" ]; then
logger -p local0.err "[$KEY][$tag:$LINENO] ord_vcm json not found under /root/shared_v (${JSON_PREFIX}*${JSON_SUFFIX})"
    exit 1
fi

if ! command -v jq &> /dev/null
then
    logger -p local0.err "[$KEY][$tag:$LINENO] jq could not be found. Please install jq to run this script."
    exit 1
fi

echo -e "\e[32mplease wait for update $FILE_JSON\e[0m"
logger -p local0.notice "[$KEY][$tag:$LINENO] please wait for update $FILE_JSON$"

if ! jq -e . "$FILE_JSON" > /dev/null 2>&1; then
    logger -p local0.err "[$KEY][$tag:$LINENO] invalid JSON: $FILE_JSON"
    echo "[$KEY][$tag:$LINENO] invalid JSON: $FILE_JSON" >&2
    exit 1
fi

# Ensure expected top-level objects exist
jq '(.ORD //= {}) | (.VCM //= {}) | (.ETC //= {})' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"

#clean for jq format
jq '.ORD |= if . == null then . else . end' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"

echo "ORD check"
jq '.ORD.vib_enable |= if . == null then false else . end |
.ORD.ovl_buffering |= if . == null then 0 else . end |
.ORD.evt_copy_delay |= if . == null then 15 else . end |
.ORD.err_send_period |= if . == null then 180 else . end |
.ORD.disk_limit_per = 90
' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"

echo "VCM check"
jq 'del (.VCM.file_time_recording)' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"
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
 .ETC.file_check_reboot |= if . == null then true else . end |
 .ETC.startup_grace_extra_sec |= if . == null then 10 else . end |
 .ETC.init_cooldown_sec |= if . == null then 40 else . end |
 .ETC.stream_active_window_sec |= if . == null then 10 else . end' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"


sync
echo -e "\e[32mcomplete update $FILE_JSON\e[0m"
logger -p local0.notice "[$KEY][$tag:$LINENO] complete update $FILE_JSON$"
