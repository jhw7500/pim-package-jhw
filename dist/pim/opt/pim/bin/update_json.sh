#!/usr/bin/env bash

#FILE_JSON="/home/user/edgeconf_pim.json"
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
cp $FILE_JSON $FILE_JSON.backup
#updated_json=$(jq '(.VHL_CAM.vertical // 0) as $v | if $v == 0 then .VHL_CAM.vertical = 0 else . end' "$FILE_JSON")
#UPDATE_JSON=$(jq '(.VHL_CAM.vertical_flip // 0) as $v | (.VHL_CAM.horizontal_flip // 0) as $h | .VHL_CAM.vertical_flip = $v | .VHL_CAM.horizontal_flip = $h' "$FILE_JSON")

UPDATE_JSON=$(jq 'if .VHL_CAM.log_level == null then .VHL_CAM.log_level = 5 else . end' "$FILE_JSON")
echo "$UPDATE_JSON" > "$FILE_JSON"

UPDATE_JSON=$(jq 'if .VHL_CAM.debug_level == null then .VHL_CAM.debug_level = 0 else . end' "$FILE_JSON")
echo "$UPDATE_JSON" > "$FILE_JSON"

UPDATE_JSON=$(jq 'if .VHL_CAM.app == null then .VHL_CAM.app = "streamApp" else . end' "$FILE_JSON")
echo "$UPDATE_JSON" > "$FILE_JSON"

key_name=0
for num in {0..3}
do
    key_name="cam_ch${num}_rotate"
    UPDATE_JSON=$(jq --arg key "$key_name" 'del(.VHL_CAM[$key])' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    key_name="ch${num}_vflip"
    UPDATE_JSON=$(jq --arg key "$key_name" 'if .VHL_CAM[$key] == null then .VHL_CAM[$key] = false else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    key_name="ch${num}_hflip"
    UPDATE_JSON=$(jq --arg key "$key_name" 'if .VHL_CAM[$key] == null then .VHL_CAM[$key] = false else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"
done

#streamApp
if [[ $1 == 1 ]]; then
    UPDATE_JSON=$(jq 'del(.VHL_CAM.rec_fps)' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'del(.VHL_CAM.rtsp_fps)' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'del(.VHL_CAM.rec_bps)' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'del(.VHL_CAM.rtsp_bps)' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'if .VHL_CAM.fps == null then .VHL_CAM.fps = 15 else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'if .VHL_CAM.bitrate == null then .VHL_CAM.bitrate = 1024 else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq '.VHL_CAM.app = "streamApp"' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

#gstApp
elif [[ $1 == 2 ]]; then
    UPDATE_JSON=$(jq 'del(.VHL_CAM.fps)' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'del(.VHL_CAM.bitrate)' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'if .VHL_CAM.rec_fps == null then .VHL_CAM.rec_fps = 15 else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'if .VHL_CAM.rtsp_fps == null then .VHL_CAM.rtsp_fps = 15 else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'if .VHL_CAM.rec_bps == null then .VHL_CAM.rec_bps = 4096 else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq 'if .VHL_CAM.rtsp_bps == null then .VHL_CAM.rtsp_bps = 1024 else . end' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

    UPDATE_JSON=$(jq '.VHL_CAM.app = "gstApp"' "$FILE_JSON")
    echo "$UPDATE_JSON" > "$FILE_JSON"

fi
