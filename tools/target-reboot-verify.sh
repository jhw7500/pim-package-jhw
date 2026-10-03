#!/usr/bin/env bash
set -euo pipefail

host=root@192.168.214.4
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

ready=0
for n in $(seq 1 120); do
    state=$(ssh "${ssh_opts[@]}" "$host" 'set -u
lifecycle=$(jq -r ".lifecycle // empty" /run/pim-camera/owner.json 2>/dev/null || true)
services=$(systemctl is-active cam-operate.service ord-operate.service sd-mount.service vsd-operate.service 2>/dev/null | tr "\n" " ")
procs=""
for p in gstApp ord vcm vsd; do
    if pgrep -x "$p" >/dev/null; then procs="${procs}1"; else procs="${procs}0"; fi
done
printf "%s|%s|%s" "$lifecycle" "$services" "$procs"
' 2>/dev/null || true)
    case "$state" in
        'ACTIVE|active active active active |1111')
            ready=1
            echo "stack_ready=$(date -u +%FT%TZ)"
            break
            ;;
    esac
    if test $((n % 6)) -eq 0; then
        echo "waiting_for_stack elapsed=$((n * 5))s state=$state"
    fi
    sleep 5
done
test "$ready" -eq 1

ssh "${ssh_opts[@]}" "$host" bash -s <<'REMOTE'
set -euo pipefail

echo package
dpkg-query -W pim-mp

echo services
systemctl is-active cam-operate.service ord-operate.service sd-mount.service vsd-operate.service

echo processes
for p in gstApp ord vcm vsd; do pgrep -a -x "$p"; done

echo recovery
status=$(/opt/pim/bin/cam-recoveryctl status --json)
printf '%s\n' "$status"
jq -e '.owner.lifecycle == "ACTIVE" and .pending == null and .active == null' <<< "$status" >/dev/null

echo vpu-hashes
plugin_hash=$(sha256sum /usr/lib/gstreamer-1.0/libgstvpu.so | awk '{print $1}')
wrapper_hash=$(sha256sum /usr/lib/libfslvpuwrap.so.3.0.0 | awk '{print $1}')
printf '%s  %s\n' "$plugin_hash" /usr/lib/gstreamer-1.0/libgstvpu.so
printf '%s  %s\n' "$wrapper_hash" /usr/lib/libfslvpuwrap.so.3.0.0
test "$plugin_hash" = d83594447b7dac184c019371c0c296b72345585913ed03adf6e0a56f60a38b27
test "$wrapper_hash" = 03980af335703b0352a9a43f2dff62657671db5aaf822e476a415d5e762a4927

echo h265-runtime
jq -e '.VHL_CAM.enc == "h265"' /run/pim-camera/config/pim_runtime.json >/dev/null
pid=$(pgrep -xo gstApp)
grep -E 'libgstvpu|libfslvpuwrap' "/proc/$pid/maps"

parts=""
for n in $(seq 1 24); do
    parts=$(find /dev/shm -maxdepth 1 -type f -name 'VD3001_*-ch*.mp4.part' -mmin -2 -print | sort)
    test -n "$parts" && break
    sleep 5
done
test -n "$parts"
printf '%s\n' "$parts"
while IFS= read -r file; do
    size=$(stat -c %s "$file")
    test "$size" -gt 0
    stat -c '%y %s %n' "$file"
done <<< "$parts"

echo fatal-signatures
# journalctl 을 파이프로 grep 하지 않는다.  `journalctl | grep -q` 는 grep -q 가 첫 매치에서
# 파이프를 닫아 journalctl 이 SIGPIPE 로 141 을 내고, 이 블록의 `set -o pipefail` 아래에서
# 그 141 이 파이프라인 상태가 되어 **매치가 있는데 if 가 거짓**이 된다 — fatal 서명이 있는데
# 없다고 읽는다 (Codex 지적 P1, 실측 재현: 매치를 먼저 내고 많이 출력하는 생산자로 rc=141).
# 파일로 받아 읽으면 생산자가 끝까지 돌아 그 경로가 없고, journalctl 을 두 번 돌리지도 않는다.
jlog=$(mktemp)
journalctl -b -u cam-operate.service --no-pager > "$jlog"
if grep -Eiq 'segfault|core dumped|symbol lookup error|undefined symbol' "$jlog"; then
    grep -Ei 'segfault|core dumped|symbol lookup error|undefined symbol' "$jlog"
    rm -f "$jlog"
    exit 1
fi
rm -f "$jlog"
echo none
echo RECOVERY_PASS
REMOTE
