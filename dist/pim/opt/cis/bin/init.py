import getconfval
import os
import dbver
import json
import psutil
import glob
import sys
import subprocess
from datetime import datetime
from collections import OrderedDict
import syslog

def write_logfile(lvl, msg):
    syslog.openlog(logoption=syslog.LOG_PID,facility=syslog.LOG_LOCAL1)
    if lvl == "ERROR":
        syslog.syslog(syslog.LOG_ERR, "init.py|"+msg)
    elif lvl == "INFO":
        syslog.syslog(syslog.LOG_INFO, "init.py|"+msg)
    else:
        syslog.syslog(syslog.LOG_DEBUG, "init.py|"+msg)

def update_json_file(path, new_data):
    """
    path     : json 파일 경로
    new_data : dict 또는 OrderedDict

    반환값:
        True  -> 파일 저장됨
        False -> 변경 없음
    """

    try:
        with open(path, 'r', encoding='utf-8') as f:
            current_text = f.read()
    except Exception:
        current_text = ""

    # OrderedDict 유지
    new_text = json.dumps(
        new_data,
        indent=3,
        ensure_ascii=False
    ) + "\n"

    # 스타일 또는 내용이 다르면 저장
    if current_text != new_text:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_text)
        return True

    return False

def log_jsonconferr(err, path):
    if err == -1:
        print("json load error!!")
        write_logfile("ERROR", "not find json format ("+ os.path.basename(path) + ")")
    elif err == -2:
        print("json key error!!")
        write_logfile("ERROR", "not find json key ("+ os.path.basename(path) + ")")
    else:
        print("undefined error!!")
        write_logfile("ERROR", "undefined error("+ str(err) + ")")

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

def rename_error_conf(conf_path):
    if os.path.isfile(conf_path):
        error_path = os.path.dirname(conf_path) + "/error_" + os.path.basename(conf_path)
        os.renames(conf_path,error_path)

def set_global_conf(conf_path):
    with open("/tmp/global_edgeconf_path", "w") as f :
        f.write(conf_path)
        f.close()

def get_global_conf():
    json_path = search_conf(r"/root/shared_v/edgeconf_*.json")
    if json_path == False :
        json_path = search_conf(r"/root/shared_v/backup_edgeconf_*.json")
        if json_path == False :
            json_path = "/etc/defaultconf.json"
    return json_path

def copy_backup_conf(conf_path):
    conf = {}
    try:
        with open(conf_path) as json_file:
            conf = json.load(json_file, object_pairs_hook=OrderedDict)
    except:
        return False
    
    backup_flag = True
    backup_path = os.path.dirname(conf_path) + "/backup_" + os.path.basename(conf_path)

    backup_pattern = os.path.dirname(conf_path)+"/backup_edgeconf_*.json"
    backup_list = glob.glob(backup_pattern)
    for v in backup_list:
        if v != backup_path :
            subprocess.call(['rm',v])

    if update_json_file(backup_path, conf) == True :
        print("backup json data is different. backup save file.")
    else :
        print("backup json data is same.")

