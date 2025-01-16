#!/usr/bin/env bash
tag=$(basename "$0")
KEY=PKG
#FILE_JSON="/home/user/edgeconf_pim.json"
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
cp "$FILE_JSON" "/opt/pim/config/${FILE_JSON##*/}.backup"
#updated_json=$(jq '(.VHL_CAM.vertical // 0) as $v | if $v == 0 then .VHL_CAM.vertical = 0 else . end' "$FILE_JSON")
#UPDATE_JSON=$(jq '(.VHL_CAM.vertical_flip // 0) as $v | (.VHL_CAM.horizontal_flip // 0) as $h | .VHL_CAM.vertical_flip = $v | .VHL_CAM.horizontal_flip = $h' "$FILE_JSON")

if ! command -v jq &> /dev/null
then
    logger -p local0.err "[$KEY][$tag:$LINENO] jq could not be found. Please install jq to run this script."
    exit 1
fi

echo -e "\e[32mplease wait for update $FILE_JSON\e[0m"
logger -p local0.notice "[$KEY][$tag:$LINENO] please wait for update $FILE_JSON$"

header_to_remove="ORD"
echo "check $header_to_remove header"
jq "if has(\"${header_to_remove}\") then del(.${header_to_remove}) else . end" "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
header_to_remove="VCM"
echo "check $header_to_remove header"
jq "if has(\"${header_to_remove}\") then del(.${header_to_remove}) else . end" "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

bps=$(jq -r '.VHL_CAM.bitrate' "$FILE_JSON")
if [ -z "$bps" ] || [ "$bps" == "null" ]; then
    echo "bps is not exist"
    bps=2048
else
    echo "bps is exist"
fi

ch0_en=$(jq -r '.VHL_CAM.cam_ch0' "$FILE_JSON")
if [ -z "$ch0_en" ] || [ "$ch0_en" == "null" ]; then
    echo "cam_ch0 is not exist"
    ch0_en="true"
else
    echo "cam_ch0 is exist"
fi

ch1_en=$(jq -r '.VHL_CAM.cam_ch1' "$FILE_JSON")
if [ -z "$ch1_en" ] || [ "$ch1_en" == "null" ]; then
    echo "cam_ch1 is not exist"
    ch1_en="true"
else
    echo "cam_ch1 is exist"
fi

ch2_en=$(jq -r '.VHL_CAM.cam_ch2' "$FILE_JSON")
if [ -z "$ch2_en" ] || [ "$ch2_en" == "null" ]; then
    echo "cam_ch2 is not exist"
    ch2_en="true"
else
    echo "cam_ch2 is exist"
fi

ch3_en=$(jq -r '.VHL_CAM.cam_ch3' "$FILE_JSON")
if [ -z "$ch3_en" ] || [ "$ch3_en" == "null" ]; then
    echo "cam_ch3 is not exist"
    ch3_en="true"
else
    echo "cam_ch3 is exist"
fi

ch0_rotate=$(jq -r '.VHL_CAM.cam_ch0_rotate' "$FILE_JSON")
if [ -z "$ch0_rotate" ] || [ "$ch0_rotate" == "null" ]; then
    echo "ch0_rotate is not exist"
    ch0_rotate="true"
else
    echo "ch0_rotate is exist"
fi

ch1_rotate=$(jq -r '.VHL_CAM.cam_ch1_rotate' "$FILE_JSON")
if [ -z "$ch1_rotate" ] || [ "$ch1_rotate" == "null" ]; then
    echo "ch1_rotate is not exist"
    ch1_rotate="true"
else
    echo "ch1_rotate is exist"
fi

ch2_rotate=$(jq -r '.VHL_CAM.cam_ch2_rotate' "$FILE_JSON")
if [ -z "$ch2_rotate" ] || [ "$ch2_rotate" == "null" ]; then
    echo "ch2_rotate is not exist"
    ch2_rotate="true"
else
    echo "ch2_rotate is exist"
fi

ch3_rotate=$(jq -r '.VHL_CAM.cam_ch3_rotate' "$FILE_JSON")
if [ -z "$ch3_rotate" ] || [ "$ch3_rotate" == "null" ]; then
    echo "ch3_rotate is not exist"
    ch3_rotate="true"
else
    echo "ch3_rotate is exist"
fi

capture_en=$(jq -r '.VHL_CAM.capture' "$FILE_JSON")
if [ -z "$capture_en" ] || [ "$capture_en" == "null" ]; then
    echo "capture is not exist"
    capture_en="false"
else
    echo "capture is exist"
    if [ "$capture_en" == "true" ] || [ "$capture_en" == "false" ]; then
        echo "del capture"
        jq 'del (.VHL_CAM.capture)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
    fi
fi
echo "capture : $capture_en"

