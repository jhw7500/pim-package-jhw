#!/bin/bash
# repro_a_loop.sh — wifi 부팅 충돌 재현 루프 (옵션 A)
#
# 동작:
#   N회 반복:
#     1) device alive 확인 → 실패 시 STUCK
#     2) ssh로 reboot 트리거
#     3) INITIAL_WAIT 초 대기 (기본 60s)
#     4) ssh 재시도 (RETRY_COUNT 회, RETRY_INTERVAL 간격)
#     5) 성공 시 wifi_boot_diag.sh boot 실행 + 로그 회수
#     6) wpa_state 분류 → summary.csv 기록
#     실패 시 ALARM (마커파일 + exit 2) → 절대 자동 복구 X
#
# Resume:
#   ITER_START=N 환경변수로 N부터 이어서 시작
#
# Env (default):
#   DEVICE_IP=192.168.0.200  DEVICE_USER=root  DEVICE_PASS=root
#   ITER_COUNT=20  INITIAL_WAIT=60  RETRY_INTERVAL=30  RETRY_COUNT=5
#   ITER_START=1  OUT_DIR=tmp/repro_a

set -uo pipefail

DEVICE_IP="${DEVICE_IP:-192.168.0.200}"
DEVICE_USER="${DEVICE_USER:-root}"
DEVICE_PASS="${DEVICE_PASS:-root}"
ITER_COUNT="${ITER_COUNT:-20}"
ITER_START="${ITER_START:-1}"
INITIAL_WAIT="${INITIAL_WAIT:-60}"
RETRY_INTERVAL="${RETRY_INTERVAL:-30}"
RETRY_COUNT="${RETRY_COUNT:-5}"
OUT_DIR="${OUT_DIR:-tmp/repro_a}"

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.csv"
[ -f "$SUMMARY" ] || echo "iter,start_ts,boot_sent_ts,first_ssh_ok_ts,ssh_attempts,wifi_state,log_file,result" > "$SUMMARY"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

ssh_dev()  { sshpass -p "$DEVICE_PASS" ssh "${SSH_OPTS[@]}" "${DEVICE_USER}@${DEVICE_IP}" "$@"; }
scp_from() { sshpass -p "$DEVICE_PASS" scp "${SSH_OPTS[@]}" "${DEVICE_USER}@${DEVICE_IP}:$1" "$2"; }

bell5() { for _ in 1 2 3 4 5; do printf '\a'; sleep 0.2; done; }

stuck_exit() {
  local iter="$1" reason="$2"
  local stuck_file="$OUT_DIR/STUCK_iter_$(printf '%03d' "$iter").txt"
  {
    echo "[STUCK] iter=$iter at $(date -Iseconds)"
    echo "reason: $reason"
    echo "device: ${DEVICE_USER}@${DEVICE_IP}"
    echo "next iteration to resume: $iter"
    echo
    echo "DO NOT auto-recover. User must intervene (console/serial/power-cycle)."
    echo "After recovery, resume with:"
    echo "  ITER_START=$iter ITER_COUNT=$ITER_COUNT bash test/repro_a_loop.sh"
  } | tee "$stuck_file"
  bell5
  cat <<EOF >&2

================================================================
ALARM: iteration ${iter}에서 device 복구 불가
   reason: ${reason}
   device: ${DEVICE_USER}@${DEVICE_IP}
   stuck info: ${stuck_file}
   재개 명령: ITER_START=$iter ITER_COUNT=$ITER_COUNT bash test/repro_a_loop.sh
================================================================
EOF
  exit 2
}

echo "===== repro_a_loop start $(date -Iseconds) ====="
echo "device=${DEVICE_USER}@${DEVICE_IP}  iter=${ITER_START}..${ITER_COUNT}"
echo "wait=${INITIAL_WAIT}s  retry=${RETRY_COUNT}x${RETRY_INTERVAL}s"
echo "out=$OUT_DIR  summary=$SUMMARY"

