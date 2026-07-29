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
#   드라이버(max9296.c)/설계문서   : ch0=Link A, ch1=Link B
#   기존 스크립트 상수(CH0_EN_OK=0xea) : ch0=Link B, ch1=Link A  ← 현재 동작
# 두 소스의 매핑이 서로 반대다. 실측으로 확정될 때까지 기존 동작을 유지하며,
# 확정되면 아래 두 줄만 교체하면 모든 판정이 따라간다.
CH_EVEN_LINK=$LM_LINK_B    # ch0, ch2
CH_ODD_LINK=$LM_LINK_A     # ch1, ch3

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
#   ok        : 정상
#   errb_only : 링크는 락됐고 ERRB 만 어서트 (리셋 금지 / 에러 플래그 금지)
#   err_even  : 짝수 채널(ch0/ch2) 링크 소실
#   err_odd   : 홀수 채널(ch1/ch3) 링크 소실
#   err_both  : 양 채널 소실 (CMU 미락 또는 GMSL2 미락)
#   read_fail : i2c 읽기 실패 — 재시도 후에도 지속되면 해당 버스 채널을 에러로 올린다
#   unknown   : 유효값이나 비트 조합이 미정의 — 에러 플래그를 만들지 않는다
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
    # 기대 모드가 아니면 살아남은 링크의 반대쪽 채널이 소실된 것이다.
    if [ "$ctrl3_mode" -eq "$CH_EVEN_LINK" ]; then
        ctrl3_verdict="err_odd"
    elif [ "$ctrl3_mode" -eq "$CH_ODD_LINK" ]; then
        ctrl3_verdict="err_even"
    else
        ctrl3_verdict="unknown"
    fi
}

# 링크가 실제로 깨진 경우에만 리셋한다.
# ERRB 만 어서트된 상태(LOCKED=1)에 리셋을 쏘면 정상 링크를 끊는다.
ctrl3_needs_reset() {
    case "$1" in
        err_even|err_odd|err_both|read_fail) return 0 ;;
        *) return 1 ;;
    esac
}

