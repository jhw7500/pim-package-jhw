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

PATH_TO_TRANSFER="/mnt/sd_cam"
FILE_TO_TRANSFER=0
INTERVAL=5

transfer_check=""
FILE_CHECK=/tmp/file_check

JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
FILE_JSON=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$FILE_JSON" ] || [ "$f" -nt "$FILE_JSON" ]; then
        FILE_JSON="$f"
    fi
done
rec_time=$(cat $FILE_JSON | grep recording_time | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
logger -p local0.notice "[$KEY][$tag:$LINENO] ip:$FTP_SERVER, id:$USERNAME, pwd:$PASSWORD, remote_dir:$REMOTE_DIR, json:$FILE_JSON, rec_time:$rec_time"

while true; do
    #if [[ $cur_min -ne $(date '+%M') && $(date '+%S') -ge 5 ]]; then
    file_check=$(cat $FILE_CHECK 2>/dev/null| tr -d '\n')
    #if [ "$transfer_check" == "OK"  ]; then
    if [[ -n "$file_check" ]]; then
        logger -p local0.info "[$KEY][$tag:$LINENO] file_check : $file_check"
        FILE_TO_TRANSFER=$(date '+%Y%m%d_%H%M00' -d "$rec_time min ago")
        logger -p local0.notice "[$KEY][$tag:$LINENO] ncftpput -u $USERNAME -p $PASSWORD $FTP_SERVER $REMOTE_DIR $PATH_TO_TRANSFER/*$FILE_TO_TRANSFER*"
        ncftpput -u "$USERNAME" -p "$PASSWORD" "$FTP_SERVER" "$REMOTE_DIR" $PATH_TO_TRANSFER/*$FILE_TO_TRANSFER*
        logger -p local0.notice "[$KEY][$tag:$LINENO] ncftp end"
        cat /dev/null > $FILE_CHECK
        #cur_min=$(date '+%M')
    fi
    sleep "$INTERVAL"
done
