#!/bin/bash
# chk_cam_operate.sh 의 ISP 근거 로그(ladder_isp_evidence_log, #192) 검증
# 사용법: bash test/cam_link/isp_evidence_log_test.sh
#
# 배경: 파일 검사 실패 로그는 파일이 빠진 채널만 남긴다. ISP 하나가 멈추면 같은 CSI 의 두 채널이 함께 빠지므로
# 어느 ISP 가 멈췄는지, ISP 쪽 문제인지는 복구가 끝나면 알 수 없다. 사다리는 복구를 요청하기 직전에 드라이버의
# health_raw 를 두 번 읽어 채널별 프레임 카운터(hinf_count)가 움직였는지를 한 줄로 남긴다. 기록 전용이라
# 어떤 입력에서도 rc 0 이고 요청을 바꾸지 않는다.
#
# ISP_EVIDENCE_DAEMON=<경로> 로 다른 사본을 시험할 수 있다.
source "$(dirname "$0")/lib.sh"

CHK=${ISP_EVIDENCE_DAEMON:-$PIM_BIN/chk_cam_operate.sh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 경로 상수, jq 필터, 함수는 스크립트에 이어서 적혀 있다. 그 구간을 원문 그대로 잘라 쓴다.
awk '/^SYSFS_HEALTH_I2C2=/ { p = 1 } p { print } p && /^}$/ { exit }' "$CHK" > "$WORK/ev.sh"
if ! grep -q '^ladder_isp_evidence_log() {' "$WORK/ev.sh" || ! bash -n "$WORK/ev.sh"; then
    echo "함수 구간 추출 실패 ($CHK)" >&2
    exit 1
fi

# hr <adapter> <streaming> <busy> <schema> <채널…> : health_raw 한 줄을 만든다(드라이버가 내는 키 구성).
# 채널 = "<번호>:<enabled>:<link up>:<hinf_count|null>:<isp status>"
hr() {
    local adapter=$1 streaming=$2 busy=$3 schema=$4 chs="" c n en up hinf st
    shift 4
    for c in "$@"; do
        IFS=: read -r n en up hinf st <<<"$c"
        chs+="${chs:+,}{\"channel\":$n,\"enabled\":$en,\"phy\":\"B\",\"link\":{\"status\":\"OK\",\"up\":$up},\"control_tunnel\":\"OK\",\"serializer\":{\"status\":\"OK\",\"errno\":0,\"device_id\":145},\"isp\":{\"status\":\"$st\",\"errno\":0,\"hinf_count\":$hinf,\"hinf_progress\":\"YES\"},\"sensor\":{\"status\":\"UNKNOWN\",\"probe\":\"DEEP_NOT_RUN\"}}"
    done
    printf '{"schema":%s,"adapter":%s,"sequence":7,"observed_monotonic_ms":9660461,"busy":%s,"mode":"dual-wide","streaming":%s,"configured_local_mask":3,"configured_global_mask":3,"deserializer":{"status":"OK","errno":0,"device_id":150,"ctrl3_errno":0,"ctrl3":250,"rx3_errno":0,"rx3":102,"link_a_up":true,"link_b_up":true},"pair":{"status":"ALIGNED","sample_gap_ms":1000},"channels":[%s]}\n' \
        "$schema" "$adapter" "$busy" "$streaming" "$chs"
}

# 첫 읽기는 $WORK/s1, 둘째 읽기는 $WORK/s2 의 파일을 본다. 두 읽기 사이의 sleep 대역이 파일을 바꿔 놓는다.
# 파일 이름: i2c2(ch0·ch1), i2c1(ch2·ch3). 없는 파일은 읽기 실패다.
reset_samples() { rm -rf "$WORK/s1" "$WORK/s2"; mkdir -p "$WORK/s1" "$WORK/s2"; }
# run <사유> : 함수를 한 번 부른다. 출력 "<rc> <sleep 횟수>", 로그 줄은 $WORK/log 에 남는다.
run() {
    (
        KEY=RST; tag=chk_cam_operate.sh
        # shellcheck disable=SC1090,SC1091  # 대상 스크립트에서 잘라낸 구간이다
        source "$WORK/ev.sh"
        SYSFS_HEALTH_I2C2="$WORK/cur/i2c2"; SYSFS_HEALTH_I2C1="$WORK/cur/i2c1"
        logger() { printf '%s\n' "$*" >> "$WORK/log"; }
        sleep() { echo "$1" >> "$WORK/sleeps"; rm -rf "$WORK/cur"; cp -r "$WORK/s2" "$WORK/cur"; }
        rm -rf "$WORK/cur"; cp -r "$WORK/s1" "$WORK/cur"
        : > "$WORK/log"; : > "$WORK/sleeps"
        ladder_isp_evidence_log "$1"
        echo "$? $(grep -c . "$WORK/sleeps")"
    )
}
# 로그 줄에서 근거 부분만
evidence() { sed -n 's/^.* request: //p' "$WORK/log"; }

echo "=== 채널별 판정 ==="
reset_samples
hr 2 true false 1 0:true:true:119:OK 1:true:true:120:OK > "$WORK/s1/i2c2"
hr 1 true false 1 2:true:true:121:OK 3:true:true:122:OK > "$WORK/s1/i2c1"
hr 2 true false 1 0:true:true:134:OK 1:true:true:135:OK > "$WORK/s2/i2c2"
hr 1 true false 1 2:true:true:136:OK 3:true:true:137:OK > "$WORK/s2/i2c1"
t_eq "네 채널이 모두 진행 (rc, sleep 횟수)" "$(run 'file check failure')" "0 1"
t_eq "네 채널이 모두 진행" "$(evidence)" "ch0=ok(119>134) ch1=ok(120>135) | ch2=ok(121>136) ch3=ok(122>137)"
t_eq "로그 한 줄, 사유와 꼬리표가 들어간다" "$(grep -c 'local0.error \[RST\]\[chk_cam_operate.sh:[0-9]*\] isp evidence before file check failure request: ' "$WORK/log")" 1
t_eq "두 읽기 사이의 간격은 1초" "$(cat "$WORK/sleeps")" 1

hr 1 true false 1 2:true:true:121:UNKNOWN 3:true:true:137:OK > "$WORK/s2/i2c1"
run 'file check failure' > /dev/null
t_eq "ch2 의 카운터만 멈춤" "$(evidence)" "ch0=ok(119>134) ch1=ok(120>135) | ch2=STALL(121>121) ch3=ok(122>137)"

hr 2 true false 1 0:true:true:119:OK 1:true:true:120:OK > "$WORK/s2/i2c2"
hr 1 true false 1 2:true:true:121:UNKNOWN 3:true:true:122:UNKNOWN > "$WORK/s2/i2c1"
run 'gstapp start marker missing' > /dev/null
t_eq "네 채널이 모두 멈춤" "$(evidence)" "ch0=STALL(119>119) ch1=STALL(120>120) | ch2=STALL(121>121) ch3=STALL(122>122)"
t_eq "다른 사유도 그대로 적는다" "$(grep -c 'isp evidence before gstapp start marker missing request: ' "$WORK/log")" 1

reset_samples
hr 2 true false 1 0:true:true:119:OK 1:false:true:null:DISABLED > "$WORK/s1/i2c2"
hr 1 true false 1 2:true:true:null:FAILED 3:true:false:122:OK > "$WORK/s1/i2c1"
hr 2 true false 1 0:true:true:134:OK 1:false:true:null:DISABLED > "$WORK/s2/i2c2"
hr 1 true false 1 2:true:true:null:FAILED 3:true:false:122:OK > "$WORK/s2/i2c1"
run 'file check failure' > /dev/null
t_eq "끈 채널, 카운터를 못 읽은 채널, 링크가 내려간 채널" "$(evidence)" "ch0=ok(119>134) ch1=off | ch2=isp-FAILED ch3=link-down"

hr 1 false false 1 2:true:true:121:OK 3:true:true:122:OK > "$WORK/s1/i2c1"
hr 1 false false 1 2:true:true:121:OK 3:true:true:122:OK > "$WORK/s2/i2c1"
run 'file check failure' > /dev/null
t_eq "스트리밍 중이 아닌 장치는 표시를 붙인다" "$(evidence)" "ch0=ok(119>134) ch1=off | ch2=STALL(121>121) ch3=STALL(122>122) not-streaming"

hr 1 true false 1 > "$WORK/s1/i2c1"; hr 1 true false 1 > "$WORK/s2/i2c1"
run 'file check failure' > /dev/null
t_eq "채널 목록이 비어 있음" "$(evidence)" "ch0=ok(119>134) ch1=off | no-channels"

echo "=== 읽지 못하는 경우(사다리는 그대로 간다) ==="
reset_samples
hr 2 true false 1 0:true:true:119:OK 1:true:true:120:OK > "$WORK/s1/i2c2"
hr 2 true false 1 0:true:true:134:OK 1:true:true:135:OK > "$WORK/s2/i2c2"
t_eq "한 장치의 파일이 없음 (rc, sleep 횟수)" "$(run 'file check failure')" "0 1"
t_eq "한 장치의 파일이 없음" "$(evidence)" "ch0=ok(119>134) ch1=ok(120>135) | unreadable"

hr 1 true false 1 2:true:true:121:OK 3:true:true:122:OK > "$WORK/s1/i2c1"
printf 'not json\n' > "$WORK/s2/i2c1"
run 'file check failure' > /dev/null
t_eq "둘째 읽기가 JSON 이 아님" "$(evidence)" "ch0=ok(119>134) ch1=ok(120>135) | unreadable"

hr 1 true false 2 2:true:true:136:OK 3:true:true:137:OK > "$WORK/s2/i2c1"
run 'file check failure' > /dev/null
t_eq "알 수 없는 schema" "$(evidence)" "ch0=ok(119>134) ch1=ok(120>135) | schema?"

hr 1 true true 1 2:true:true:136:OK 3:true:true:137:OK > "$WORK/s2/i2c1"
run 'file check failure' > /dev/null
t_eq "드라이버가 busy 를 돌려줌" "$(evidence)" "ch0=ok(119>134) ch1=ok(120>135) | busy"

reset_samples
t_eq "두 장치 모두 없음: 기다리지 않는다 (rc, sleep 횟수)" "$(run 'file check failure')" "0 0"
t_eq "두 장치 모두 없음" "$(evidence)" "unavailable"

echo "=== 드라이버가 실제로 낸 줄 ==="
# .6 보드에서 2026-11-25 에 1초 간격으로 읽은 1-0048 의 health_raw 두 줄(원문 그대로).
reset_samples
cat > "$WORK/s1/i2c1" <<'EOF'
{"schema":1,"adapter":1,"sequence":1,"observed_monotonic_ms":9660467,"busy":false,"mode":"dual-wide","streaming":true,"configured_local_mask":3,"configured_global_mask":12,"deserializer":{"status":"OK","errno":0,"device_id":150,"ctrl3_errno":0,"ctrl3":250,"rx3_errno":0,"rx3":102,"link_a_up":true,"link_b_up":true},"pair":{"status":"NOT_APPLICABLE","sample_gap_ms":0},"channels":[{"channel":2,"enabled":true,"phy":"B","link":{"status":"OK","up":true},"control_tunnel":"OK","serializer":{"status":"OK","errno":0,"device_id":145},"isp":{"status":"STARTING","errno":0,"hinf_count":119,"hinf_progress":"STARTING"},"sensor":{"status":"UNKNOWN","probe":"DEEP_NOT_RUN"}},{"channel":3,"enabled":true,"phy":"A","link":{"status":"OK","up":true},"control_tunnel":"OK","serializer":{"status":"OK","errno":0,"device_id":145},"isp":{"status":"STARTING","errno":0,"hinf_count":119,"hinf_progress":"STARTING"},"sensor":{"status":"UNKNOWN","probe":"DEEP_NOT_RUN"}}],"isp_boot":{"status":"OK","epoch_current":true,"stage":"post_config","channels":[{"channel":2,"checked":true,"errno":0,"value":1280},{"channel":3,"checked":true,"errno":0,"value":1280}]}}
EOF
cat > "$WORK/s2/i2c1" <<'EOF'
{"schema":1,"adapter":1,"sequence":2,"observed_monotonic_ms":9661483,"busy":false,"mode":"dual-wide","streaming":true,"configured_local_mask":3,"configured_global_mask":12,"deserializer":{"status":"OK","errno":0,"device_id":150,"ctrl3_errno":0,"ctrl3":250,"rx3_errno":0,"rx3":102,"link_a_up":true,"link_b_up":true},"pair":{"status":"ALIGNED","sample_gap_ms":1016},"channels":[{"channel":2,"enabled":true,"phy":"B","link":{"status":"OK","up":true},"control_tunnel":"OK","serializer":{"status":"OK","errno":0,"device_id":145},"isp":{"status":"OK","errno":0,"hinf_count":135,"hinf_progress":"YES"},"sensor":{"status":"UNKNOWN","probe":"DEEP_NOT_RUN"}},{"channel":3,"enabled":true,"phy":"A","link":{"status":"OK","up":true},"control_tunnel":"OK","serializer":{"status":"OK","errno":0,"device_id":145},"isp":{"status":"OK","errno":0,"hinf_count":135,"hinf_progress":"YES"},"sensor":{"status":"UNKNOWN","probe":"DEEP_NOT_RUN"}}],"isp_boot":{"status":"OK","epoch_current":true,"stage":"post_config","channels":[{"channel":2,"checked":true,"errno":0,"value":1280},{"channel":3,"checked":true,"errno":0,"value":1280}]}}
EOF
run 'file check failure' > /dev/null
t_eq "보드의 실제 표본" "$(evidence)" "unreadable | ch2=ok(119>135) ch3=ok(119>135)"

echo "=== 부르는 자리 ==="
# 세 사다리가 요청을 고르기 직전에 한 번씩 부른다. 쉬는 중인 분기와 끊김 분기에서는 부르지 않는다
# (블록을 실행해 보는 확인은 monitor_ladder_test.sh, final_stall_watch_test.sh 에 있다).
line_of() { grep -n -F -- "$1" "$CHK" | head -1 | cut -d: -f1; }
t_eq "부르는 곳은 셋" "$(grep -c -E '^[[:space:]]+ladder_isp_evidence_log "' "$CHK")" 3
# 부르는 줄의 바로 윗줄(들여쓰기를 뺀 원문). 같은 분기 줄이 드라이버 미적재 사다리에도 있어 줄 번호로 찾지 않는다.
above() { sed -n "$(( $(line_of "$1") - 1 ))p" "$CHK" | sed -E 's/^[[:space:]]+//'; }
t_eq "파일 검사: 사다리 분기의 첫 줄" "$(above 'ladder_isp_evidence_log "file check failure"')" 'elif (( cam_disconnect_flag == 0x0 )); then'
t_eq "시작 마커: 사다리 분기의 첫 줄" "$(above 'ladder_isp_evidence_log "gstapp start marker missing"')" 'elif [ "$marker_disc" -eq 0 ]; then'
hold=$(line_of 'if ladder_on_hold "final path stall"; then')
verdict=$(line_of 'FINAL STALL: no new')
call=$(line_of 'ladder_isp_evidence_log "final path stall"')
pick=$(line_of 'if [ "$next" -le 2 ]; then')
order=no
[ -n "$hold" ] && [ -n "$verdict" ] && [ -n "$call" ] && [ -n "$pick" ] &&
    [ "$hold" -lt "$verdict" ] && [ "$verdict" -lt "$call" ] && [ "$call" -lt "$pick" ] && order=yes
t_eq "최종 경로 정체: 쉬는 중 판정 뒤, 정체 판정 뒤, 요청 선택 앞" "$order" yes

t_summary "ISP 근거 로그"