def verify_conf_key(conf_path):
    try:
        with open(conf_path) as json_file:
            edgeconf = json.load(json_file, object_pairs_hook=OrderedDict)
    except:
        return -1

    if getconfval.get_json_val("iot_app") == "sea_app":
        if is_json_key_present(edgeconf, "manufacturer") == False:
            return -2
        if is_json_key_present(edgeconf, "daughter_board_type") == False:
            return -2
        if is_json_key_present(edgeconf, "mainboard_version") == False:
            return -2
        if is_json_key_present(edgeconf, "fw_version") == False:
            return -2
        if is_json_key_present(edgeconf, "device_id") == False:
            return -2
    
    if is_json_key_present(edgeconf, "NETWORK") == False:
        return -2
    else:
        if is_json_key_present(edgeconf["NETWORK"], "WLAN0") == False:
            return -2
        else:
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "security") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "ssid") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "identity") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "passwd") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "method") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "address") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "netmask") == False:
                return -2
        if is_json_key_present(edgeconf["NETWORK"], "ETH0") == False:
            return -2
        else:
            if is_json_key_present(edgeconf["NETWORK"]["ETH0"], "method") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["ETH0"], "address") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["ETH0"], "netmask") == False:
                return -2
        if is_json_key_present(edgeconf["NETWORK"], "ETH1") == False:
            return -2
        else:
            if is_json_key_present(edgeconf["NETWORK"]["ETH1"], "method") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["ETH1"], "address") == False:
                return -2
            if is_json_key_present(edgeconf["NETWORK"]["ETH1"], "netmask") == False:
                return -2
    
    if getconfval.get_json_val("daughterboard_type") != "none":
        if is_json_key_present(edgeconf, "SENSORS") == False:
            return -2
        else:
            if is_json_key_present(edgeconf["SENSORS"], "ACC") == False:
                return -2
            else:
                if is_json_key_present(edgeconf["SENSORS"]["ACC"], "use") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ACC"], "samplerate") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ACC"], "scale") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ACC"], "targetX") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ACC"], "targetY") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ACC"], "targetZ") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ACC"], "offset") == False:
                    return -2
            if is_json_key_present(edgeconf["SENSORS"], "ADC") == False:
                return -2
            else:
                if is_json_key_present(edgeconf["SENSORS"]["ADC"], "use") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ADC"], "version") == False:
                    return -2
                #if is_json_key_present(edgeconf["SENSORS"]["ADC"], "fpga_version") == False:
                #    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ADC"], "samplerate") == False:
                    return -2
                if is_json_key_present(edgeconf["SENSORS"]["ADC"], "cnv_unit") == False:
                    return -2

    return 0

