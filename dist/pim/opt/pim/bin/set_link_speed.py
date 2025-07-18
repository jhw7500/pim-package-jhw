import json
import subprocess
import os
import glob

# edgeconf_*.json 중 첫 번째 파일 자동 선택
json_files = glob.glob("/root/shared_v/edgeconf_*.json")
if not json_files:
    exit(1)

json_path = json_files[0]

def set_ethtool(interface: str, speed_value: str):
    speed_value = speed_value.lower()
    if speed_value not in ("100", "1000", "auto"):
        speed_value = "auto"

    if speed_value == "auto":
        cmd = ["ethtool", "-s", interface, "autoneg", "on"]
    else:
        cmd = ["ethtool", "-s", interface, "speed", speed_value, "duplex", "full", "autoneg", "off"]

    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError:
        pass

# JSON 열기
try:
    with open(json_path, "r") as f:
        config = json.load(f)
except FileNotFoundError:
    exit(1)

# ETH0, ETH1 처리
for iface in ["ETH0", "ETH1"]:
    iface_conf = config["NETWORK"].get(iface)
    if iface_conf:
        linkspeed = iface_conf.get("linkspeed", "auto")  # 기본값: auto
        interface_name = iface.lower()
        set_ethtool(interface_name, linkspeed)
