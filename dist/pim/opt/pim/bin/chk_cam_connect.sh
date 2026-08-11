#!/bin/bash
#JSON_PREFIX=edgeconf_
#JOSN_SUFFIX=.json
#FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
FLAG_PATH="/tmp"
tag=$(basename "$0")

# RX3(0x002F) 디코드는 BG_Check_for_pim.sh 와 공유한다. 두 벌로 두면 갈라지므로
# lib 한 곳에만 둔다. 경로를 변수로 받는 것은 테스트에서 저장소 사본을 쓰기 위함이다.
PIM_LIB="${PIM_LIB:-/opt/pim/lib}"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_state.sh"

# ── MAX9296 CTRL3(0x13) 비트 정의 (데이터시트) ──────────────────────
#  bit 7,6,0 : 예약(-). 값에 의미가 없으므로 반드시 마스킹한다.
#  bit 5:4   : LINK_MODE  00=Dual 01=Link A 10=Link B 11=Splitter
#  bit 3     : LOCKED     1=GMSL2 링크 락
#  bit 2     : ERROR      1=ERRB 어서트 (링크 락 여부와 무관한 에러 플래그)
#  bit 1     : CMU_LOCKED 1=CMU(Clock Multiplier Unit) 락
CTRL3_VALID_MASK=0x3e
LM_DUAL=0
LM_LINK_A=1
LM_LINK_B=2
LM_SPLITTER=3
BIT_LOCKED=0x08
BIT_ERROR=0x04
BIT_CMU=0x02

# 양 채널 활성 시 기대하는 LINK_MODE (기존 SUCCESS_VAL=0xfa 가 Splitter 였다)
LM_BOTH_EXPECT=$LM_SPLITTER

# 짝수 채널(ch0/ch2)과 홀수 채널(ch1/ch3)이 각각 어느 LINK_MODE 로 설정되는가.
#
# 우리가 읽는 CTRL3 의 LINK_MODE 는 드라이버가 CTRL0(0x0010) 의 LINK_CFG(bit1:0) 에
# 써 넣은 값의 되읽기다. 즉 기대값은 추정이 아니라 드라이버 레지스터 테이블에서
# 그대로 나온다(max9296.c, 하드웨어 없이 확인 가능):
#
#   ch0 (Left,  enable!=0x02) → max9296_init_setting_720p_30fps_L
#                               → des CTRL0=0x22 → LINK_CFG=0b10 = Link B
#   ch1 (Right, enable==0x02) → max9296_init_setting_720p_30fps_R
#                               → des CTRL0=0x21 → LINK_CFG=0b01 = Link A
#   양 채널                   → ..._crop_720p_2ch_30fps
#                               → des CTRL0=0x23 → LINK_CFG=0b11 = Splitter
#
# 상위 비트도 봐야 한다. 단일 구성이 쓰는 0x21/0x22/0x23 은 RESET_ONESHOT(0x20)만
# 켜고 AUTO_LINK(0x10)는 꺼 둔다 — 즉 LINK_CFG 가 그대로 지켜지므로 위 표를 값만으로
# 단정할 수 있다. 반면 듀얼 테이블이 쓰는 0x31/0x32 는 AUTO_LINK 가 켜져 있어 어느
# 링크가 잡힐지 레지스터 값만으로는 알 수 없다(듀얼 판정에 LINK_MODE 를 쓰지 않는 이유).
# 벤치 실측도 같은 방향이었다: 둘 다 연결 RX3=0x66 → ch1 물리 제거 → 0x60.
#
# 주의 — max9296.c 주석의 '링크 이름'은 신뢰하지 말 것. 매크로 MAX9295_SER_ADDR_CH0 의
# "Link A: ch0" 에서 주소(ch0=0x40)는 맞지만 링크 이름은 위 표와 반대다. 1274행의
# "Right=Link B" 도 마찬가지다. 위 표는 주석이 아니라 실제 레지스터 쓰기와 벤치 실측에서
# 뽑았다. 드라이버 내부의 link_a_err/link_b_err 도 물리 링크 이름이 아니라 로컬 ch0/ch1
# 의 별칭으로만 쓰인다(max9296.c:1295~1298).
#
# 시리얼라이저 주소 규칙은 위 LINK_MODE 표와 별개이며 확정돼 있다:
#   듀얼 — ch0=0x40, ch1=0x60   (리맵은 듀얼 초기화에서만 일어난다, max9296.c:483)
#   단일 — 어느 채널이든 0x40   (max9296.c:608·664)
# 따라서 '단일 구성에서는' 주소로 채널을 판별할 수 없다. 이 스크립트는 des(0x48)만
# 읽으므로 어느 쪽이든 영향받지 않는다.
CH_EVEN_LINK=$LM_LINK_B    # ch0, ch2 → LINK_MODE Link B (드라이버 _L 테이블)
CH_ODD_LINK=$LM_LINK_A     # ch1, ch3 → LINK_MODE Link A (드라이버 _R 테이블)

