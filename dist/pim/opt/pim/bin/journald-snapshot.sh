#!/bin/bash
set -euo pipefail
tag=$(basename "$0")
KEY="LOG"
SRC="/run/log/journal"
DIR="/var/log/cantops/journald"
DST="$DIR/$(date +%Y%m%d)"
MAX_CNT=30
MAX_SIZE=$((10 * 1024 * 1024 * 1024))
mkdir -p "$DST"

# 저널 파일들만 증분 복사(덮어쓰기 in-place)
rsync -a --inplace --no-whole-file --chmod=Fu=rw,Fg=r,Fa=r "$SRC"/ "$DST"/

# 보관 정책(예: 30일)
#find /var/log/cantops/journald -mindepth 1 -maxdepth 1 -type d -mtime +30 -print -exec rm -rf {} +
cnt=$(find "$DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
size=$(du -sb "$DIR" | awk '{print $1}')
if (( cnt > MAX_CNT )); then
    logger -p local0.notice "[$KEY][$tag:$LINENO] journald file cnt : $cnt > $MAX_CNT"
    del=$((cnt - MAX_CNT))
    find "$DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T+ %p\n' | sort | head -n $del | cut -d' ' -f2- | xargs -r rm -rf --
fi

size=$(du -sb "$DIR" | awk '{print $1}')
if (( size > MAX_SIZE )); then
    logger -p local0.notice "[$KEY][$tag:$LINENO] journald file size : $size > $MAX_SIZE"
    find "$DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T+ %p\n' | sort | head -n 1 | cut -d' ' -f2- | xargs -r rm -rf --
fi

