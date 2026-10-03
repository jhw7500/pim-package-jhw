#!/usr/bin/env bash
set -euo pipefail

target="root@192.168.214.4"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
package_root="$(cd -- "$(dirname -- "$0")/.." && pwd)/dist/pim"
plugin="$package_root/usr/lib/gstreamer-1.0/libgstvpu.so"
wrapper="$package_root/usr/lib/libfslvpuwrap.so.3.0.0"
expected_plugin="d509fb1b98d733e2202fc07e4c722cff7164243cb52a0a6ba49e5dffa3b24702"
expected_wrapper="acfec82c89ee84c9009d4ea3c31b20cdf892010481a27c20d18fbfdd5c8a3384"
run_id="imx-vpu-758b3b1-$(date -u +%Y%m%dT%H%M%SZ)"
remote_dir="/root/camtest/$run_id"

test "$(sha256sum "$plugin" | awk '{print $1}')" = "$expected_plugin"
test "$(sha256sum "$wrapper" | awk '{print $1}')" = "$expected_wrapper"

ssh "${ssh_opts[@]}" "$target" "install -d -o root -g root -m 0700 '$remote_dir/new'"
scp "${ssh_opts[@]}" "$plugin" "$target:$remote_dir/new/libgstvpu.so"
scp "${ssh_opts[@]}" "$wrapper" "$target:$remote_dir/new/libfslvpuwrap.so.3.0.0"

ssh "${ssh_opts[@]}" "$target" bash -s -- \
  "$remote_dir" "$expected_plugin" "$expected_wrapper" <<'REMOTE'
set -euo pipefail
umask 077

work=$1
expected_plugin=$2
expected_wrapper=$3
active_plugin=/usr/lib/gstreamer-1.0/libgstvpu.so
active_wrapper=/usr/lib/libfslvpuwrap.so.3.0.0
active_link=/usr/lib/libfslvpuwrap.so.3
backup="$work/backup"
report="$work/result.log"
armed=0
restoring=0

exec > >(tee -a "$report") 2>&1