# RX3(0x002F) 비트 정의와 read_rx3_links() 는 lib/cam_state.sh 에 있다.
# 판정에는 쓰지 않고 진단 로그에만 남긴다. 현장 로그에서 이 값과 drv(드라이버
# link_status)의 일치율을 확인한 뒤 귀속 사용 여부를 별도로 판단한다.

ENABLE_VAL="true"
DISABLE_VAL="false"
result=0;
timestamp=`date +"%Y-%m-%d %T,%3N"`

# parse_ctrl3 / classify_ctrl3 의 출력 (command substitution 을 쓰면
# 서브셸이라 값이 전달되지 않으므로 전역 변수로 주고받는다)
ctrl3_mode=0
ctrl3_locked=0
ctrl3_error=0
ctrl3_cmu=0
ctrl3_verdict="unknown"

# CTRL3 원시 문자열에서 16진 토큰을 뽑아 비트 필드로 분해한다.
parse_ctrl3() {
    local raw val
    ctrl3_mode=0; ctrl3_locked=0; ctrl3_error=0; ctrl3_cmu=0
    raw=$(printf '%s' "$1" | grep -oE '0[xX][0-9a-fA-F]+' | head -1)
    [ -n "$raw" ] || return 1
    val=$(( raw & CTRL3_VALID_MASK ))
    ctrl3_mode=$(( (val >> 4) & 0x3 ))
    [ $(( val & BIT_LOCKED )) -ne 0 ] && ctrl3_locked=1
    [ $(( val & BIT_ERROR ))  -ne 0 ] && ctrl3_error=1
    [ $(( val & BIT_CMU ))    -ne 0 ] && ctrl3_cmu=1
    return 0
}

# $1=CTRL3 원시값, $2=기대 LINK_MODE → ctrl3_verdict 설정
#   ok              : 정상
#   errb_only       : 링크는 락됐고 ERRB 만 어서트 (에러 플래그 금지)
#   err_both        : 링크 미락 / CMU 미락 → 해당 버스의 두 채널이 함께 영향받는다
#   mode_unexpected : 드라이버가 설정한 LINK_MODE 가 아니다 → 채널 귀속 불가
#   read_fail       : i2c 읽기 실패
#   unknown         : (방어용) 위 어디에도 안 걸리는 경우. 현재 classify 는 만들지 않는다
#
# CTRL3 의 LOCKED(bit3)는 링크별이 아니라 집계 비트 하나다. 벤치 실측에서 듀얼 구성 중
# ch0 를 뽑든 ch1 을 뽑든 동일한 값(0x32 / link_status=3)이 나왔다 — 즉 이 레지스터만으로는
# 어느 채널이 문제인지 원리적으로 알 수 없다. 그래서 채널을 귀속하는 판정을 두지 않는다.
# 링크별 판별은 RX3(0x002F)의 SYNC_LOCKED_A/B·WBLOCK_A/B 로 가능하다(런타임 이탈 한정).
# 별도 과제로 다룬다.
classify_ctrl3() {
    local expect="$2"
    if ! parse_ctrl3 "$1"; then
        # 16진 토큰 자체가 없다 = i2c 읽기 실패(NACK / deserializer 접근 불가).
        # "유효값인데 비트 조합이 미정의(unknown)"와 달리 통신 자체가 안 된 것이므로
        # 조용히 넘기면 죽은 deserializer 가 상위에 전혀 보이지 않는다. 구분해서 올린다.
        ctrl3_verdict="read_fail"
        return
    fi
    if [ "$ctrl3_cmu" -eq 0 ] || [ "$ctrl3_locked" -eq 0 ]; then
        ctrl3_verdict="err_both"
        return
    fi
    if [ "$ctrl3_mode" -eq "$expect" ]; then
        if [ "$ctrl3_error" -eq 1 ]; then
            ctrl3_verdict="errb_only"
        else
            ctrl3_verdict="ok"
        fi
        return
    fi
    # 드라이버가 설정해 둔 LINK_MODE 가 아니다. 듀얼 구성에서 이 값이 읽히면 외부에서
    # CTRL0(0x0010)을 바꿨다는 뜻이고, 그 값으로 채널을 귀속할 근거가 없다.
    ctrl3_verdict="mode_unexpected"
}

