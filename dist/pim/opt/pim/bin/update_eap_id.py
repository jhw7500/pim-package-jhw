#!/usr/bin/env python3

import os
import json
import subprocess

# JSON 파일 경로와 Wi-Fi 인터페이스 이름을 지정합니다.
json_file = "/root/shared_v/edgeconf_pim.json"

# 이전에 저장된 Wi-Fi 맥 주소를 가져옵니다.
with open(json_file) as f:
    prev_id = json.load(f)["NETWORK"]["WLAN0"]["identity"]

# 현재 Wi-Fi 맥 주소를 가져옵니다.
current_id = subprocess.check_output("cat /sys/class/net/wlp1s0/address | tr -d ':' | awk '{print $1\"@u.things\"}'", shell=True).decode().strip()

# 이전 Wi-Fi 맥 주소와 현재 Wi-Fi 맥 주소가 다른 경우
if prev_id != current_id:
    print("change eap id {} to {}".format(prev_id, current_id))
    # JSON 파일에서 Wi-Fi 맥 주소를 업데이트합니다.
    with open(json_file, "r") as f:
        data = json.load(f)
    data["NETWORK"]["WLAN0"]["identity"] = current_id
    with open(json_file, "w") as f:
        json.dump(data, f, indent=4)
else:
    print("eap id same: {} : {}".format(prev_id, current_id))
