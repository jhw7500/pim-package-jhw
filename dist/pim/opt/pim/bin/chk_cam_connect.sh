#!/bin/bash
#JSON_PREFIX=edgeconf_
#JOSN_SUFFIX=.json
#FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
FLAG_PATH="/tmp"
tag=$(basename "$0")

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

# 짝수 채널(ch0/ch2)과 홀수 채널(ch1/ch3)이 각각 어느 GMSL2 링크에 붙어 있는가.
# 벤치 실측(2026-07-31)으로 확정. 결정적 근거는 '런타임 이탈' 실험이다 — 정상 상태에서
# 시작해 변수 하나만 바꾸므로 해석 여지가 없다.
#   둘 다 연결        RX3=0x66  (Link A·B 모두 SYNC_LOCKED+WBLOCK)
#   └ ch1 물리 제거   RX3=0x60  (Link A 비트만 소거, Link B 는 락 유지)
#   ⇒ ch1 = Link A, ch0 = Link B
#
# 부팅 시점 실험(카메라 하나 없이 부팅)은 이와 반대로 읽히기 쉬우니 주의:
#   ch1 제거 → FAILLOCK_B / ch0 제거 → FAILLOCK_A
# FAILLOCK 은 '빠진 링크'가 아니라 '카메라가 있는데도 splitter 훈련에 실패한 링크'를
# 표시한다. 부팅 시엔 양 링크가 다 안 올라와 이 구분이 보이지 않는다. 위 런타임
# 실험과 교차하면 두 결과가 같은 니블을 ch0 로 가리켜 일관된다.
#
# 드라이버(max9296.c)/설계문서는 ch0=Link A(serializer 0x40)라고 한다. RX3 의 Link A/B
# 는 PHY 레인 라벨이라 보드 배선에 따라 드라이버의 주소 배정과 반대일 수 있다. 우리가
# 읽는 것은 RX3 프레임이므로 아래 값을 따른다.
CH_EVEN_LINK=$LM_LINK_B    # ch0, ch2 → RX3 기준 Link B
CH_ODD_LINK=$LM_LINK_A     # ch1, ch3 → RX3 기준 Link A

# ── MAX9296 RX3(0x002F) — 링크별 래치 ──────────────────────────────
#  bit6 SYNC_LOCKED_B / bit5 WBLOCK_B / bit4 FAILLOCK_B
#  bit2 SYNC_LOCKED_A / bit1 WBLOCK_A / bit0 FAILLOCK_A
# FAILLOCK 은 Read-Clear 다(실측: 0x01 → 0x00 → 0x00). 링크가 계속 죽어 있어도
# 두 번째 읽기부터 0이 되므로 레벨 신호로 쓸 수 없다.
#
# 반면 SYNC_LOCKED/WBLOCK 은 RO 라 read-clear 가 아니고, 런타임 이탈에서 링크별로
# 정확히 갈린다(실측: 0x66 → ch1 제거 → 0x60). 즉 현장의 실제 실패 유형에서는 이
# 비트들로 채널 특정이 가능하다. 다만 부팅 시점 부재에서는 양 링크가 다 0이 되어
# 구분되지 않는다.
#
# 이번 변경에서는 판정에 쓰지 않고 진단 로그에만 남긴다. 현장 로그로 두 유형의
# 분포와 포착률을 확인한 뒤 귀속 사용 여부를 별도로 판단한다.
RX3_FAILLOCK_A=0x01
RX3_FAILLOCK_B=0x10

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

# RX3(0x002F)를 한 번 읽어 어느 링크가 락에 실패했는지 문자열로 돌려준다.
# 출력: "<원시값>/<A|B|AB|none>" 또는 읽기 실패 시 "NA/NA"
#
# 호출 시점: log_ctrl3 가 불릴 때, 즉 이상이 감지됐을 때만. 정상(ok)일 때는 읽지 않아
# 래치를 헛되이 소비하지 않는다.
#
# errb_only(LOCKED=1 + ERRB)에서도 읽는 것은 의도된 선택이다. 이 상태는 링크가 살아
# 있으므로 "지금 끊긴 링크"는 없지만, 직전에 튀었다가 회복된 링크의 래치가 남아 있을 수
# 있다 — 그 순간이 오히려 포착 가치가 가장 높다. 링크 단절(LOCKED=0 → err_both)과는
# 같은 순간에 공존할 수 없으므로(배타적) 서로의 래치를 가로채지 않는다.
#
# faillock=none 의 해석 주의: "실패가 없었다"와 "이미 누가 읽어 지워졌다"를 구분할 수
# 없다. 다만 드라이버(max9296.c)는 des(0x48) 상태 레지스터를 전혀 읽지 않으므로
# (i2c read 3건 모두 AP1302 ISP 대상) 실사용에서 다른 소비자는 이 스크립트뿐이다.
read_rx3_faillock() {
    local raw val a b
    raw=$(i2ctransfer -f -y -a "$1" w2@0x48 0x00 0x2f r1 2>/dev/null \
          | grep -oE '0[xX][0-9a-fA-F]+' | head -1)
    [ -n "$raw" ] || { printf 'NA/NA'; return; }
    val=$(( raw )); a=0; b=0
    [ $(( val & RX3_FAILLOCK_A )) -ne 0 ] && a=1
    [ $(( val & RX3_FAILLOCK_B )) -ne 0 ] && b=1
    if   [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then printf '%s/AB' "$raw"
    elif [ "$a" -eq 1 ];                   then printf '%s/A'  "$raw"
    elif [ "$b" -eq 1 ];                   then printf '%s/B'  "$raw"
    else                                        printf '%s/none' "$raw"
    fi
}

# 판정 근거를 원시값·비트·드라이버 비트·RX3 래치까지 한 줄로 남긴다.
# rx3/faillock 은 이번 변경에서 기록 전용이며 판정에는 쓰지 않는다.
# $1=level  $2=i2c adapter  $3=호출부 LINENO  $4=메시지  $5=CTRL3 원시값
log_ctrl3() {
    local drv rx3
    drv=$(cat "/sys/bus/i2c/devices/$2-0048/link_status" 2>/dev/null | tr -d '\n')
    rx3=$(read_rx3_faillock "$2")
    logger -p "local0.$1" "[CHK][$tag:$3] $4 : $5 (mode=$ctrl3_mode locked=$ctrl3_locked error=$ctrl3_error cmu=$ctrl3_cmu verdict=$ctrl3_verdict drv=${drv:-NA} rx3=${rx3%%/*} faillock=${rx3##*/})"
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
        logger -p local0.debug "[CHK][$tag:$LINENO] CAM0 CAM1 OK"
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
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM0 OK"
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
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM1 OK"
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
        logger -p local0.debug "[CHK][$tag:$LINENO] CAM2 CAM3 OK"
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
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM2 OK"
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
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM3 OK"
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