# RX3 는 log_ctrl3 가 불릴 때, 즉 이상이 감지됐을 때만 읽는다. 정상(ok)일 때는 읽지
# 않는다. errb_only(LOCKED=1 + ERRB)에서도 읽는 것은 의도된 선택이다 — 링크는 살아
# 있지만 직전에 튀었다 회복한 흔적이 남아 있을 수 있고, 그 순간이 포착 가치가 가장
# 높다. 링크 단절(LOCKED=0 → err_both)과는 같은 순간에 공존할 수 없어 서로 간섭하지
# 않는다.

# 판정 근거를 원시값·비트·드라이버 비트·RX3 링크 상태까지 한 줄로 남긴다.
# rx3/link 는 기록 전용이며 판정에는 쓰지 않는다. drv 와 대조해 일치율을 재기 위한 것.
# $1=level  $2=i2c adapter  $3=호출부 LINENO  $4=메시지  $5=CTRL3 원시값
log_ctrl3() {
    local drv rx3 hint
    drv=$(cat "/sys/bus/i2c/devices/$2-0048/link_status" 2>/dev/null | tr -d '\n')
    rx3=$(read_rx3_links "$2")
    # 판별되면 기록해 두고, 모호해진 뒤에는 그 기록을 덧붙인다(lib/cam_state.sh).
    hint=$(rx3_link_hint "$2" "$rx3")
    logger -p "local0.$1" "[CHK][$tag:$3] $4 : $5 (mode=$ctrl3_mode locked=$ctrl3_locked error=$ctrl3_error cmu=$ctrl3_cmu verdict=$ctrl3_verdict drv=${drv:-NA} rx3=${rx3%%/*} link=${rx3##*/}${hint})"
}

# 정상 판정을 주기적으로 한 줄만 notice 로 올린다.
#
# 정상은 debug 라 기본 로그 레벨에서 사라진다. 그래서 다른 계층이 실패했을 때
# (예: gstApp 이 채널을 못 띄웠을 때) "그 시점 링크는 정상이었나"를 확인할 방법이
# 없다 — 정상 로그의 부재는 '정상이었다'의 증거가 아니라 '레벨에 걸러졌다'와
# 구분되지 않는다. debug 는 그대로 두고 기록용 한 줄을 따로 남긴다.
#
# 매 호출 올리면 저널을 메워 정작 필요한 줄이 밀려난다. 버스별로 간격을 둔다.
# RX3 는 읽지 않는다 — 정상일 때 i2c 를 더 태우지 않는다는 결정(위 주석)을 지킨다.
# drv 는 sysfs 라 비용이 없어 함께 남긴다.
OK_NOTICE_INTERVAL_SEC="${OK_NOTICE_INTERVAL_SEC:-300}"

# $1=i2c adapter  $2=호출부 LINENO  $3=라벨  $4=CTRL3 원시값
log_ok() {
    local f now ts drv
    logger -p local0.debug "[CHK][$tag:$2] $3 OK"
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    f="${STATE_DIR}/ok_notice_ts_$1"
    now=$(date +%s)
    ts=$(cat "$f" 2>/dev/null | tr -d '\n')
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    # 시계가 뒤로 가면 경과가 음수가 되어 영영 안 찍힌다. 그때는 즉시 한 번 찍고 갱신.
    [ $((now - ts)) -ge "$OK_NOTICE_INTERVAL_SEC" ] || [ $((now - ts)) -lt 0 ] || return 0
    printf '%s' "$now" > "$f"
    drv=$(cat "/sys/bus/i2c/devices/$1-0048/link_status" 2>/dev/null | tr -d '\n')
    logger -p local0.notice "[CHK][$tag:$2] $3 OK : $4 (mode=$ctrl3_mode locked=$ctrl3_locked error=$ctrl3_error cmu=$ctrl3_cmu drv=${drv:-NA})"
}

