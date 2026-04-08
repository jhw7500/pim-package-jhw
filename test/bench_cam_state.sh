#!/bin/bash
# cam_state jq vs file-based 성능 비교 벤치마크
# 사용법: bash test/bench_cam_state.sh [iterations]

ITERATIONS="${1:-100}"
STATE_FILE="/tmp/bench_cam_state.json"
STATE_DIR="/tmp/bench_cam_state_dir"
RECOVERY_FILE="/tmp/bench_cam_recovery.json"

echo "=== cam_state 성능 벤치마크 (${ITERATIONS}회 반복) ==="
echo ""

# ─────────────────────────────────────────────
# 준비: 테스트 JSON 생성
# ─────────────────────────────────────────────
cat > "$STATE_FILE" << 'EOF'
{
  "timestamp": 0,
  "state": "healthy",
  "streak": 0,
  "last_init_ts": 0,
  "last_start_ts": 0,
  "recording": {
    "start_video_time_actual": "",
    "start_video_time": "",
    "start_video_time_chk": "",
    "start_video_time_cpy": "",
    "start_video_time_vib": ""
  },
  "channels": {
    "ch0": {"error": false, "last_ok": 0},
    "ch1": {"error": false, "last_ok": 0},
    "ch2": {"error": false, "last_ok": 0},
    "ch3": {"error": false, "last_ok": 0}
  }
}
EOF