def init_conf(conf_path):
    sysinfo = {
        "mainboard_version":"",
        "daughterboard_version":"",
    }
    edgeconf = {
    }

    edgeconf_file_error = False

    try:
        with open(conf_path) as json_file:
            edgeconf = json.load(json_file, object_pairs_hook=OrderedDict)
    except:
        return -1
    try:
        with open('/etc/cts/sysinfo.json') as f:
            sysinfo = json.load(f, object_pairs_hook=OrderedDict)
    except:
        print("/etc/cts/sysinfo.json file not found")

    #prev_json_str = json.dumps(edgeconf, indent=3)

    if is_json_key_present(edgeconf, "manufacturer") == True:
        edgeconf["manufacturer"] = "cantops"
    
    if is_json_key_present(edgeconf, "daughter_board_type") == True:
        edgeconf["daughter_board_type"] = "analog"  ##ethercat 셋팅시, sea_app 이상동작.
    
    if is_json_key_present(edgeconf, "mainboard_version") == True:
        edgeconf["mainboard_version"] = sysinfo["mainboard_version"]

    if is_json_key_present(edgeconf, "fw_version") == True:
        if getconfval.get_json_val("mainboard_type") == "plus":
            appver = os.popen("dpkg -l pim-mp | grep 'pim-mp' | awk '{print $3}'").readline().rstrip('\n')
            edgeconf["fw_version"] = appver
        else:
            appver = os.popen("dpkg -l cis | grep 'cis' | awk '{print $3}'").readline().rstrip('\n')
            edgeconf["fw_version"] = appver            

    devid="000000000000"
    try:
        dev_wlan = getconfval.get_json_val("dev_wlan")
        nics = psutil.net_if_addrs()[dev_wlan]
        for interface in nics:
            if interface.family == 17:
                devid = interface.address
                devid = devid.replace(":","")

    except KeyError as e:
        print("Get mac address of", e, ": error")
    
    if is_json_key_present(edgeconf, "device_id") == True:
        edgeconf["device_id"] = devid
    
    identity = devid + "@u.things"
    if is_json_key_present(edgeconf, "NETWORK") == False:
        return -2
    else:
        if is_json_key_present(edgeconf["NETWORK"], "WLAN0") == False:
            return -2
        else:
            security = edgeconf["NETWORK"]["WLAN0"].get("security","PSK")
            ssid = edgeconf["NETWORK"]["WLAN0"].get("ssid","")
            if security == "EAP" and ssid == "ureadythings" :
                edgeconf["NETWORK"]["WLAN0"]["identity"] = identity
                edgeconf["NETWORK"]["WLAN0"]["passwd"] = "qwe124@@"
    
    if getconfval.get_json_val("daughterboard_type") != "none":
        try:
            fwver = dbver.get_daughter_board_version()
        except:
            fwver = "0.0.0"
        
        if is_json_key_present(edgeconf, "SENSORS") == False:
            return -2
        else:
            if is_json_key_present(edgeconf["SENSORS"], "ACC") == False:
                return -2
            else:
                edgeconf["SENSORS"]["ACC"]["use"] = True
            if is_json_key_present(edgeconf["SENSORS"], "ADC") == False:
                return -2
            else:
                edgeconf["SENSORS"]["ADC"]["use"] = True
            if is_json_key_present(edgeconf["SENSORS"], "ETHERCAT") == True:
                edgeconf["SENSORS"]["ETHERCAT"]["use"] = False

            if getconfval.get_json_val("daughterboard_type") == "ethercat":
                edgeconf["SENSORS"]["ADC"]["samplerate"] = 1000
                edgeconf["SENSORS"]["ADC"]["decimation"] = 1

        edgeconf["SENSORS"]["ADC"]["version"] = sysinfo["daughterboard_version"]
        edgeconf["SENSORS"]["ADC"]["fpga_version"] = fwver

    cam_max_ch=getconfval.get_json_val("cam_max_channel")
    if cam_max_ch < 4:
        if is_json_key_present(edgeconf, "VHL_CAM") == True:
            if is_json_key_present(edgeconf["VHL_CAM"], "i2c1") == True:
                if is_json_key_present(edgeconf["VHL_CAM"]["i2c1"],"ch3") == True:
                    edgeconf["VHL_CAM"]["i2c1"]["ch3"]["enable"] = False
    if cam_max_ch < 3:
        if is_json_key_present(edgeconf, "VHL_CAM") == True:
            if is_json_key_present(edgeconf["VHL_CAM"], "i2c1") == True:
                if is_json_key_present(edgeconf["VHL_CAM"]["i2c1"],"ch2") == True:
                    edgeconf["VHL_CAM"]["i2c1"]["ch2"]["enable"] = False
    if cam_max_ch < 2:
        if is_json_key_present(edgeconf, "VHL_CAM") == True:
            if is_json_key_present(edgeconf["VHL_CAM"], "i2c2") == True:
                if is_json_key_present(edgeconf["VHL_CAM"]["i2c2"],"ch1") == True:
                    edgeconf["VHL_CAM"]["i2c2"]["ch1"]["enable"] = False
    if cam_max_ch < 1:
        if is_json_key_present(edgeconf, "VHL_CAM") == True:
            if is_json_key_present(edgeconf["VHL_CAM"], "i2c2") == True:
                if is_json_key_present(edgeconf["VHL_CAM"]["i2c2"],"ch0") == True:
                    edgeconf["VHL_CAM"]["i2c2"]["ch0"]["enable"] = False

    if update_json_file(conf_path, edgeconf) == True :
        print(f"{conf_path} is different. save file.")
    else :
        print(f"{conf_path} data is same.")

    return 0

#################################################
if len(sys.argv) == 2 and sys.argv[1] == "power_on" :
    init_conf("/etc/defaultconf.json")

json_path = search_conf(r"/root/shared_v/edgeconf_*.json")
if json_path != False :
    ret = verify_conf_key(json_path)
    if ret < 0:
        ### error_ ####
        log_jsonconferr(ret, json_path)
        rename_error_conf(json_path)
        json_path = False
    else:
        ret = init_conf(json_path)
        if ret < 0:
            ### error_ ####
            log_jsonconferr(ret, json_path)
            rename_error_conf(json_path)
            json_path = False
        else:
            ### json OK ###
            copy_backup_conf(json_path)
            set_global_conf(json_path)
            sys.exit()

json_path = search_conf(r"/root/shared_v/backup_edgeconf_*.json")
if json_path != False :
    if verify_conf_key(json_path) == 0 and init_conf(json_path) == 0:
        ### try backup_  OK ###
        set_global_conf(json_path)
        sys.exit()

json_path = "/etc/defaultconf.json"
set_global_conf(json_path)