cam_ch_en=$1
# 전 채널 disable 시 deserializer가 power-down되어 i2c NACK이 발생하므로 i2c 트랜잭션 자체를 건너뛴다.
if [ "${cam_ch_en:-0}" -eq 0 ] 2>/dev/null; then
    logger -p local0.info "[CHK][$tag:$LINENO] all camera channels disabled (cam_ch_en=${cam_ch_en:-0}), skip i2c check"
    exit 0
fi
if [[ $((cam_ch_en&0x01)) == 1 ]]; then
    cam_ch0="true"
else
    cam_ch0="false"
fi
if [[ $((cam_ch_en>>1&0x01)) == 1 ]]; then
    cam_ch1="true"
else
    cam_ch1="false"
fi
if [[ $((cam_ch_en>>2&0x01)) == 1 ]]; then
    cam_ch2="true"
else
    cam_ch2="false"
fi
if [[ $((cam_ch_en>>3&0x01)) == 1 ]]; then
    cam_ch3="true"
else
    cam_ch3="false"
fi

#ch0/1 Des check
cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
#ch2/3 Des check
cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)

#if [[ ! -s "$FILE_JSON" ]]; then
#    logger -p local0.error "[CHK][$tag:$LINENO] Not Found $FILE_JSON"
#    result=1 ;
#else
#cam_ch0=$(jq '.VHL_CAM.cam_ch0' "$FILE_JSON")
#cam_ch1=$(jq '.VHL_CAM.cam_ch1' "$FILE_JSON")
#cam_ch2=$(jq '.VHL_CAM.cam_ch2' "$FILE_JSON")
#cam_ch3=$(jq '.VHL_CAM.cam_ch3' "$FILE_JSON")

#CAM0, CAM1 ENABLE
if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
    classify_ctrl3 "$cam01_res" "$LM_BOTH_EXPECT"
    if [ "$ctrl3_verdict" = "ok" ]; then
        log_ok 2 $LINENO "CAM0 CAM1" "$cam01_res"
    else
        recovered_by=""
        # Phase 1: read-only retry (no reset write)
        # errb_only 는 링크가 안정적으로 락된 상태라 읽기 재시도로 바뀌지 않으므로 건너뛴다.
        if [ "$ctrl3_verdict" != "errb_only" ]; then
            for r in 1 2 3; do
                sleep 0.3
                cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
                classify_ctrl3 "$cam01_res" "$LM_BOTH_EXPECT"
                if [ "$ctrl3_verdict" = "ok" ]; then
                    recovered_by="read retry $r"
                    break
                fi
                # 재시도 중 errb_only 로 바뀌면 남은 재시도도 의미가 없다.
                [ "$ctrl3_verdict" = "errb_only" ] && break
            done
        fi

        # 리셋(CTRL0 0x0010 write)은 두지 않는다. 그 write 는 0x31 =
        # RESET_ONESHOT|AUTO_LINK|LINK_CFG(A) 로, splitter 구성을 단일링크 auto 모드로
        # 바꿔버린다(드라이버 max9296.c:444-445 "// auto link", splitter 유지값은 0x23).
        # 그래서 리셋 뒤에는 SUCCESS 값(Splitter)에 도달할 경로가 없다 — 필드 로그에서
        # 리셋 41회 복구 0회, 벤치에서 5초 대기해도 0x22 고정이었다.
        # 게다가 그렇게 바뀐 LINK_MODE 를 되읽어 채널을 지목해 왔는데, 독립 증거
        # (gstApp Fragment opened)와 일치율이 0/10 이었다.

        # error classification
        case "$ctrl3_verdict" in
            ok)
                logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 recovered (${recovered_by:-read retry})"
                ;;
            errb_only)
                log_ctrl3 warning 2 $LINENO "CAM01 ERRB asserted but link locked" "$cam01_res"
                ;;
            err_both)
                # LOCKED/CMU 미락은 링크 단위 사건이라 두 채널이 함께 영향받는다.
                log_ctrl3 error 2 $LINENO "CAM01_ERR" "$cam01_res"
                echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
                echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
                ;;
            mode_unexpected)
                # 드라이버는 듀얼 구성에서 Splitter 로 설정한다. 단일링크 모드가 읽혔다면
                # 외부에서 CTRL0 를 바꾼 것이고, 그 값으로 채널을 귀속할 수 없다.
                log_ctrl3 error 2 $LINENO "CAM01_ERR unexpected LINK_MODE" "$cam01_res"
                echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
                echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
                ;;
            read_fail)
                # 재시도 후에도 i2c 를 못 읽었다 = deserializer 통신 불가.
                log_ctrl3 error 2 $LINENO "CAM01 CTRL3 read failed after retry" "$cam01_res"
                echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
                echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
                ;;
            *)
                log_ctrl3 error 2 $LINENO "CAM01 UNKNOWN CTRL3, no error flag" "$cam01_res"
                ;;
        esac
    fi