wait_for_stack() {
    local n
    for n in $(seq 1 165); do
        if systemctl is-active --quiet cam-operate.service &&
           pgrep -x gstApp >/dev/null &&
           pgrep -x vcm >/dev/null &&
           pgrep -x ord >/dev/null &&
           pgrep -x vsd >/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

restore() {
    local original_rc=$? restore_rc=0
    trap - EXIT INT TERM HUP
    test "$armed" -eq 1 || exit "$original_rc"
    test "$restoring" -eq 0 || exit 97
    restoring=1
    set +e

    echo "RESTORE begin"
    systemctl stop cam-operate.service || restore_rc=1
    install -o root -g root -m 0755 "$backup/libgstvpu.so" "$active_plugin" || restore_rc=1
    install -o root -g root -m 0755 "$backup/libfslvpuwrap.so.3.0.0" "$active_wrapper" || restore_rc=1
    ln -sfn "$(cat "$backup/wrapper-link.txt")" "$active_link" || restore_rc=1
    ldconfig || restore_rc=1

    restored_plugin=$(sha256sum "$active_plugin" 2>/dev/null | awk '{print $1}')
    restored_wrapper=$(sha256sum "$active_wrapper" 2>/dev/null | awk '{print $1}')
    test "$restored_plugin" = "$(cat "$backup/plugin.sha256")" || restore_rc=1
    test "$restored_wrapper" = "$(cat "$backup/wrapper.sha256")" || restore_rc=1

    systemctl start cam-operate.service || restore_rc=1
    systemctl start ord-operate.service || restore_rc=1
    wait_for_stack || restore_rc=1
    sleep 15
    systemctl is-active cam-operate.service ord-operate.service sd-mount.service vsd-operate.service || restore_rc=1
    pgrep -a gstApp || restore_rc=1
    printf 'restored_hashes\n%s  %s\n%s  %s\n' \
        "$restored_plugin" "$active_plugin" "$restored_wrapper" "$active_wrapper"
    if test "$restore_rc" -ne 0; then
        echo "RESTORE failed; evidence=$work" >&2
        exit 96
    fi
    echo "RESTORE pass; evidence=$work"
    exit "$original_rc"
}
trap restore EXIT INT TERM HUP

echo "TEST begin $(date -u +%FT%TZ)"
echo "evidence=$work"
install -d -o root -g root -m 0700 "$backup"
test -f "$active_plugin"
test -f "$active_wrapper"
test -L "$active_link"
cp -a "$active_plugin" "$backup/libgstvpu.so"
cp -a "$active_wrapper" "$backup/libfslvpuwrap.so.3.0.0"
readlink "$active_link" > "$backup/wrapper-link.txt"
sha256sum "$active_plugin" | awk '{print $1}' > "$backup/plugin.sha256"
sha256sum "$active_wrapper" | awk '{print $1}' > "$backup/wrapper.sha256"
chmod 0600 "$backup"/* "$report" "$work/new/"*
armed=1

echo "baseline"
dpkg-query -W pim-mp
jq -e '.VHL_CAM.enc == "h265"' /root/shared_v/edgeconf_pim.json >/dev/null
jq -c '.VHL_CAM | {enc,tmp_path,vhl_name,muxer,i2c1:{ch2:.i2c1.ch2.enable,ch3:.i2c1.ch3.enable},i2c2:{ch0:.i2c2.ch0.enable,ch1:.i2c2.ch1.enable}}' /root/shared_v/edgeconf_pim.json
systemctl is-active cam-operate.service ord-operate.service sd-mount.service vsd-operate.service
sha256sum "$active_plugin" "$active_wrapper"
pgrep -a gstApp

test "$(sha256sum "$work/new/libgstvpu.so" | awk '{print $1}')" = "$expected_plugin"
test "$(sha256sum "$work/new/libfslvpuwrap.so.3.0.0" | awk '{print $1}')" = "$expected_wrapper"

echo "install test pair"
systemctl stop cam-operate.service
if pgrep -x gstApp >/dev/null; then
    echo "gstApp survived cam-operate stop" >&2
    exit 1
fi
install -o root -g root -m 0755 "$work/new/libgstvpu.so" "$active_plugin"
install -o root -g root -m 0755 "$work/new/libfslvpuwrap.so.3.0.0" "$active_wrapper"
ln -sfn libfslvpuwrap.so.3.0.0 "$active_link"
ldconfig
test "$(sha256sum "$active_plugin" | awk '{print $1}')" = "$expected_plugin"
test "$(sha256sum "$active_wrapper" | awk '{print $1}')" = "$expected_wrapper"

echo "plugin inspection"
registry="/tmp/gst-registry-$PPID-$$.bin"
GST_REGISTRY="$registry" gst-inspect-1.0 vpuenc_h264 | grep -E 'Long-name|profile|level|qp-min|qp-max' | head -20
GST_REGISTRY="$registry" gst-inspect-1.0 vpuenc_hevc | grep -E 'Long-name|profile|level|qp-min|qp-max' | head -20
rm -f "$registry"
if ldd /usr/local/bin/gstApp | grep -q 'not found'; then
    ldd /usr/local/bin/gstApp | grep 'not found'
    exit 1
fi

echo "start test stack"
start_epoch=$(date +%s)
systemctl start cam-operate.service
systemctl start ord-operate.service
wait_for_stack
sleep 35
pid1=$(pgrep -xo gstApp)
test -n "$pid1"
grep -E 'libgstvpu|libfslvpuwrap' "/proc/$pid1/maps"
grep -q 'libgstvpu' "/proc/$pid1/maps"
grep -q 'libfslvpuwrap' "/proc/$pid1/maps"
test "$(sha256sum "/proc/$pid1/root$active_plugin" | awk '{print $1}')" = "$expected_plugin"
test "$(sha256sum "/proc/$pid1/root$active_wrapper" | awk '{print $1}')" = "$expected_wrapper"

runtime=/run/pim-camera/config/pim_runtime.json
test -f "$runtime"
jq -e '.VHL_CAM.enc == "h265"' "$runtime" >/dev/null
tmp_path=$(jq -er '.VHL_CAM.tmp_path' "$runtime")
vhl_name=$(jq -er '.VHL_CAM.vhl_name' "$runtime")
muxer=$(jq -er '.VHL_CAM.muxer' "$runtime")
recent_parts=$(find "$tmp_path" -maxdepth 1 -type f -name "${vhl_name}_*-ch*.${muxer}.part" -mmin -2 -print | sort)
test -n "$recent_parts"
printf 'recent_active_fragments\n%s\n' "$recent_parts"
while IFS= read -r part; do stat -c '%y %s %n' "$part"; done <<< "$recent_parts"
test -f /tmp/start_video_time
stat -c 'start_video_time=%y size=%s' /tmp/start_video_time

# 창 시작 시각을 파일 mtime 으로 박아 둔다.  아래에서 "그 시각 이후 수정된 조각"을
# 요구하는 기준이 된다.
window_ref=$(mktemp)
echo "stability window"
sleep 20
pid2=$(pgrep -xo gstApp)
test "$pid1" = "$pid2"
systemctl is-active cam-operate.service ord-operate.service sd-mount.service vsd-operate.service
ps -o pid=,etimes=,stat=,cmd= -p "$pid2"
# 존재가 아니라 **전진**을 요구한다.  `-mmin -2` 창은 sleep 20 보다 넓으므로, 인코딩이
# 창 동안 멈춰도 직전 조각이 그 창에 그대로 남고 크기도 0 보다 커서 "존재 + 크기>0" 검사는
# 새 바이트 없이 통과한다 — 멈춘 VPU 파이프라인이 TEST pass 를 받는다 (Codex 지적, P1).
# `-newer "$window_ref"` 는 창 시작 이후 mtime 이 갱신된 것만 고르므로 "창 동안 바이트가
# 쓰였다"를 직접 표현하고, 기존 조각의 성장과 새 조각 생성을 모두 포함한다.
# find 가 경로를 직접 비교하므로 조각 이름에 공백이 있어도 안전하다.
progressed=$(find "$tmp_path" -maxdepth 1 -type f -name "${vhl_name}_*-ch*.${muxer}.part" -newer "$window_ref" -print | sort)
rm -f "$window_ref"
if [ -z "$progressed" ]; then
    echo "no fragment advanced during the stability window: encoding stalled" >&2
    find "$tmp_path" -maxdepth 1 -type f -name "${vhl_name}_*-ch*.${muxer}.part" -mmin -2 \
        -exec stat -c '  %y %s %n' {} + >&2
    exit 1
fi
printf 'fragments_written_during_window\n%s\n' "$progressed"
while IFS= read -r part; do
    size=$(stat -c %s "$part")
    test "$size" -gt 0
    stat -c '%y %s %n' "$part"
done <<< "$progressed"

echo "journal since test start"
# journalctl 을 파이프로 grep 하지 않는다.  `journalctl | grep -q` 는 grep -q 가 첫 매치에서
# 파이프를 닫아 journalctl 이 SIGPIPE 로 141 을 내고, 이 블록의 `set -o pipefail` 아래에서
# 그 141 이 파이프라인 상태가 되어 **매치가 있는데 if 가 거짓**이 된다 — fatal 서명이 있는데
# 없다고 읽는다 (Codex 지적 P1, 실측 재현: 매치를 먼저 내고 많이 출력하는 생산자로 rc=141).
# 파일로 받아 읽으면 생산자가 끝까지 돌아 그 경로가 없고, journalctl 을 두 번 돌리지도 않는다.
jlog=$(mktemp)
journalctl -u cam-operate.service --since "@$start_epoch" --no-pager > "$jlog"
tail -120 "$jlog"
if grep -Eiq 'segfault|core dumped|symbol lookup error|undefined symbol' "$jlog"; then
    echo "fatal runtime signature found" >&2
    grep -Ein 'segfault|core dumped|symbol lookup error|undefined symbol' "$jlog" >&2
    rm -f "$jlog"
    exit 1
fi
rm -f "$jlog"

echo "TEST pass $(date -u +%FT%TZ)"
REMOTE

echo "remote_evidence=$remote_dir/result.log"
