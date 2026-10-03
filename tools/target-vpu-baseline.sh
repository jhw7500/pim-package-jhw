#!/usr/bin/env bash
set -euo pipefail
# bare `test` 어서션은 set -e 로 죽을 때 아무것도 찍지 않는다 — 운영자는 "스크립트가
# 그냥 죽었다"만 본다 (세 파일 합쳐 27개 중 21개가 메시지 없음).  ERR 트랩 한 줄이면
# 어느 줄의 무슨 명령이 실패했는지 나온다.  ERR 은 set -e 가 종료시키는 바로 그 조건에서만
# 발동하므로(if 조건, ||/&& 의 비최종 항, ! 뒤는 제외) 거짓 소음이 없고, EXIT 트랩과는
# 별개라 기존 `trap restore EXIT INT TERM HUP` 와 공존한다 (@claude 지적, 실측 확인).
trap 'echo "FAILED rc=$? line=$LINENO: $BASH_COMMAND" >&2' ERR

target="root@192.168.214.4"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

ssh "${ssh_opts[@]}" "$target" 'set -eu
trap "echo \"FAILED rc=\$? line=\$LINENO: \$BASH_COMMAND\" >&2" ERR
echo "hostname=$(hostname)"
dpkg-query -W pim-mp
echo "camera-config"
jq -c ".VHL_CAM | {app,enc,cam_width,cam_height,fps}" /root/shared_v/edgeconf_pim.json
echo "services"
systemctl is-active cam-operate.service ord-operate.service sd-mount.service vsd-operate.service
echo "hashes"
sha256sum \
  /usr/lib/gstreamer-1.0/libgstvpu.so \
  /usr/lib/libfslvpuwrap.so.3.0.0 \
  /usr/local/bin/gstApp \
  /usr/local/bin/ord \
  /usr/local/bin/vcm \
  /usr/local/bin/vsd \
  /opt/pim/driver/max9296.ko
echo "vpu-plugin"
# 이 원격 블록은 set -eu 만이고 pipefail 이 없다.  그래서 생산자가 실패해도 마지막
# 명령(head/grep)이 0 을 내면 파이프라인이 0 이 되어 실패가 삼켜진다 — gst-inspect 가
# 죽거나 매치가 0 건이어도 vpu-plugin 절이 조용히 비고 baseline 은 성공으로 끝난다
# (Codex 지적 P2, 실측 재현: 생산자 rc 1 인데 파이프라인 rc 0).  그래서 상태를 따로 받고
# 매치가 비었는지도 본다.
gi=$(mktemp)
if ! gst-inspect-1.0 vpuenc_h264 > "$gi" 2>&1; then
  echo "gst-inspect-1.0 vpuenc_h264 failed:" >&2
  sed "s/^/  /" "$gi" >&2
  rm -f "$gi"
  exit 1
fi
props=$(grep -E "Long-name|qp-min|qp-max|profile|level" "$gi" | head -n 20)
if [ -z "$props" ]; then
  echo "vpuenc_h264 reported none of the expected properties" >&2
  rm -f "$gi"
  exit 1
fi
printf "%s\n" "$props"
rm -f "$gi"
echo "missing-libraries"
# 같은 이유로 ldd 의 상태를 따로 받는다.  ldd 자체가 실패하면 grep -q 는 매치를 못 찾고
# if 가 거짓이 되어 아래 echo none 에 도달한다 — "빠진 라이브러리 없음"을 성공으로
# 보고하는데 실제로는 검사를 못 한 것이다 (Codex 지적 P2, 실측 재현).
ld=$(mktemp)
if ! ldd /usr/local/bin/gstApp > "$ld" 2>&1; then
  echo "ldd /usr/local/bin/gstApp failed:" >&2
  sed "s/^/  /" "$ld" >&2
  rm -f "$ld"
  exit 1
fi
if grep -q "not found" "$ld"; then
  grep "not found" "$ld"
  rm -f "$ld"
  exit 1
fi
rm -f "$ld"
echo none
'