#CAM0 ENABLE ONLY
elif [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1" == *"$DISABLE_VAL"* ]]; then
    classify_ctrl3 "$cam01_res" "$CH_EVEN_LINK"
    case "$ctrl3_verdict" in
        ok)
            log_ok 2 $LINENO "CAM0" "$cam01_res"
            ;;
        errb_only)
            log_ctrl3 warning 2 $LINENO "CAM0 ERRB asserted but link locked" "$cam01_res"
            ;;
        read_fail)
            log_ctrl3 error 2 $LINENO "CAM0 CTRL3 read failed" "$cam01_res"
            echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
            ;;
        unknown)
            log_ctrl3 error 2 $LINENO "CAM0 UNKNOWN CTRL3, no error flag" "$cam01_res"
            ;;
        # mode_unexpected / err_both 는 아래 *) 캐치올이 처리한다(swap 감지 포함).
        # unknown 은 classify_ctrl3 가 만들지 않지만 ctrl3_verdict 초기값이라 남겨둔다.
        *)
            if [ "$ctrl3_locked" -eq 1 ] && [ "$ctrl3_mode" -eq "$CH_ODD_LINK" ]; then
                log_ctrl3 warning 2 $LINENO "please swap ch0 and ch1(CAM0 enable but CAM1 display)" "$cam01_res"
            else
                log_ctrl3 error 2 $LINENO "CAM0_ERR" "$cam01_res"
                echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
            fi
            ;;
    esac
#CAM1 ENABLE ONLY
elif [[ "$cam_ch0" == *"$DISABLE_VAL"* ]] && [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
    classify_ctrl3 "$cam01_res" "$CH_ODD_LINK"
    case "$ctrl3_verdict" in
        ok)
            log_ok 2 $LINENO "CAM1" "$cam01_res"
            ;;
        errb_only)
            log_ctrl3 warning 2 $LINENO "CAM1 ERRB asserted but link locked" "$cam01_res"
            ;;
        read_fail)
            log_ctrl3 error 2 $LINENO "CAM1 CTRL3 read failed" "$cam01_res"
            echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
            ;;
        unknown)
            log_ctrl3 error 2 $LINENO "CAM1 UNKNOWN CTRL3, no error flag" "$cam01_res"
            ;;
        # mode_unexpected / err_both 는 아래 *) 캐치올이 처리한다(swap 감지 포함).
        # unknown 은 classify_ctrl3 가 만들지 않지만 ctrl3_verdict 초기값이라 남겨둔다.
        *)
            if [ "$ctrl3_locked" -eq 1 ] && [ "$ctrl3_mode" -eq "$CH_EVEN_LINK" ]; then
                log_ctrl3 warning 2 $LINENO "please swap ch0 and ch1(CAM1 enable but CAM0 display)" "$cam01_res"
            else
                log_ctrl3 error 2 $LINENO "CAM1_ERR" "$cam01_res"
                echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
            fi
            ;;
    esac
else
    logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 disable"
fi

