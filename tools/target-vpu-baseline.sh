#!/usr/bin/env bash
set -euo pipefail

target="root@192.168.214.4"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

ssh "${ssh_opts[@]}" "$target" 'set -eu
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
gst-inspect-1.0 vpuenc_h264 | grep -E "Long-name|qp-min|qp-max|profile|level" | head -n 20
echo "missing-libraries"
if ldd /usr/local/bin/gstApp | grep -q "not found"; then
  ldd /usr/local/bin/gstApp | grep "not found"
  exit 1
fi
echo none
'