echo "bps=$bps, ch0=${ch0_en},$ch0_rotate, ch1=$ch1_en,$ch1_rotate ch2=$ch2_en,$ch2_rotate, ch3=$ch3_en,$ch3_rotate"
echo "update log, debug, app, id, fps"
jq '.VHL_CAM.log_level |= if . == null then 5 else . end | 
.VHL_CAM.debug_level |= if . == null then 0 else . end | 
.VHL_CAM.app |= if . == null then "streamApp" else . end |
.VHL_CAM.id |= if . == null then "user" else . end |
.VHL_CAM.fps |= if . == null then 15 else . end' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"


key_name=0
for num in {0..3}
do
    echo "check cam_ch${num}, cam_ch${num}_rotate, ch${num}_vflip, ch${num}_hflip"
#    ch${num}_en=$(jq --arg key1 "cam_ch${num}" '.VHL_CAM.$key1' "$FILE_JSON")
    jq --arg key1 "cam_ch${num}_rotate" --arg key2 "ch${num}_vflip" --arg key3 "ch${num}_hflip" --arg key4 "cam_ch${num}" \
    'del(.VHL_CAM[$key1], .VHL_CAM[$key2], .VHL_CAM[$key3], .VHL_CAM[$key4])' \
    "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"
done

echo "check vflip, hflip, bitrate, rec_fps, rtsp_ftps, rec_bps, rtsp_bps, vflip"
jq 'del(.VHL_CAM.bitrate, .VHL_CAM.rec_fps, .VHL_CAM.rtsp_fps, .VHL_CAM.rec_bps, .VHL_CAM.rtsp_bps, .VHL_CAM.vflip, .VHL_CAM.hflip)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

echo "check exp_time"
jq 'del (.VHL_CAM.ch0.exp_time, .VHL_CAM.ch1.exp_time, .VHL_CAM.ch2.exp_time, .VHL_CAM.ch3.exp_time)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

echo "check capture"
#jq 'del (.VHL_CAM.capture)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
#jq --argjson capture_en "$capture_en" '.VHL_CAM.capture |= (if .enable == null then .enable = $capture_en else . end)
#| .VHL_CAM.capture |= (if .delay == null then .delay = 0 else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
jq --argjson key0 "$capture_en" --argjson key1 0 '.VHL_CAM.capture |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.capture |= (if .delay == null then .delay = $key1 else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

echo "update i2c header"
jq '.VHL_CAM.i2c2 |= (if .exp_time == null then .exp_time = 10000 else . end)
| .VHL_CAM.i2c1 |= (if .exp_time == null then .exp_time = 10000 else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

jq '.VHL_CAM |= (if .i2c2.ch0 == null then .i2c2.ch0 = .ch0 else . end)
| .VHL_CAM |= (if .i2c2.ch1 == null then .i2c2.ch1 = .ch1 else . end)
| .VHL_CAM |= (if .i2c1.ch2 == null then .i2c1.ch2 = .ch2 else . end)
| .VHL_CAM |= (if .i2c1.ch3 == null then .i2c1.ch3 = .ch3 else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#jq 'del(.VHL | select(.ch0 != null).ch0, select(.ch1 != null).ch1, select(.ch2 != null).ch2, select(.ch3 != null).ch3)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
echo "check old channel config"
jq '.VHL_CAM |= (if .ch0 == null then . else del(.ch0) end)
| .VHL_CAM |= (if .ch1 == null then . else del(.ch1) end)
| .VHL_CAM |= (if .ch2 == null then . else del(.ch2) end)
| .VHL_CAM |= (if .ch3 == null then . else del(.ch3) end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

echo "update new channel config"
#echo "check ch0"
jq --argjson key0 "$ch0_en" --argjson key1 "$ch0_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c2.ch0 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c2.ch0 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#echo "check ch1"
jq --argjson key0 "$ch1_en" --argjson key1 "$ch1_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c2.ch1 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c2.ch1 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#echo "check ch2"
jq --argjson key0 "$ch2_en" --argjson key1 "$ch2_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c1.ch2 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c1.ch2 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#echo "check ch3"
jq --argjson key0 "$ch3_en" --argjson key1 "$ch3_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c1.ch3 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c1.ch3 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#streamApp
if [[ $1 == 1 ]]; then
    echo "update for streamApp"
    jq '.VHL_CAM.app = "streamApp"' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
#gstApp
elif [[ $1 == 2 ]]; then
    echo "update for gstApp"
    jq '.VHL_CAM.app = "gstApp"' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
fi

sync
logger -p local0.notice "[$KEY][$tag:$LINENO] complete update $FILE_JSON$"
echo -e "\e[32mcomplete update $FILE_JSON\e[0m"
#echo -e "\e[33mif you want the streamApp, run '/opt/pim/bin/update_json 1' but you want the gstApp, run 'opt/pim/bin/update_json 2'\e[0m"
