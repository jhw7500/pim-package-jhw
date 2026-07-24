#!/usr/bin/env bash
tag=$(basename "$0")
KEY=PKG

set -Ee -o pipefail

err_report() {
    local ec=$?
    local line=${BASH_LINENO[0]:-0}
    local cmd=${BASH_COMMAND}
    trap - ERR
    echo "[$KEY][$tag:$line] update failed (exit=$ec): $cmd" >&2
    logger -p local0.err "[$KEY][$tag:$line] update failed (exit=$ec): $cmd"
    exit "$ec"
}

trap err_report ERR
#FILE_JSON="/home/user/edgeconf_pim.json"
FILE_JSON=""
for f in /root/shared_v/edgeconf_*.json; do
    [ -e "$f" ] || continue
    if [ -z "$FILE_JSON" ] || [ "$f" -nt "$FILE_JSON" ]; then
        FILE_JSON="$f"
    fi
done

if [ -z "$FILE_JSON" ] || [ ! -f "$FILE_JSON" ]; then
    FILE_BACKUP_JSON=""
    for f in /root/shared_v/backup_edgeconf_*.json; do
        [ -e "$f" ] || continue
        if [ -z "$FILE_BACKUP_JSON" ] || [ "$f" -nt "$FILE_BACKUP_JSON" ]; then
            FILE_BACKUP_JSON="$f"
        fi
    done
    if [ -f "$FILE_BACKUP_JSON" ]; then
        dir=$(dirname "$FILE_BACKUP_JSON")
        file=$(basename "$FILE_BACKUP_JSON")
        newfile=${file#backup_}
        FILE_JSON="${dir}/${newfile}"
        cp "$FILE_BACKUP_JSON" "$FILE_JSON"
        logger -p local0.notice "[$KEY][$tag:$LINENO] edgeconf json copied from backup json ( $FILE_BACKUP_JSON )"
    fi
fi

if [ -z "$FILE_JSON" ] || [ ! -f "$FILE_JSON" ]; then
    logger -p local0.err "[$KEY][$tag:$LINENO] edgeconf json not found under /root/shared_v (edgeconf_*.json or backup_edgeconf_*.json)"
    exit 1
fi

if [ -d /opt/pim/config ]; then
    cp "$FILE_JSON" "/opt/pim/config/${FILE_JSON##*/}.backup"
else
    logger -p local0.err "[$KEY][$tag:$LINENO] missing /opt/pim/config"
fi

if ! jq -e . "$FILE_JSON" > /dev/null 2>&1; then
    logger -p local0.err "[$KEY][$tag:$LINENO] invalid JSON: $FILE_JSON"
    echo "[$KEY][$tag:$LINENO] invalid JSON: $FILE_JSON" >&2
    exit 1
fi
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

echo "bps=$bps, ch0=${ch0_en},$ch0_rotate, ch1=$ch1_en,$ch1_rotate ch2=$ch2_en,$ch2_rotate, ch3=$ch3_en,$ch3_rotate"
echo "update log, debug, app, id, fps"
jq '.VHL_CAM.log_level |= if . == null then 5 else . end | 
.VHL_CAM.debug_level |= if . == null then 0 else . end | 
.VHL_CAM.id |= if . == null then "user" else . end |
.VHL_CAM.fps |= if . == null then 15 else . end |
.VHL_CAM.muxer |= if . == null then "mp4" else . end |
.VHL_CAM.app = "gstApp"
' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"


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

jq --argjson key0 "$capture_en" --argjson key1 0 --argjson key2 200 '.VHL_CAM.capture |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.capture |= (if .delay == null then .delay = $key1 else . end)
| .VHL_CAM.capture |= (if .timeout == null then .timeout = $key2 else . end)
| .VHL_CAM.capture |= (if .record == null then .record = false else . end)
| .VHL_CAM.capture |= (if .rtsp == null then .rtsp = false else . end)
| .VHL_CAM.capture |= (if .encoder == null then .encoder = "turbo" else . end)
| .VHL_CAM.capture |= (if .quality == null then .quality = 85 else . end)
| .VHL_CAM.capture |= (if .response == null then .response = true else . end)
| .VHL_CAM.capture |= (if .path == null then .path = "/dev/shm/capture" else . end)
| .VHL_CAM.capture |= (if .queue_size == null then .queue_size = 30 else . end)
' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

jq '.VHL_CAM.queue_tune |= (if .main_src_time_ms == null then .main_src_time_ms = 300 else . end)
| .VHL_CAM.queue_tune |= (if .enc_src_time_ms == null then .enc_src_time_ms = 300 else . end)
| .VHL_CAM.queue_tune |= (if .rec_sink_time_ms == null then .rec_sink_time_ms = 500 else . end)
| .VHL_CAM.queue_tune |= (if .cap_src_time_ms == null then .cap_src_time_ms = 500 else . end)
' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

jq '.VHL_CAM.rtsp_tune |= (if .rtsp_factory_latency_ms == null then .rtsp_factory_latency_ms = 200 else . end)
| .VHL_CAM.rtsp_tune |= (if .rtsp_appsink_max_buffers == null then .rtsp_appsink_max_buffers = 3 else . end)
| .VHL_CAM.rtsp_tune |= (if .rtsp_factory_queue_max_buffers == null then .rtsp_factory_queue_max_buffers = 3 else . end)
| .VHL_CAM.rtsp_tune |= (if .rtsp_bin_queue_max_time_ms == null then .rtsp_bin_queue_max_time_ms = 100 else . end)
' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

jq 'del (.VHL_CAM.capture.turbojpeg)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

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

echo "check path"
jq '.VHL_CAM.tmp_path |= (. // "/dev/shm")
| .VHL_CAM.sd_tmp_path |= (. // "/mnt/sd_cam/tmp")
| .VHL_CAM.final_path |= (. // "/mnt/sd_cam")
' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

echo "check ETH1 health config"
jq '
  .NETWORK |= (. // {})
  | .NETWORK.ETH1 |= (. // {})
  | .NETWORK.ETH1 |= (
      if (.client_ip_addr != null and .client_ip_addr != "") then .
      elif (.ping_test_ip_addr != null and .ping_test_ip_addr != "") then .client_ip_addr = .ping_test_ip_addr
      else .client_ip_addr = "199.10.100.20"
      end
    )
  | .NETWORK.ETH1 |= (
      if .ping_check_enable != null then .
      else .ping_check_enable = false
      end
    )
  | .NETWORK.ETH1 |= (
      if .ping_max_fail_count != null then .
      else .ping_max_fail_count = 2
      end
    )
  | .NETWORK.ETH1 |= del(.ping_test_ip_addr)
' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

echo "update new channel config"
#echo "check ch0"
jq --argjson key0 "$ch0_en" --argjson key1 "$ch0_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c2.ch0 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c2.ch0 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c2.ch0 |= (if .awb == null then .awb = "auto" else . end)
| .VHL_CAM.i2c2.ch0 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#echo "check ch1"
jq --argjson key0 "$ch1_en" --argjson key1 "$ch1_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c2.ch1 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c2.ch1 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c2.ch1 |= (if .awb == null then .awb = "auto" else . end)
| .VHL_CAM.i2c2.ch1 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#echo "check ch2"
jq --argjson key0 "$ch2_en" --argjson key1 "$ch2_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c1.ch2 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c1.ch2 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c1.ch2 |= (if .awb == null then .awb = "auto" else . end)
| .VHL_CAM.i2c1.ch2 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#echo "check ch3"
jq --argjson key0 "$ch3_en" --argjson key1 "$ch3_rotate" --argjson key2 "$bps" '.VHL_CAM.i2c1.ch3 |= (if .enable == null then .enable = $key0 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .vflip == null then .vflip = $key1 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .hflip == null then .hflip = $key1 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .ae_on == null then .ae_on = true else . end)
| .VHL_CAM.i2c1.ch3 |= (if .ae_gain == null then .ae_gain = 256 else . end)
| .VHL_CAM.i2c1.ch3 |= (if .awb == null then .awb = "auto" else . end)
| .VHL_CAM.i2c1.ch3 |= (if .bps == null then .bps = [$key2,2048] else . end)' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

echo "check led_flash per channel"
# led_flash: integrated LED control applied via V4L2 ioctl (max9296 driver)
#   enable      : bool. gates mcp4018_power_chX (MAX9295 MFP4 GPIO) + led_flash_chX bit8 (AR0234 R0x3270)
#   wiper       : int  0..127 (MCP4018 digital pot; 63 = mid-scale default)
#   flash_delay : int  0..255 (AR0234 R0x3270 bit7:0 DELAY field)
jq '.VHL_CAM.i2c2.ch0.led_flash |= (. // {})
| .VHL_CAM.i2c2.ch0.led_flash |= (if .enable      == null then .enable      = false else . end)
| .VHL_CAM.i2c2.ch0.led_flash |= (if .wiper       == null then .wiper       = 63    else . end)
| .VHL_CAM.i2c2.ch0.led_flash.flash_delay = 128
| .VHL_CAM.i2c2.ch1.led_flash |= (. // {})
| .VHL_CAM.i2c2.ch1.led_flash |= (if .enable      == null then .enable      = false else . end)
| .VHL_CAM.i2c2.ch1.led_flash |= (if .wiper       == null then .wiper       = 63    else . end)
| .VHL_CAM.i2c2.ch1.led_flash.flash_delay = 128
| .VHL_CAM.i2c1.ch2.led_flash |= (. // {})
| .VHL_CAM.i2c1.ch2.led_flash |= (if .enable      == null then .enable      = false else . end)
| .VHL_CAM.i2c1.ch2.led_flash |= (if .wiper       == null then .wiper       = 63    else . end)
| .VHL_CAM.i2c1.ch2.led_flash.flash_delay = 128
| .VHL_CAM.i2c1.ch3.led_flash |= (. // {})
| .VHL_CAM.i2c1.ch3.led_flash |= (if .enable      == null then .enable      = false else . end)
| .VHL_CAM.i2c1.ch3.led_flash |= (if .wiper       == null then .wiper       = 63    else . end)
| .VHL_CAM.i2c1.ch3.led_flash.flash_delay = 128
' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

#gstApp (streamApp deprecated — $1==1 분기 제거됨)
if [[ $1 == 2 ]]; then
    echo "update for gstApp"
    jq '.VHL_CAM.app = "gstApp"' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
fi

model=$(jq -r '.model_name' '/etc/cts/model_info.json')
bd_type="${model:4:1}"
if [[ "$bd_type" == "a" || "$bd_type" == "c" ]]; then
    echo "check SENSORS config (model: $model)"
    # .SENSORS.ACC
    jq '
    .SENSORS |= (. // {})
    | .SENSORS.ACC |= (. // {})
    | .SENSORS.ACC |= (if .use == null then .use = true else . end)
    | .SENSORS.ACC |= (if .samplerate == null then .samplerate = 1000 else . end)
    | .SENSORS.ACC |= (if .scale == null then .scale = 1000 else . end)
    | .SENSORS.ACC |= (if .targetX == null then .targetX = "x" else . end)
    | .SENSORS.ACC |= (if .targetY == null then .targetY = "y" else . end)
    | .SENSORS.ACC |= (if .targetZ == null then .targetZ = "z" else . end)
    | .SENSORS.ACC |= (if .offset == null then .offset = [0,0,0,0,0,0,0,0] else . end)
    | .SENSORS.ACC |= (if .use_filter == null then .use_filter = false else . end)
    | .SENSORS.ACC |= (if .ntaps == null then .ntaps = 101 else . end)
    | .SENSORS.ACC |= (if .cutoff == null then .cutoff = 499 else . end)
    | .SENSORS.ACC |= (if .decimation == null then .decimation = 1 else . end)
    | .SENSORS.ACC |= (if .dataframe == null then .dataframe = "ACC" else . end)
    ' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"

    # .SENSORS.ADC
    jq '
    .SENSORS |= (. // {})
    | .SENSORS.ADC |= (. // {})
    | .SENSORS.ADC |= (if .use == null then .use = true else . end)
    | .SENSORS.ADC |= (if .version == null then .version = "" else . end)
    | .SENSORS.ADC |= (if .fpga_version == null then .fpga_version = "" else . end)
    | .SENSORS.ADC |= (if .deviceid == null then .deviceid = [0,0] else . end)
    | .SENSORS.ADC |= (if .samplerate == null then .samplerate = 20000 else . end)
    | .SENSORS.ADC |= (if .cnv_unit == null then .cnv_unit = [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1] else . end)
    | .SENSORS.ADC |= (if .use_filter == null then .use_filter = false else . end)
    | .SENSORS.ADC |= (if .ntaps == null then .ntaps = 51 else . end)
    | .SENSORS.ADC |= (if .cutoff == null then .cutoff = 499 else . end)
    | .SENSORS.ADC |= (if .decimation == null then .decimation = 20 else . end)
    | .SENSORS.ADC |= (if .dataframe == null then .dataframe = "ADC" else . end)
    ' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
    
    # .SENSORS.ETHERCAT
    jq '
    .SENSORS |= (. // {})
    | .SENSORS.ETHERCAT |= (. // {})
    | .SENSORS.ETHERCAT |= (if .use == null then .use = false else . end)
    | .SENSORS.ETHERCAT |= (if .samplerate == null then .samplerate = 1000 else . end)
    | .SENSORS.ETHERCAT |= (if .version == null then .version = "" else . end)
    | .SENSORS.ETHERCAT |= (if .deviceid == null then .deviceid = ["RX", "TX"] else . end)
    | .SENSORS.ETHERCAT |= (if .direction == null then .direction = "BOTH" else . end)
    | .SENSORS.ETHERCAT |= (if .wcnt == null then .wcnt = 15 else . end)
    | .SENSORS.ETHERCAT |= (if .PDO_len == null then .PDO_len = 518 else . end)
    | .SENSORS.ETHERCAT |= (if .mot1_sp == null then .mot1_sp = ["<i", 125, 129, 0.00732421875] else . end)
    | .SENSORS.ETHERCAT |= (if .mot1_tq == null then .mot1_tq = ["<h", 123, 125, 0.1] else . end)
    | .SENSORS.ETHERCAT |= (if .mot2_sp == null then .mot2_sp = ["<i", 106, 110, 0.00732421875] else . end)
    | .SENSORS.ETHERCAT |= (if .mot2_tq == null then .mot2_tq = ["<h", 104, 106, 0.1] else . end)
    | .SENSORS.ETHERCAT |= (if .mot3_sp == null then .mot3_sp = ["<i", 144, 148, -0.00732421875] else . end)
    | .SENSORS.ETHERCAT |= (if .mot3_tq == null then .mot3_tq = ["<h", 142, 144, -0.1] else . end)
    | .SENSORS.ETHERCAT |= (if .mot4_sp == null then .mot4_sp = ["<i", 163, 167, 0.00732421875] else . end)
    | .SENSORS.ETHERCAT |= (if .mot4_tq == null then .mot4_tq = ["<h", 161, 163, 0.1] else . end)
    | .SENSORS.ETHERCAT |= (if .use_filter == null then .use_filter = false else . end)
    | .SENSORS.ETHERCAT |= (if .ntaps == null then .ntaps = 101 else . end)
    | .SENSORS.ETHERCAT |= (if .cutoff == null then .cutoff = 499 else . end)
    | .SENSORS.ETHERCAT |= (if .decimation == null then .decimation = 1 else . end)
    | .SENSORS.ETHERCAT |= (if .dataframe == null then .dataframe = "ETHERCAT" else . end)
    ' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
fi

if [[ "${model:0:3}" == "cis" ]]; then
    echo "add CIS config (model: $model)"
    jq '
    . |= (if .config_version == null then .config_version = "1.1.1" else . end)
    | . |= (if .manufacturer == null then .manufacturer = "cantops" else . end)
    | . |= (if .daughter_board_type == null then .daughter_board_type = "analog" else . end)
    | . |= (if .mainboard_version == null then .mainboard_version = "" else . end)
    | . |= (if .fw_version == null then .fw_version = "" else . end)
    | . |= (if .device_id == null then .device_id = "000000000000" else . end)
    | . |= (if .testmode == null then .testmode = false else . end)
    | . |= (if .factory == null then .factory = "UNKNOWN" else . end)
    | . |= (if .target == null then .target = "OHT" else . end)
    | . |= (if .maker == null then .maker = "user" else . end)
    | .TARGET_OHT |= (. // {})
    | .TARGET_OHT |= (if .ip == null then .ip = "100.100.100.100" else . end)
    | .TARGET_OHT |= (if .port == null then .port = 7007 else . end)
    | .TARGET_OHT |= (if .id == null then .id = "VD9999" else . end)
    | .TARGET_OHT |= (if .comm_period_ms == null then .comm_period_ms = 500 else . end)
    | .TARGET_OHT |= (if .acc_warn_enable == null then .acc_warn_enable = false else . end)
    | .TARGET_OHT |= (if .acc_warnlevel_mg == null then .acc_warnlevel_mg = 800 else . end)
    | .TARGET_OHT |= (if .angle_warnlevel_deg == null then .angle_warnlevel_deg = 6 else . end)
    | .TARGET_OHT |= (if .angle_warnlevel_duration == null then .angle_warnlevel_duration = 3 else . end)
    | .TARGET_STK |= (. // {})
    | .TARGET_STK |= (if .id == null then .id = "" else . end)
    | .TARGET_STK |= (if .ip == null then .ip = "100.100.100.15" else . end)
    | .TARGET_STK |= (if .port == null then .port = 9001 else . end)
    | .TARGET_STK |= (if .mode == null then .mode = 1 else . end)
    | .TARGET_STK |= (if .main == null then .main = true else . end)
    | .TARGET_STK |= (if .heartBeatPort == null then .heartBeatPort = 9002 else . end)
    | .TARGET_STK |= (if .heartBeatTimeoutMs == null then .heartBeatTimeoutMs = 60000 else . end)
    | .TARGET_STK |= (if .hSizeLimitMB == null then .hSizeLimitMB = 100 else . end)
    | .TARGET_STK |= (if .nSizeLimitMB == null then .nSizeLimitMB = 70 else . end)
    | .SERVER_JINDAN |= (. // {})
    | .SERVER_JINDAN |= (if .interface == null then .interface = "WLAN0" else . end)
    | .SERVER_JINDAN |= (if .ip == null then .ip = "127.0.0.1" else . end)
    | .SERVER_JINDAN |= (if .port == null then .port = 9661 else . end)
    | .SERVER_JINDAN |= (if .id == null then .id = "999" else . end)
    | .CRON_PROPERTIES |= (. // {})
    | .CRON_PROPERTIES.JOBS |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA |= (if .use == null then .use = true else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA |= (if .period == null then .period = 5 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .use == null then .use = true else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .sp1_threshold == null then .sp1_threshold = 1000 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .sp2_threshold == null then .sp2_threshold = 1000 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .sp3_threshold == null then .sp3_threshold = 30 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .sp4_threshold == null then .sp4_threshold = 30 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .thr_elapsed == null then .thr_elapsed = 1 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .min_axis2report == null then .min_axis2report = 2 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .saveAddBehind == null then .saveAddBehind = 120 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .saveAddFront == null then .saveAddFront = 30 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .overwrite == null then .overwrite = true else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ANALYZER_ZONE |= (if .data == null then .data = "adc" else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.FULLTIME_ANALYSIS |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.FULLTIME_ANALYSIS |= (if .use == null then .use = false else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.FULLTIME_ANALYSIS.FEATURES |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.FULLTIME_ANALYSIS.FEATURES |= (if .guide_roller_rpm == null then .guide_roller_rpm = [600] else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.FULLTIME_ANALYSIS.FEATURES |= (if .constvel == null then .constvel = [2803,0.05] else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.FULLTIME_ANALYSIS.FEATURES |= (if .boltloosestatus == null then .boltloosestatus = [] else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.FULLTIME_ANALYSIS.FEATURES |= (if .overSpeedRPM == null then .overSpeedRPM = [2900] else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ADV_ANALYSIS |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ADV_ANALYSIS |= (if .use == null then .use = false else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ADV_ANALYSIS |= (if .saveTimeLength == null then .saveTimeLength = 200 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.ADV_ANALYSIS |= (if .data == null then .data = "eadc" else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_HC |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_HC |= (if .use == null then .use = false else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_HC |= (if .saveTimeLength == null then .saveTimeLength = 616 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_HC |= (if .data == null then .data = "hadc" else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_TR |= (. // {})
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_TR |= (if .use == null then .use = false else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_TR |= (if .saveTimeLength == null then .saveTimeLength = 616 else . end)
    | .CRON_PROPERTIES.JOBS.GENERATE_DATA.SUBJOBS.STK_ANALYSIS_TR |= (if .data == null then .data = "adc" else . end)
    | .CRON_PROPERTIES.JOBS.WIFI_CHECKER |= (. // {})
    | .CRON_PROPERTIES.JOBS.WIFI_CHECKER |= (if .use == null then .use = false else . end)
    | .CRON_PROPERTIES.JOBS.WIFI_CHECKER |= (if .period == null then .period = 60 else . end)
    | .CRON_PROPERTIES |= (if .tmpfs_marginsize == null then .tmpfs_marginsize = 15 else . end)
    | .CRON_PROPERTIES |= (if .mode == null then .mode = "NA" else . end)
    | . |= (if .log_level == null then .log_level = "INFO" else . end)
    | . |= (if .logfile_level == null then .logfile_level = "INFO" else . end)
    | . |= (if .ipc_addr == null then .ipc_addr = "/var/run/sea/sea_data.sock" else . end)
    | . |= (if .sdcard_path == null then .sdcard_path = "/mnt/sd/" else . end)
    | . |= (if .reset_hour == null then .reset_hour = 7 else . end)
    | . |= (if .limit_cpu_temp == null then .limit_cpu_temp = 75 else . end)
    | . |= (if .chunk_store_sec == null then .chunk_store_sec = 60 else . end)
    | . |= (if .reboot_count_1day == null then .reboot_count_1day = 0 else . end)
    | . |= (if .fw_updated == null then .fw_updated = false else . end)
    | . |= (if .force_reboot == null then .force_reboot = false else . end)
    | . |= (if .tmpfs_data == null then .tmpfs_data = "/root/data/" else . end)
    | . |= (if .tmpfs_result == null then .tmpfs_result = "/root/result/" else . end)
    | . |= (if .tmpfs_log == null then .tmpfs_log = "/root/log/" else . end)
    | . |= (if .tmpfs_socket == null then .tmpfs_socket = "/root/socket/" else . end)
    | . |= (if .shared_v == null then .shared_v = "/root/shared_v/" else . end)
    | . |= (if .zmq_ext_pub == null then .zmq_ext_pub = "tcp://127.0.0.1:9991" else . end)
    | . |= (if .zmq_ext_sub == null then .zmq_ext_sub = "tcp://127.0.0.1:9992" else . end)
    | . |= (if .zmq_proxy_pub == null then .zmq_proxy_pub = "ipc:///root/socket/main_publish.sock" else . end)
    | . |= (if .zmq_proxy_sub == null then .zmq_proxy_sub = "ipc:///root/socket/main_subscribe.sock" else . end)
    | . |= (if .zmq_log == null then .zmq_log = "ipc:///root/socket/log.sock" else . end)
    | . |= (if .server == null then .server = "JINDAN" else . end)
    | . |= (if .acc_report_min == null then .acc_report_min = 10 else . end)
    | . |= (if .tq_report_min == null then .tq_report_min = 10 else . end)
    | . |= (if .device_report_min == null then .device_report_min = 1 else . end)
    | .SERVER_DSIOT |= (. // {})
    | .SERVER_DSIOT |= (if .pass == null then .pass = 0 else . end)
    ' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
else
    echo "remove CIS config (model: $model)"
    jq 'del (
    .config_version,
    .manufacturer,
    .daughter_board_type,
    .mainboard_version,
    .fw_version,
    .device_id,
    .testmode,
    .factory,
    .target,
    .maker,
    .TARGET_OHT,
    .TARGET_STK,
    .SERVER_JINDAN,
    .CRON_PROPERTIES,
    .log_level,
    .logfile_level,
    .ipc_addr,
    .sdcard_path,
    .reset_hour,
    .limit_cpu_temp,
    .chunk_store_sec,
    .reboot_count_1day,
    .fw_updated,
    .force_reboot,
    .tmpfs_data,
    .tmpfs_result,
    .tmpfs_log,
    .tmpfs_socket,
    .shared_v,
    .zmq_ext_pub,
    .zmq_ext_sub,
    .zmq_proxy_pub,
    .zmq_proxy_sub,
    .zmq_log,
    .server,
    .acc_report_min,
    .tq_report_min,
    .device_report_min,
    .SERVER_DSIOT
    )' "$FILE_JSON" > temp.json && mv temp.json "$FILE_JSON"
fi

sync
logger -p local0.notice "[$KEY][$tag:$LINENO] complete update $FILE_JSON$"
echo -e "\e[32mcomplete update $FILE_JSON\e[0m"
#echo -e "\e[33mif you want the streamApp, run '/opt/pim/bin/update_json 1' but you want the gstApp, run 'opt/pim/bin/update_json 2'\e[0m"
