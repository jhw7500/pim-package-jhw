#!/bin/bash
set -euo pipefail
tag=$(basename "$0")
KEY="LOG"
SRC="/run/log/journal"
DIR="/var/log/cantops/journald"
DST="$DIR/$(date +%Y%m%d -d '1 min ago')"
MAX_CNT=30
MAX_SIZE=$((10 * 1024 * 1024 * 1024))
mkdir -p "$DST"

# cron(매분)·부팅·종료·creboot 가 같은 사본을 동시에 쓰지 않게 한다
exec 9>/run/journald-snapshot.lock
flock -w 20 9 || { logger -p local0.notice "[$KEY][$tag:$LINENO] journald snapshot skip: lock busy"; exit 0; }

# 쓰는 중인 파일(이름에 @ 없음)은 부팅마다 다른 이름으로 복사한다. 같은 이름이면 다음 부팅의 첫 복사가
# 이전 부팅의 마지막 회전 이후 구간을 덮는다(#205). 회전본보다 먼저 복사해야 그 사이 회전이 일어나도
# 빠지는 구간이 없다. 디스크에 내리는 일은 회전본 복사 뒤 한 번에 한다(아래).
boot=$(tr -d - < /proc/sys/kernel/random/boot_id)
while IFS= read -r f; do
    rel=${f#"$SRC"/}
    live="$DST/${rel%.journal}@live-$boot.journal"
    mkdir -p "$(dirname "$live")"
    rsync -a --inplace --no-whole-file --chmod=Fu=rw,Fg=r,Fa=r "$f" "$live"
done < <(find "$SRC" -name '*.journal' ! -name '*@*')

# 회전본(이름에 @)은 같은 이름으로 증분 복사(덮어쓰기 in-place)
rsync -a --inplace --no-whole-file --chmod=Fu=rw,Fg=r,Fa=r --include='*@*' --exclude='*.journal' "$SRC"/ "$DST"/

# 실행 사이에 회전이 끼면 live 사본에서 밀려난 구간은 방금 만든 회전본 사본에만 있다. 둘을 함께 디스크에
# 내려야 급정지 때 그 구간이 사라지지 않는다. 회전본이 수백 개라 파일마다 fsync 하지 않고 파일시스템을 한 번 내린다.
sync -f "$DST"

# 보관 정책(예: 30일)
#find /var/log/cantops/journald -mindepth 1 -maxdepth 1 -type d -mtime +30 -print -exec rm -rf {} +
cnt=$(find "$DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
size=$(du -sb "$DIR" | awk '{print $1}')
if (( cnt > MAX_CNT )); then
    logger -p local0.notice "[$KEY][$tag:$LINENO] journald file cnt : $cnt > $MAX_CNT"
    del=$((cnt - MAX_CNT))
    find "$DIR" -mindepth 1 -maxdepth 1 -type d | sort | head -n $del | xargs -r rm -rf --
fi

size=$(du -sb "$DIR" | awk '{print $1}')
if (( size > MAX_SIZE )); then
    logger -p local0.notice "[$KEY][$tag:$LINENO] journald file size : $size > $MAX_SIZE"
    find "$DIR" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1 | xargs -r rm -rf --
fi

