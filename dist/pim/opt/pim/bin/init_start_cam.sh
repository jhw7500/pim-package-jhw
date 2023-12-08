#!/bin/bash
key=RST
csi1_en=0
csi2_en=0
ENABLE_VAL=true
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
logger -p local0.notice "[$KEY][$tag:$LINENO] json_file : $FILE_JSON"
cam_ch0_en=$(cat $FILE_JSON | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch1_en=$(cat $FILE_JSON | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch2_en=$(cat $FILE_JSON | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch3_en=$(cat $FILE_JSON | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
if [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch1_en" == *"$ENABLE_VAL"* ]]; then
    logger -p local0.notice "[$key][$tag:$LINENO] csi1 enable"
    csi1_en=1
fi

if [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch3_en" == *"$ENABLE_VAL"* ]]; then
    logger -p local0.notice "[$key][$tag:$LINENO] csi2 enable"
    csi2_en=1
fi

if [[ "$csi1_en" -eq 1 ]] && [[ "$csi2_en" -eq 1 ]]; then
    PIMCAM -d 25 -m 0 &
else
    PIMCAM -d 15 -m 0 &
fi