# ─────────────────────────────────────────────
# 방법1: jq 일괄 호출 (배치)
# ─────────────────────────────────────────────
method1_reset_streak() {
    local tmp="${STATE_FILE}.tmp.$$"
    local ts=$(date +%s)
    jq --argjson ts "$ts" '
      .streak = 0 | .state = "healthy" | .timestamp = $ts
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

method1_inc_streak() {
    local tmp="${STATE_FILE}.tmp.$$"
    local ts=$(date +%s)
    jq --argjson ts "$ts" '
      .streak += 1 |
      .timestamp = $ts |
      if .streak >= 2 then .state = "degraded" else . end
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

method1_channel_errors() {
    local tmp="${STATE_FILE}.tmp.$$"
    local ts=$(date +%s)
    jq --argjson ts "$ts" '
      .channels.ch0.error = true | .channels.ch0.last_ok = $ts |
      .channels.ch1.error = true | .channels.ch1.last_ok = $ts |
      .channels.ch2.error = true | .channels.ch2.last_ok = $ts |
      .channels.ch3.error = true | .channels.ch3.last_ok = $ts
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

method1_get_values() {
    jq -r '[.timestamp, .state, .streak, .last_init_ts] | @tsv' "$STATE_FILE" > /dev/null 2>&1
}

# 최악 시나리오: reset + inc + channel_errors + get (BG루프 1회 시뮬레이션)
method1_loop_sim() {
    method1_reset_streak
    method1_inc_streak
    method1_channel_errors
    method1_get_values
}

# ─────────────────────────────────────────────
# 방법2: 파일 기반 키-값
# ─────────────────────────────────────────────
method2_init() {
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR/channels"
    echo "0" > "$STATE_DIR/timestamp"
    echo "healthy" > "$STATE_DIR/state"
    echo "0" > "$STATE_DIR/streak"
    echo "0" > "$STATE_DIR/last_init_ts"
    echo "0" > "$STATE_DIR/last_start_ts"
    for ch in 0 1 2 3; do
        echo "false" > "$STATE_DIR/channels/ch${ch}_error"
        echo "0" > "$STATE_DIR/channels/ch${ch}_last_ok"
    done
}

method2_reset_streak() {
    echo "0" > "$STATE_DIR/streak"
    echo "healthy" > "$STATE_DIR/state"
    date +%s > "$STATE_DIR/timestamp"
}

method2_inc_streak() {
    local current
    current=$(cat "$STATE_DIR/streak" 2>/dev/null)
    current=${current:-0}
    current=$((current + 1))
    echo "$current" > "$STATE_DIR/streak"
    date +%s > "$STATE_DIR/timestamp"
    if [ "$current" -ge 2 ]; then
        echo "degraded" > "$STATE_DIR/state"
    fi
}

method2_channel_errors() {
    local ts
    ts=$(date +%s)
    for ch in 0 1 2 3; do
        echo "true" > "$STATE_DIR/channels/ch${ch}_error"
        echo "$ts" > "$STATE_DIR/channels/ch${ch}_last_ok"
    done
}

method2_get_values() {
    cat "$STATE_DIR/timestamp" > /dev/null 2>&1
    cat "$STATE_DIR/state" > /dev/null 2>&1
    cat "$STATE_DIR/streak" > /dev/null 2>&1
    cat "$STATE_DIR/last_init_ts" > /dev/null 2>&1
}

method2_loop_sim() {
    method2_reset_streak
    method2_inc_streak
    method2_channel_errors
    method2_get_values
}

# ─────────────────────────────────────────────
# 현재 방법 (개별 jq fork) - 기준선
# ─────────────────────────────────────────────
current_state_set() {
    local key="$1" value="$2"
    local tmp="${STATE_FILE}.tmp.$$"
    jq "$key = $value" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

current_state_touch() {
    current_state_set '.timestamp' "$(date +%s)"
}

current_reset_streak() {
    current_state_set '.streak' 0
    current_state_set '.state' '"healthy"'
    current_state_touch
}

current_inc_streak() {
    local current
    current=$(jq -r '.streak' "$STATE_FILE" 2>/dev/null)
    current=${current:-0}
    current_state_set '.streak' $((current + 1))
    current_state_touch
}

current_channel_errors() {
    for ch in 0 1 2 3; do
        current_state_set ".channels.ch${ch}.error" true
        current_state_set ".channels.ch${ch}.last_ok" "$(date +%s)"
    done
}

current_get_values() {
    jq -r '.timestamp' "$STATE_FILE" > /dev/null 2>&1
    jq -r '.state' "$STATE_FILE" > /dev/null 2>&1
    jq -r '.streak' "$STATE_FILE" > /dev/null 2>&1
    jq -r '.last_init_ts' "$STATE_FILE" > /dev/null 2>&1
}

current_loop_sim() {
    current_reset_streak
    current_inc_streak
    current_channel_errors
    current_get_values
}

# ─────────────────────────────────────────────
# 벤치마크 실행
# ─────────────────────────────────────────────

echo "[현재 방식] 개별 jq fork (기준선)"
# JSON 초기화
cat > "$STATE_FILE" << 'RESETEOF'
{"timestamp":0,"state":"healthy","streak":0,"last_init_ts":0,"last_start_ts":0,"recording":{},"channels":{"ch0":{"error":false,"last_ok":0},"ch1":{"error":false,"last_ok":0},"ch2":{"error":false,"last_ok":0},"ch3":{"error":false,"last_ok":0}}}
RESETEOF
start=$(date +%s%N)
for ((i=0; i<ITERATIONS; i++)); do
    current_loop_sim
done
end=$(date +%s%N)
current_ms=$(( (end - start) / 1000000 ))
echo "  소요시간: ${current_ms}ms (${ITERATIONS}회)"
echo "  1회당: $(echo "scale=2; $current_ms / $ITERATIONS" | bc)ms"
echo "  jq fork/회: ~15회"
echo ""

echo "[방법1] jq 일괄 호출 (배치)"
cat > "$STATE_FILE" << 'RESETEOF'
{"timestamp":0,"state":"healthy","streak":0,"last_init_ts":0,"last_start_ts":0,"recording":{},"channels":{"ch0":{"error":false,"last_ok":0},"ch1":{"error":false,"last_ok":0},"ch2":{"error":false,"last_ok":0},"ch3":{"error":false,"last_ok":0}}}
RESETEOF
start=$(date +%s%N)
for ((i=0; i<ITERATIONS; i++)); do
    method1_loop_sim
done
end=$(date +%s%N)
method1_ms=$(( (end - start) / 1000000 ))
echo "  소요시간: ${method1_ms}ms (${ITERATIONS}회)"
echo "  1회당: $(echo "scale=2; $method1_ms / $ITERATIONS" | bc)ms"
echo "  jq fork/회: 4회"
echo ""

echo "[방법2] 파일 기반 키-값 (jq 제거)"
method2_init
start=$(date +%s%N)
for ((i=0; i<ITERATIONS; i++)); do
    method2_loop_sim
done
end=$(date +%s%N)
method2_ms=$(( (end - start) / 1000000 ))
echo "  소요시간: ${method2_ms}ms (${ITERATIONS}회)"
echo "  1회당: $(echo "scale=2; $method2_ms / $ITERATIONS" | bc)ms"
echo "  jq fork/회: 0회"
echo ""

# ─────────────────────────────────────────────
# 결과 비교
# ─────────────────────────────────────────────
echo "=== 비교 결과 ==="
echo "현재:  ${current_ms}ms (기준)"
echo "방법1: ${method1_ms}ms ($(echo "scale=1; $current_ms / $method1_ms" | bc)x 빠름)"
echo "방법2: ${method2_ms}ms ($(echo "scale=1; $current_ms / $method2_ms" | bc)x 빠름)"
echo ""
echo "방법1 vs 방법2: $(echo "scale=1; $method1_ms / $method2_ms" | bc)x 차이"

# 정리
rm -f "$STATE_FILE" "$RECOVERY_FILE"
rm -rf "$STATE_DIR"
