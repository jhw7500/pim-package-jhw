#!/bin/bash
# wifi_boot_diag.sh
#
# 가설 검증용 진단 스크립트
#   1) 부팅 직후(연결 실패 상태)와
#   2) /opt/cis/bin/update_network.py 재실행 직후(연결 성공 상태)
#   를 비교해 wpa_supplicant / netplan-wpa-* / 인터페이스 상태 차이를 기록한다.
#
# 사용법:
#   부팅 직후:                 ./wifi_boot_diag.sh boot
#   update_network.py 재실행 후: ./wifi_boot_diag.sh after
#
# 결과 파일: /tmp/wifi_boot_diag_<stage>_<UTC ts>.log
#
# 비밀번호/PSK 는 가능한 한 redact 한다.

set -u

STAGE="${1:-boot}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG="/tmp/wifi_boot_diag_${STAGE}_${TS}.log"
WLAN="$(python3 /opt/cis/bin/getconfval.py dev_wlan 2>/dev/null | tr -d '\r\n')"
[ -z "$WLAN" ] && WLAN="wlan0"

redact() { sed -E 's/(psk|password)=.*/\1=<redacted>/Ig; s/(password:).*/\1 <redacted>/Ig'; }

section() { printf '\n===== %s =====\n' "$1"; }

# all stdout/stderr -> log + console
exec > >(tee -a "$LOG") 2>&1

echo "wifi_boot_diag stage=$STAGE ts=$TS wlan=$WLAN host=$(hostname)"
echo "uptime: $(uptime)"
echo "kernel: $(uname -r)"
echo "package: $(dpkg-query -W -f='${Package}=${Version}\n' pim-mp cis 2>/dev/null | grep -v '=$')"

section "ps wpa_supplicant / netplan-wpa"
ps -eo pid,ppid,etimes,stat,cmd | grep -E 'wpa_supplicant|netplan-wpa' | grep -v grep || echo "(none)"

section "systemctl wpa_supplicant.service"
systemctl is-active wpa_supplicant 2>&1 || true
systemctl is-enabled wpa_supplicant 2>&1 || true
systemctl status wpa_supplicant --no-pager -n 8 2>&1 || true

section "systemctl netplan-wpa-* (all)"
mapfile -t UNITS < <(systemctl list-units --type=service --all 'netplan-wpa-*' --no-legend --no-pager 2>/dev/null | awk '{print $1}')
if [ "${#UNITS[@]}" -eq 0 ]; then
  echo "(no netplan-wpa-* units found via list-units)"
  # 일부 환경에서는 transient 라 list-units 가 못 잡을 수 있음
  systemctl list-unit-files 'netplan-wpa-*' --no-pager 2>/dev/null || true
else
  for u in "${UNITS[@]}"; do
    echo "--- $u ---"
    systemctl status "$u" --no-pager -n 15 2>&1 || true
  done
fi

section "wpa_cli status (ctrl_iface 두 곳 다 시도)"
for CTRL in /run/wpa_supplicant /var/run/wpa_supplicant; do
  echo "--- ctrl=$CTRL ---"
  ls -la "$CTRL" 2>&1 | head -10
  wpa_cli -p "$CTRL" -i "$WLAN" status 2>&1 | head -25 || true
done

section "iw dev / reg / rfkill"
iw dev 2>&1
echo "---"
iw reg get 2>&1 | head -20
echo "---"
rfkill list 2>&1 || echo "(rfkill missing)"

section "ip link / addr"
ip -br link
echo "---"
ip -br addr

section "/etc/netplan and /run/netplan files"
ls -la /etc/netplan/ 2>&1
echo "---"
ls -la /run/netplan/ 2>&1 || echo "(no /run/netplan)"
echo "--- /etc/netplan/${WLAN}.yaml ---"
[ -f "/etc/netplan/${WLAN}.yaml" ] && redact < "/etc/netplan/${WLAN}.yaml" || echo "(not present)"
echo "--- /run/netplan/wpa-supplicant-${WLAN}.conf ---"
[ -f "/run/netplan/wpa-supplicant-${WLAN}.conf" ] && redact < "/run/netplan/wpa-supplicant-${WLAN}.conf" || echo "(not present)"

section "/etc/wpa_supplicant/wpa_supplicant.conf"
[ -f /etc/wpa_supplicant/wpa_supplicant.conf ] && redact < /etc/wpa_supplicant/wpa_supplicant.conf || echo "(not present)"

section "journal: networkd / netplan-wpa-* / wpa_supplicant (this boot)"
journalctl --no-pager -b 0 -u systemd-networkd -u 'netplan-wpa-*' -u wpa_supplicant 2>&1 | tail -200

section "journal: cis tag (this boot)"
journalctl --no-pager -b 0 -t cis -t cis.sh -t WiFiCHK -t WiFiLOG 2>&1 | tail -120

section "kernel dmesg (wifi / driver / regdomain)"
dmesg -T 2>/dev/null | grep -iE 'wlan|wlp|wpa|wifi|laird|lwb|regulatory|firmware' | tail -80 || \
  journalctl --no-pager -k -b 0 2>&1 | grep -iE 'wlan|wlp|wpa|wifi|laird|lwb|regulatory|firmware' | tail -80

section "done"
echo "log saved: $LOG"