for i in $(seq "$ITER_START" "$ITER_COUNT"); do
  start_ts=$(date -Iseconds)
  echo
  echo "######## iteration ${i}/${ITER_COUNT} start=${start_ts} ########"

  if ! ssh_dev 'echo alive' >/dev/null 2>&1; then
    stuck_exit "$i" "iteration 시작 전 SSH unreachable (device 응답 없음)"
  fi

  echo "[i=$i] trigger reboot"
  ssh_dev 'nohup sh -c "sleep 1; reboot" >/dev/null 2>&1 &' || true
  boot_sent_ts=$(date -Iseconds)

  echo "[i=$i] sleep ${INITIAL_WAIT}s (initial boot wait)"
  sleep "$INITIAL_WAIT"

  attempt=0
  ok=0
  first_ok_ts=""
  while [ "$attempt" -lt "$RETRY_COUNT" ]; do
    attempt=$((attempt + 1))
    echo "[i=$i] ssh attempt ${attempt}/${RETRY_COUNT} ..."
    if ssh_dev 'echo ssh_ok' >/dev/null 2>&1; then
      ok=1
      first_ok_ts=$(date -Iseconds)
      echo "[i=$i] ssh OK (attempt $attempt) at $first_ok_ts"
      break
    fi
    if [ "$attempt" -lt "$RETRY_COUNT" ]; then
      echo "[i=$i] sleep ${RETRY_INTERVAL}s before next attempt"
      sleep "$RETRY_INTERVAL"
    fi
  done

  if [ "$ok" -ne 1 ]; then
    echo "$i,$start_ts,$boot_sent_ts,,${attempt},UNREACHABLE,,STUCK" >> "$SUMMARY"
    stuck_exit "$i" "${RETRY_COUNT}회 SSH 재시도 모두 실패 (총 ${INITIAL_WAIT}s + ${RETRY_COUNT}*${RETRY_INTERVAL}s unreachable)"
  fi

  echo "[i=$i] run wifi_boot_diag.sh boot on device"
  ssh_dev 'bash /opt/pim/bin/wifi_boot_diag.sh boot >/dev/null 2>&1' || echo "[i=$i] wifi_boot_diag execution returned non-zero"
  remote_log=$(ssh_dev 'ls -t /tmp/wifi_boot_diag_boot_*.log 2>/dev/null | head -1' | tr -d '\r')

  local_log="$OUT_DIR/iter_$(printf '%03d' "$i")_boot.log"
  if [ -n "$remote_log" ]; then
    if scp_from "$remote_log" "$local_log" >/dev/null 2>&1; then
      echo "[i=$i] log pulled: $local_log"
    else
      echo "[i=$i] scp log failed (remote=$remote_log)"
    fi
  else
    echo "[i=$i] no remote log found"
  fi

  wifi_state="UNKNOWN"
  ip_state="NO_IP"
  if [ -f "$local_log" ]; then
    if grep -qE 'wpa_state=COMPLETED' "$local_log"; then
      wifi_state="CONNECTED"
    elif grep -qE 'wpa_state=(DISCONNECTED|SCANNING|INACTIVE|INTERFACE_DISABLED)' "$local_log"; then
      wifi_state="NOT_CONNECTED"
    fi
    if grep -qE 'wlp1s0.*UP.*192\.168\.0\.5' "$local_log"; then
      ip_state="HAS_IP"
    fi
  fi

  result="PASS"
  case "$wifi_state" in
    NOT_CONNECTED) result="FAIL_DEAUTH" ;;
    UNKNOWN)       result="FAIL_UNKNOWN" ;;
  esac
  if [ "$wifi_state" = "CONNECTED" ] && [ "$ip_state" = "NO_IP" ]; then
    result="PASS_NO_IP"
  fi

  echo "$i,$start_ts,$boot_sent_ts,$first_ok_ts,${attempt},${wifi_state}/${ip_state},${local_log},${result}" >> "$SUMMARY"
  echo "[i=$i] result=${result}  wifi=${wifi_state}  ip=${ip_state}"
done

echo
echo "===== Summary ($(date -Iseconds)) ====="
column -s, -t < "$SUMMARY" 2>/dev/null || cat "$SUMMARY"

pass=$(awk -F, 'NR>1 && $8 ~ /^PASS/' "$SUMMARY" | wc -l)
fail=$(awk -F, 'NR>1 && $8 ~ /^FAIL/' "$SUMMARY" | wc -l)
stuck=$(awk -F, 'NR>1 && $8 == "STUCK"' "$SUMMARY" | wc -l)
echo
echo "PASS=$pass  FAIL=$fail  STUCK=$stuck  (total $((pass+fail+stuck)) iterations)"
echo "===== repro_a_loop done $(date -Iseconds) ====="
