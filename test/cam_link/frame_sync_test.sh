#!/bin/bash
# cam_sensor_frame_sync.sh 판정 로직 테스트
#
# 하드웨어 없이 동작한다. DMA helper 는 CAM_DMA_READ 로, 단조 시계 원본은
# CAM_UPTIME_PATH 로 주입한다. 실제 I2C/V4L2 장치는 열지 않는다.

cd "$(dirname "$0")" || exit 1
source ./lib.sh

SCRIPT="$PIM_BIN/cam_sensor_frame_sync.sh"
WORK="${TMPDIR:-/tmp}/frame_sync_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# ── mono_ns 파싱 ────────────────────────────────────────────────────────────
# uptime 나노초는 64비트 정수여야 한다. awk 의 double 로 계산하면 100일 이상
# 가동한 장비에서 정밀도가 깨지므로 정수 연산으로 조립한다.
t_extract_func "$SCRIPT" mono_ns "$WORK/mono_ns.sh" || exit 1
source "$WORK/mono_ns.sh"

mono_of() {
    printf '%s 0.00\n' "$1" > "$WORK/uptime"
    UPTIME_PATH="$WORK/uptime" mono_ns
}

t_eq "정수부+소수 2자리"        "$(mono_of 123.45)"       "123450000000"
t_eq "1초 미만 (8진수 오해 금지)" "$(mono_of 0.07)"         "70000000"
t_eq "소수 3자리"               "$(mono_of 1.234)"        "1234000000"
t_eq "장기 가동 (정밀도 유지)"   "$(mono_of 6166516.48)"   "6166516480000000"

printf 'not-a-number\n' > "$WORK/uptime"
UPTIME_PATH="$WORK/uptime" mono_ns >/dev/null 2>&1 && r=0 || r=1
t_eq "형식 위반은 실패 반환" "$r" "1"

printf '12.34 56.78\n' > "$WORK/real_uptime"
a=$(UPTIME_PATH=/proc/uptime mono_ns)
b=$(UPTIME_PATH=/proc/uptime mono_ns)
[ -n "$a" ] && [ -n "$b" ] && (( b >= a )) && r=0 || r=1
t_eq "실제 /proc/uptime 이 증가한다" "$r" "0"

# ── 판정 계약 (모의 DMA) ────────────────────────────────────────────────────
make_dma_stub() {
    # $1=출력 파일  $2=모드(step|reset|frozen)
    case "$2" in
        step)   # 채널마다 표본당 1씩 증가
            cat > "$1" <<'EOF'
#!/bin/bash
f="$FS_STATE/ch$1"; n=0
[ -f "$f" ] && n=$(cat "$f")
printf '[stub] ch=%s reg=%s val=0x%04x\n' "$1" "$2" "$((n & 0xffff))"
echo $((n + 1)) > "$f"
EOF
            ;;
        reset)  # 0x0016 -> 0x0012, 불가능한 backward jump
            cat > "$1" <<'EOF'
#!/bin/bash
f="$FS_STATE/ch$1"
if [ -f "$f" ]; then v=0x0012; else v=0x0016; : > "$f"; fi
printf '[stub] ch=%s reg=%s val=%s\n' "$1" "$2" "$v"
EOF
            ;;
    esac
    chmod +x "$1"
}

run_sync() {
    # $1=모드  $2=samples  나머지는 그대로 전달. 종료코드를 출력한다.
    local mode="$1" samples="$2"; shift 2
    rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    make_dma_stub "$WORK/dma.sh" "$mode"
    FS_STATE="$WORK/state" CAM_DMA_READ="$WORK/dma.sh" \
        "$@" "$SCRIPT" 0,1,2,3 0.2 "$samples" > "$WORK/out.txt" 2>&1
    printf '%s\n' "$?"
}

t_eq "모든 채널 동일 증가 → exit 0" "$(run_sync step 3)" "0"
t_eq "  결과가 MATCH" "$(grep -c 'result=MATCH' "$WORK/out.txt")" "1"

t_eq "불가능한 backward jump → exit 4" "$(run_sync reset 2)" "4"
t_eq "  결과가 RESET_OR_INVALID" "$(grep -c 'result=RESET_OR_INVALID' "$WORK/out.txt")" "1"
t_eq "  drift 가 NA 로 낮춰진다" "$(grep -c 'drift=NA' "$WORK/out.txt")" "4"

# ── 벽시계 점프 내성 ────────────────────────────────────────────────────────
# 이 패키지는 update_time_sync.sh 와 fake-hwclock.sh 로 벽시계를 움직인다.
# 표본 간 경과시간을 date 로 재면 정지·역행한 시계가 판정을 죽인다. 경과시간은
# /proc/uptime 기반이어야 하고, date 는 표시용으로만 쓰여야 한다.
mkdir -p "$WORK/stub"
printf '#!/bin/sh\necho 1700000000000000000\n' > "$WORK/stub/date"
chmod +x "$WORK/stub/date"

t_eq "정지한 벽시계에서도 판정이 완료된다" \
    "$(run_sync step 3 env "PATH=$WORK/stub:$PATH")" "0"
t_eq "  결과는 여전히 MATCH" "$(grep -c 'result=MATCH' "$WORK/out.txt")" "1"

t_summary "cam_sensor_frame_sync"