#CAM2,CAM3 ENABLE
if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
    classify_ctrl3 "$cam23_res" "$LM_BOTH_EXPECT"
    if [ "$ctrl3_verdict" = "ok" ]; then
        log_ok 1 $LINENO "CAM2 CAM3" "$cam23_res"
    else
        recovered_by=""
        # Phase 1: read-only retry (no reset write)
        # errb_only 는 링크가 안정적으로 락된 상태라 읽기 재시도로 바뀌지 않으므로 건너뛴다.
        if [ "$ctrl3_verdict" != "errb_only" ]; then
            for r in 1 2 3; do
                sleep 0.3
                cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)
                classify_ctrl3 "$cam23_res" "$LM_BOTH_EXPECT"
                if [ "$ctrl3_verdict" = "ok" ]; then
                    recovered_by="read retry $r"
                    break
                fi
                # 재시도 중 errb_only 로 바뀌면 남은 재시도도 의미가 없다.
                [ "$ctrl3_verdict" = "errb_only" ] && break
            done
        fi

        # 리셋(CTRL0 0x0010 write)은 두지 않는다. 근거는 CAM01 블록 주석 참조.

        # error classification
        case "$ctrl3_verdict" in
            ok)
                logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 recovered (${recovered_by:-read retry})"
                ;;
            errb_only)
                log_ctrl3 warning 1 $LINENO "CAM23 ERRB asserted but link locked" "$cam23_res"
                ;;
            err_both)
                # LOCKED/CMU 미락은 링크 단위 사건이라 두 채널이 함께 영향받는다.
                log_ctrl3 error 1 $LINENO "CAM23_ERR" "$cam23_res"
                echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
                echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
                ;;
            mode_unexpected)
                # 드라이버는 듀얼 구성에서 Splitter 로 설정한다. 단일링크 모드가 읽혔다면
                # 외부에서 CTRL0 를 바꾼 것이고, 그 값으로 채널을 귀속할 수 없다.
                log_ctrl3 error 1 $LINENO "CAM23_ERR unexpected LINK_MODE" "$cam23_res"
                echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
                echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
                ;;
            read_fail)
                # 재시도 후에도 i2c 를 못 읽었다 = deserializer 통신 불가.
                log_ctrl3 error 1 $LINENO "CAM23 CTRL3 read failed after retry" "$cam23_res"
                echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
                echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
                ;;
            *)
                log_ctrl3 error 1 $LINENO "CAM23 UNKNOWN CTRL3, no error flag" "$cam23_res"
                ;;
        esac
    fi
#CAM2 ENABLE ONLY
elif [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3" == *"$DISABLE_VAL"* ]]; then
    classify_ctrl3 "$cam23_res" "$CH_EVEN_LINK"
    case "$ctrl3_verdict" in
        ok)
            log_ok 1 $LINENO "CAM2" "$cam23_res"
            ;;
        errb_only)
            log_ctrl3 warning 1 $LINENO "CAM2 ERRB asserted but link locked" "$cam23_res"
            ;;
        read_fail)
            log_ctrl3 error 1 $LINENO "CAM2 CTRL3 read failed" "$cam23_res"
            echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
            ;;
        unknown)
            log_ctrl3 error 1 $LINENO "CAM2 UNKNOWN CTRL3, no error flag" "$cam23_res"
            ;;
        # mode_unexpected / err_both 는 아래 *) 캐치올이 처리한다(swap 감지 포함).
        # unknown 은 classify_ctrl3 가 만들지 않지만 ctrl3_verdict 초기값이라 남겨둔다.
        *)
            if [ "$ctrl3_locked" -eq 1 ] && [ "$ctrl3_mode" -eq "$CH_ODD_LINK" ]; then
                log_ctrl3 warning 1 $LINENO "please swap ch2 and ch3(CAM2 enable but CAM3 display)" "$cam23_res"
            else
                log_ctrl3 error 1 $LINENO "CAM2_ERR" "$cam23_res"
                echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
            fi
            ;;
    esac
#CAM3 ENABLE ONLY
elif [[ "$cam_ch2" == *"$DISABLE_VAL"* ]] && [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
    classify_ctrl3 "$cam23_res" "$CH_ODD_LINK"
    case "$ctrl3_verdict" in
        ok)
            log_ok 1 $LINENO "CAM3" "$cam23_res"
            ;;
        errb_only)
            log_ctrl3 warning 1 $LINENO "CAM3 ERRB asserted but link locked" "$cam23_res"
            ;;
        read_fail)
            log_ctrl3 error 1 $LINENO "CAM3 CTRL3 read failed" "$cam23_res"
            echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
            ;;
        unknown)
            log_ctrl3 error 1 $LINENO "CAM3 UNKNOWN CTRL3, no error flag" "$cam23_res"
            ;;
        # mode_unexpected / err_both 는 아래 *) 캐치올이 처리한다(swap 감지 포함).
        # unknown 은 classify_ctrl3 가 만들지 않지만 ctrl3_verdict 초기값이라 남겨둔다.
        *)
            if [ "$ctrl3_locked" -eq 1 ] && [ "$ctrl3_mode" -eq "$CH_EVEN_LINK" ]; then
                log_ctrl3 warning 1 $LINENO "please swap ch2 and ch3(CAM3 enable but CAM2 display)" "$cam23_res"
            else
                log_ctrl3 error 1 $LINENO "CAM3_ERR" "$cam23_res"
                echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
            fi
            ;;
    esac
else
    logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 disable"
fi
#fi
