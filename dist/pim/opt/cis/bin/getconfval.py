import json
import subprocess
import os.path
import sys
import glob

def is_json_key_present(json, key):
    try:
        a = json[key]
    except KeyError:
        return False
    return True

def search_conf(pattern):
    conf_file = ""
    conf_list = glob.glob(pattern)
    if len(conf_list) == 1:
        return conf_list[0]
    else :
        return False

def get_global_conf():
    json_path = search_conf(r"/root/shared_v/edgeconf_*.json")
    if json_path == False :
        json_path = search_conf(r"/root/shared_v/backup_edgeconf_*.json")
        if json_path == False :
            json_path = "/etc/defaultconf.json"
    return json_path

def get_json_val(json_key):
    json_defval = ""
    if json_key == "PING_IP" :
        json_path = get_global_conf()
        json_defval = "127.0.0.1"
    elif json_key == "NETWORK_USED" :
        json_path = get_global_conf()
        json_defval = "WLAN0"
    elif json_key == "WIFI_CHMASK_EN" :
        json_path = get_global_conf()
        json_defval = False
    elif json_key == "WIFI_BGSCAN_PARAM" :
        json_path = get_global_conf()
        json_defval = "simple:3:-70:300"
    elif json_key == "WIFI_AUTOSCAN_PARAM" :
        json_path = get_global_conf()
        json_defval = "periodic:30"
    elif json_key == "mainboard_type" :
        json_path = "/etc/cts/model_info.json"
        json_defval = "plus"
    elif json_key == "daughterboard_type" :
        json_path = "/etc/cts/model_info.json"
        json_defval = "none"
    elif json_key == "iot_app" :
        json_path = "/etc/cts/model_info.json"
        json_defval = "none"
    elif json_key == "cam_max_channel" :
        json_path = "/etc/cts/model_info.json"
        json_defval = 0
    elif json_key == "dev_uart" :
        json_path = "/etc/cts/model_info.json"
        json_defval = "/dev/ttymxc3"
    elif json_key == "dev_wlan" :
        json_path = "/etc/cts/model_info.json"
        json_defval = "wlp1s0"
    elif json_key == "dev_sd" :
        json_path = "/etc/cts/model_info.json"
        json_defval = "mmcblk0"
    elif json_key == "model_name" :
        json_path = "/etc/cts/model_info.json"
        json_defval = "pim-x4"
    elif json_key == "hostname" :
        json_path = "/etc/cts/sysinfo.json"
        json_defval = "noname"
    elif json_key == "iot_longrun_en" :
        json_path = "/etc/cts/model_override.json"
        json_defval = False

    try:
        with open(json_path, "r") as f :
            jsonconf = json.load(f)
    except:
        return json_defval

    if json_key == "PING_IP" :
        try:
            if is_json_key_present(jsonconf["SERVER_JINDAN"],"ip") == True:
                return jsonconf["SERVER_JINDAN"]["ip"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "NETWORK_USED" :
        try:
            if is_json_key_present(jsonconf["NETWORK"],"used") == True:
                return jsonconf["NETWORK"]["used"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "WIFI_CHMASK_EN" :
        try:
            if is_json_key_present(jsonconf["NETWORK"]["WLAN0"],"chmask") == True:
                return jsonconf["NETWORK"]["WLAN0"]["chmask"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "WIFI_BGSCAN_PARAM" :
        try:
            if is_json_key_present(jsonconf["NETWORK"]["WLAN0"],"bgscan") == True:
                return jsonconf["NETWORK"]["WLAN0"]["bgscan"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "WIFI_AUTOSCAN_PARAM" :
        try:
            if is_json_key_present(jsonconf["NETWORK"]["WLAN0"],"autoscan") == True:
                return jsonconf["NETWORK"]["WLAN0"]["autoscan"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "mainboard_type" :
        try:
            if is_json_key_present(jsonconf,"mainboard_type") == True:
                return jsonconf["mainboard_type"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "daughterboard_type" :
        try:
            if is_json_key_present(jsonconf,"daughterboard_type") == True:
                return jsonconf["daughterboard_type"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "iot_app" :
        try:
            if is_json_key_present(jsonconf,"iot_app") == True:
                return jsonconf["iot_app"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "cam_max_channel" :
        try:
            if is_json_key_present(jsonconf,"cam_max_channel") == True:
                return jsonconf["cam_max_channel"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "dev_uart" :
        try:
            if is_json_key_present(jsonconf["dev"],"uart") == True:
                return jsonconf["dev"]["uart"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "dev_wlan" :
        try:
            if is_json_key_present(jsonconf["dev"],"wlan") == True:
                return jsonconf["dev"]["wlan"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "dev_sd" :
        try:
            if is_json_key_present(jsonconf["dev"],"sd") == True:
                return jsonconf["dev"]["sd"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "model_name" :
        try:
            if is_json_key_present(jsonconf,"model_name") == True:
                return jsonconf["model_name"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "hostname" :
        try:
            if is_json_key_present(jsonconf,"hostname") == True:
                return jsonconf["hostname"]
            else :
                return json_defval
        except:
            return json_defval
    elif json_key == "iot_longrun_en" :
        try:
            if is_json_key_present(jsonconf["iot"],"longrun_en") == True:
                return jsonconf["iot"]["longrun_en"]
            else :
                return json_defval
        except:
            return json_defval

###########################################
### arg[1] : json_path
### arg[2] : key_name

if __name__ == "__main__":
    json_key = ""
    if len(sys.argv) == 2 :
        json_key = sys.argv[1]
        print(get_json_val(json_key))
    else :
        sys.exit()
