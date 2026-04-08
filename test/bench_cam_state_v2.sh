#!/bin/bash
# 새 cam_state.sh (파일 기반) vs 기존 (개별 jq) 비교 벤치마크
ITERATIONS="${1:-100}"

echo "=== cam_state v2 검증 벤치마크 (${ITERATIONS}회) ==="
echo ""

# ─────────────────────────────────────────────
# 새 cam_state.sh 로드
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/dist/pim/opt/pim/lib/cam_state.sh"

# 기존 상태 디렉토리 정리 후 초기화
rm -rf /tmp/cam_state
cam_state_init

echo "[기능 검증]"
# streak
cam_reset_streak
s=$(cam_state_get streak)
[ "$s" = "0" ] && echo "  streak reset: OK" || echo "  streak reset: FAIL (got $s)"

cam_inc_streak
s=$(cam_state_get streak)
[ "$s" = "1" ] && echo "  streak inc: OK" || echo "  streak inc: FAIL (got $s)"

cam_inc_streak
s=$(cam_state_get streak)
state=$(cam_get_state)
[ "$s" = "2" ] && [ "$state" = "degraded" ] && echo "  streak>=2 degraded: OK" || echo "  streak>=2 degraded: FAIL (streak=$s state=$state)"

# channel error
cam_channel_error 0
e=$(cat /tmp/cam_state/channels/ch0_error 2>/dev/null)
[ "$e" = "true" ] && echo "  channel_error: OK" || echo "  channel_error: FAIL (got $e)"

cam_channel_clear 0
e=$(cat /tmp/cam_state/channels/ch0_error 2>/dev/null)
[ "$e" = "false" ] && echo "  channel_clear: OK" || echo "  channel_clear: FAIL (got $e)"

# has_channel_error
cam_channel_error 2
cam_has_channel_error && echo "  has_channel_error: OK" || echo "  has_channel_error: FAIL"

# recording
cam_recording_set 'start_video_time_actual' '2026-04-01T10:00:00'
r=$(cat /tmp/cam_state/recording/start_video_time_actual 2>/dev/null)
[ "$r" = "2026-04-01T10:00:00" ] && echo "  recording_set: OK" || echo "  recording_set: FAIL (got $r)"

# record_init / record_start
cam_record_init
state=$(cam_get_state)
[ "$state" = "recovering" ] && echo "  record_init: OK" || echo "  record_init: FAIL (state=$state)"

cam_record_start
ts=$(cat /tmp/cam_state/last_start_ts 2>/dev/null)
[ "$ts" -gt 0 ] 2>/dev/null && echo "  record_start: OK" || echo "  record_start: FAIL (ts=$ts)"

# reset_state
cam_reset_state
state=$(cam_get_state)
s=$(cam_state_get streak)
[ "$state" = "healthy" ] && [ "$s" = "0" ] && echo "  reset_state: OK" || echo "  reset_state: FAIL (state=$state streak=$s)"

echo ""

# ─────────────────────────────────────────────
# 성능 측정: BG_Check 루프 1회 시뮬레이션
# ─────────────────────────────────────────────
loop_sim() {
    cam_reset_streak
    cam_inc_streak
    cam_channel_error 0
    cam_channel_error 1
    cam_channel_error 2
    cam_channel_error 3
    cam_state_get streak > /dev/null
    cam_state_get state > /dev/null
    cam_state_get timestamp > /dev/null
    cam_state_get last_init_ts > /dev/null
}

echo "[성능 측정] 새 cam_state.sh (파일 기반)"
rm -rf /tmp/cam_state
cam_state_init
start=$(date +%s%N)
for ((i=0; i<ITERATIONS; i++)); do
    loop_sim
done
end=$(date +%s%N)
new_ms=$(( (end - start) / 1000000 ))
echo "  소요시간: ${new_ms}ms (${ITERATIONS}회)"
echo "  1회당: $(echo "scale=2; $new_ms / $ITERATIONS" | bc)ms"
echo ""

# 정리
rm -rf /tmp/cam_state
echo "검증 완료."
