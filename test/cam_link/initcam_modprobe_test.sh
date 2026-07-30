#!/bin/bash
# init_cam.sh 의 modprobe 가드 검증
# 사용법: bash test/cam_link/initcam_modprobe_test.sh
#
# 회귀 배경 두 건:
#  1) rc1=$? 가 modprobe 가 아니라 뒤따르는 sleep 의 종료코드를 담아 modprobe 실패가
#     항상 무시됐다(1호기 로그에서 init_cam 후 CSI 블록이 번갈아 죽은 원인으로 지목).
#  2) rc1 이 실패해도 의존 모듈 imx8-media-dev 를 계속 로드했다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
BLOCK="$WORK/modprobe_block.sh"
CALLS="$WORK/calls"
trap 'rm -rf "$WORK"' EXIT

# 'modprobe max9296' 부터 그 뒤 두 번째 '^fi$' 까지 (rc1 가드 + rc2 가드)
START=$(grep -n '^modprobe max9296$' "$PIM_BIN/init_cam.sh" | head -1 | cut -d: -f1)
END=$(awk -v s="$START" 'NR>=s && /^fi$/{n++; if(n==2){print NR; exit}}' "$PIM_BIN/init_cam.sh")
[ -n "$START" ] && [ -n "$END" ] || { echo "modprobe 블록 추출 실패" >&2; exit 1; }
sed -n "${START},${END}p" "$PIM_BIN/init_cam.sh" > "$BLOCK"

# $1=설명 $2=실패시킬 모듈(none|max9296|imx8-media-dev) $3=기대 시도목록 $4=기대 exit
run() {
    : > "$CALLS"
    (
        export FAILMOD="$2" CALLS
        tag=init_cam.sh
        logger() { :; }
        sleep()  { :; }
        rm()     { :; }              # /tmp/init_cam_flag 실제 삭제 방지
        modprobe() {
            printf '%s\n' "$1" >> "$CALLS"
            [ "$1" = "$FAILMOD" ] && return 1
            return 0
        }
        # shellcheck disable=SC1090
        source "$BLOCK"
    ) >/dev/null 2>&1
    local rc=$?
    t_eq "$1" "$(paste -sd, "$CALLS")/$rc" "$3/$4"
}

echo "=== modprobe 가드 (시도목록/exit) ==="
run "max9296 실패 → imx8 시도 안 하고 중단" max9296        "max9296"                1
run "imx8 실패 → 둘 다 시도 후 중단"        imx8-media-dev "max9296,imx8-media-dev" 1
run "둘 다 성공 → 계속 진행"                none           "max9296,imx8-media-dev" 0

echo
echo "=== rc 캡처 위치 회귀 방지 — sleep 이 modprobe 와 rc 캡처 사이에 없어야 ==="
between=$(sed -n "${START},${END}p" "$PIM_BIN/init_cam.sh" \
          | awk '/^modprobe max9296$/{f=1;next} f&&/^rc1=\$\?$/{print "clean";exit} f{print "dirty:"$0;exit}')
t_eq "modprobe max9296 직후가 rc1=\$?" "$between" "clean"

t_summary "init_cam modprobe 가드"