# 판정 근거를 원시값·비트·드라이버 비트까지 한 줄로 남긴다.
# 채널<->링크 매핑을 현장 로그만으로 확정하기 위한 근거 수집을 겸한다.
# $1=level  $2=i2c adapter  $3=호출부 LINENO  $4=메시지  $5=CTRL3 원시값
log_ctrl3() {
    local drv
    drv=$(cat "/sys/bus/i2c/devices/$2-0048/link_status" 2>/dev/null | tr -d '\n')
    logger -p "local0.$1" "[CHK][$tag:$3] $4 : $5 (mode=$ctrl3_mode locked=$ctrl3_locked error=$ctrl3_error cmu=$ctrl3_cmu verdict=$ctrl3_verdict drv=${drv:-NA})"
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
        # Phase 1: read-only retry (no reset write)
        for r in 1 2 3; do
            sleep 0.3
            cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
            classify_ctrl3 "$cam01_res" "$LM_BOTH_EXPECT"
            if [ "$ctrl3_verdict" = "ok" ]; then
                logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 OK (read retry $r)"
                break
            fi
        done

        # Phase 2: 링크가 실제로 깨졌을 때만 리셋 + 재확인
        if ctrl3_needs_reset "$ctrl3_verdict"; then
            log_ctrl3 error 2 $LINENO "CAM01 link fail, reset" "$cam01_res"
            i2ctransfer -f -y -a 2 w3@0x48 0x00 0x10 0x31
            i2ctransfer -f -y -a 2 w3@0x40 0x00 0x10 0x21
            sleep 1
            cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
            classify_ctrl3 "$cam01_res" "$LM_BOTH_EXPECT"
        fi

        # error classification
        case "$ctrl3_verdict" in
            ok)
                logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 recovered after reset"
                ;;
            errb_only)
                log_ctrl3 warning 2 $LINENO "CAM01 ERRB asserted but link locked, no reset" "$cam01_res"
                ;;
            err_even)
                log_ctrl3 error 2 $LINENO "CAM0_ERR" "$cam01_res"
                echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
                ;;
            err_odd)
                log_ctrl3 error 2 $LINENO "CAM1_ERR" "$cam01_res"
                echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
                ;;
            err_both)
                log_ctrl3 error 2 $LINENO "CAM01_ERR" "$cam01_res"
                echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
                echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
                ;;
            read_fail)
                # 재시도·리셋 후에도 i2c 를 못 읽었다 = deserializer 통신 불가.
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
            log_ctrl3 warning 2 $LINENO "CAM0 ERRB asserted but link locked, no reset" "$cam01_res"
            ;;
        read_fail)
            log_ctrl3 error 2 $LINENO "CAM0 CTRL3 read failed" "$cam01_res"
            echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
            ;;
        unknown)
            log_ctrl3 error 2 $LINENO "CAM0 UNKNOWN CTRL3, no error flag" "$cam01_res"
            ;;
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
            log_ctrl3 warning 2 $LINENO "CAM1 ERRB asserted but link locked, no reset" "$cam01_res"
            ;;
        read_fail)
            log_ctrl3 error 2 $LINENO "CAM1 CTRL3 read failed" "$cam01_res"
            echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
            ;;
        unknown)
            log_ctrl3 error 2 $LINENO "CAM1 UNKNOWN CTRL3, no error flag" "$cam01_res"
            ;;
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
        # Phase 1: read-only retry (no reset write)
        for r in 1 2 3; do
            sleep 0.3
            cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)
            classify_ctrl3 "$cam23_res" "$LM_BOTH_EXPECT"
            if [ "$ctrl3_verdict" = "ok" ]; then
                logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 OK (read retry $r)"
                break
            fi
        done

        # Phase 2: 링크가 실제로 깨졌을 때만 리셋 + 재확인
        if ctrl3_needs_reset "$ctrl3_verdict"; then
            log_ctrl3 error 1 $LINENO "CAM23 link fail, reset" "$cam23_res"
            i2ctransfer -f -y -a 1 w3@0x48 0x00 0x10 0x31
            i2ctransfer -f -y -a 1 w3@0x40 0x00 0x10 0x21
            sleep 1
            cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)
            classify_ctrl3 "$cam23_res" "$LM_BOTH_EXPECT"
        fi

        # error classification
        case "$ctrl3_verdict" in
            ok)
                logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 recovered after reset"
                ;;
            errb_only)
                log_ctrl3 warning 1 $LINENO "CAM23 ERRB asserted but link locked, no reset" "$cam23_res"
                ;;
            err_even)
                log_ctrl3 error 1 $LINENO "CAM2_ERR" "$cam23_res"
                echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
                ;;
            err_odd)
                log_ctrl3 error 1 $LINENO "CAM3_ERR" "$cam23_res"
                echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
                ;;
            err_both)
                log_ctrl3 error 1 $LINENO "CAM23_ERR" "$cam23_res"
                echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
                echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
                ;;
            read_fail)
                # 재시도·리셋 후에도 i2c 를 못 읽었다 = deserializer 통신 불가.
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
            log_ctrl3 warning 1 $LINENO "CAM2 ERRB asserted but link locked, no reset" "$cam23_res"
            ;;
        read_fail)
            log_ctrl3 error 1 $LINENO "CAM2 CTRL3 read failed" "$cam23_res"
            echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
            ;;
        unknown)
            log_ctrl3 error 1 $LINENO "CAM2 UNKNOWN CTRL3, no error flag" "$cam23_res"
            ;;
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
            log_ctrl3 warning 1 $LINENO "CAM3 ERRB asserted but link locked, no reset" "$cam23_res"
            ;;
        read_fail)
            log_ctrl3 error 1 $LINENO "CAM3 CTRL3 read failed" "$cam23_res"
            echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
            ;;
        unknown)
            log_ctrl3 error 1 $LINENO "CAM3 UNKNOWN CTRL3, no error flag" "$cam23_res"
            ;;
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
