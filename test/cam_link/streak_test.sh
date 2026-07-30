#!/bin/bash
# BG_Check_for_pim.sh 의 cam disconnect streak 증가 검증
# 사용법: bash test/cam_link/streak_test.sh
#
# 회귀 배경: streak_set() 과 cam_state.sh 의 cam_inc_streak() 이 같은 파일
# (/tmp/cam_state/streak)에 써서 루프 1회에 2씩 증가했다. 1호기 로그에서
# "cam disconnect : 1 → 3 → 5 → 7" 로 홀수만 찍힌 것이 실증.
# 부작용으로 cam_inc_streak 의 streak>=2 → degraded 전이가 설계 의도인 2회 연속이
# 아니라 첫 감지에 즉시 발동했다.
# cam_state.sh 를 격리 디렉터리로 복제해 실행하므로 실제 /tmp/cam_state 는 쓰지 않는다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# $1=before(구 로직) | after(현 로직)
# 출력: "값1 값2 ...|1회차 state|최종 state"
run_case() {
    local mode="$1"
    local dir="$WORK/state_$mode"          # local 다중 대입은 앞 변수를 못 보므로 줄을 나눈다
    local lib="$WORK/cam_state_$mode.sh"
    rm -rf "$dir"
    mkdir -p "$dir/channels" "$dir/recording"
    printf '%s' healthy > "$dir/state"
    printf '%s' 0       > "$dir/streak"
    sed "s#^STATE_DIR=.*#STATE_DIR=\"$dir\"#" "$PIM_LIB/cam_state.sh" > "$lib"
    (
        logger() { :; }                    # syslog 오염 방지
        # shellcheck disable=SC1090
        source "$lib"
        streak_get() {
            local v; v=$(cat "$dir/streak" 2>/dev/null | tr -d '\n')
            [[ "$v" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
            echo "$v"
        }
        streak_set() { printf "%s" "$1" > "$dir/streak" 2>/dev/null; }

        vals=""; first_state=""
        for i in 1 2 3 4 5; do
            if [ "$mode" = "before" ]; then
                streak=$(streak_get)       # --- 수정 전 원본 블록 ---
                streak=$((streak + 1))
                streak_set "$streak"
                cam_inc_streak
            else
                cam_inc_streak             # --- 현재 블록 ---
                streak=$(streak_get)
            fi
            vals="$vals $streak"
            [ "$i" -eq 1 ] && first_state="$(cat "$dir/state" 2>/dev/null)"
        done
        printf '%s|%s|%s' "${vals# }" "$first_state" "$(cat "$dir/state" 2>/dev/null)"
    )
}

before=$(run_case before)
after=$(run_case after)
b_vals="${before%%|*}"; b_rest="${before#*|}"; b_first="${b_rest%%|*}"
a_vals="${after%%|*}";  a_rest="${after#*|}";  a_first="${a_rest%%|*}"

echo "=== 루프 5회 반복 시 'cam disconnect : N' 으로 찍히는 N ==="
t_eq "수정 전(버그 재현) — 1씩 증가해야 하나 2씩" "$b_vals" "1 3 5 7 9"
t_eq "현재 — 1씩 증가"                            "$a_vals" "1 2 3 4 5"

echo
echo "=== degraded 전이 시점 (cam_inc_streak 은 streak>=2 에서 전이) ==="
t_eq "수정 전 · 1회차 state (즉시 degraded = 버그)" "$b_first" "degraded"
t_eq "현재 · 1회차 state (2회째부터 degraded)"      "$a_first" "healthy"

echo
echo "=== 격리 확인 — 케이스별 디렉터리가 분리되었는가 ==="
t_eq "state_before / state_after 파일" \
     "$([ -f "$WORK/state_before/streak" ] && [ -f "$WORK/state_after/streak" ] && echo 있음 || echo 없음)" \
     "있음"

t_summary "streak 증가"
