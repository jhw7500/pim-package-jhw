import getconfval
import os
import dbver
import json
import psutil
import glob
import sys
import subprocess
from datetime import datetime
import syslog

def write_logfile(lvl, msg):
    syslog.openlog(logoption=syslog.LOG_PID,facility=syslog.LOG_LOCAL1)
    if lvl == "ERROR":
        syslog.syslog(syslog.LOG_ERR, "init.py|"+msg)
    elif lvl == "INFO":
        syslog.syslog(syslog.LOG_INFO, "init.py|"+msg)
    else:
        syslog.syslog(syslog.LOG_DEBUG, "init.py|"+msg)

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
    global_conf_path = ""
    try:
        with open("/tmp/global_edgeconf_path", "r") as f :
            global_conf_path = f.readline()
    except:
        return ""
    return global_conf_path

def copy_backup_conf(conf_path):
    conf = {}
    try:
        with open(conf_path) as json_file:
            conf = json.load(json_file)
    except:
        return False
    
    json_str = json.dumps(conf, indent=3)
    backup_flag = True
    backup_path = os.path.dirname(conf_path) + "/backup_" + os.path.basename(conf_path)
    backup_conf = {}

    backup_pattern = os.path.dirname(conf_path)+"/backup_edgeconf_*.json"
    backup_list = glob.glob(backup_pattern)
    for v in backup_list:
        if v != backup_path :
            subprocess.call(['rm',v])
    try:
        with open(backup_path) as backup_json_file:
            backup_conf = json.load(backup_json_file)
            backup_json_str = json.dumps(backup_conf, indent=3)
            if json_str == backup_json_str:
                backup_flag = False
    except:
        backup_flag = True

    if backup_flag == True:
        print("backup json data is different. backup save file.")
        with open(backup_path, 'w') as f:
            json.dump(conf, f, indent=3)
    else:
        print("backup json data is same.")

def verify_conf_key(conf_path):
    try:
        with open(conf_path) as json_file:
            edgeconf = json.load(json_file)
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
    try:
        fwver = dbver.get_daughter_board_version()
    except:
        fwver = "0.0.0"
    
    sysinfo = {
        "mainboard_version":"",
        "daughterboard_version":"",
    }
    edgeconf = {
    }

    edgeconf_file_error = False

    try:
        with open(conf_path) as json_file:
            edgeconf = json.load(json_file)
    except:
        return -1
    try:
        with open('/etc/cts/sysinfo.json') as f:
            sysinfo = json.load(f)
    except:
        print("/etc/cts/sysinfo.json file not found")

    prev_json_str = json.dumps(edgeconf, indent=3)

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
            auto_identity=True
            if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "auto_identity") == True:
                auto_identity=edgeconf["NETWORK"]["WLAN0"]["auto_identity"]
            if auto_identity == True:
                id_suffix = ""
                if is_json_key_present(edgeconf["NETWORK"]["WLAN0"], "identity") == True:
                    s = edgeconf["NETWORK"]["WLAN0"]["identity"]
                    id_suffix = s[12:]
                edgeconf["NETWORK"]["WLAN0"]["identity"] = devid + id_suffix
    
    if getconfval.get_json_val("daughterboard_type") != "none":
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

    new_json_str = json.dumps(edgeconf, indent=3)
    if edgeconf_file_error == True or prev_json_str != new_json_str :
        print("edgeconf json data is different. save file.")
        with open(conf_path, 'w') as f:
            json_string = json.dump(edgeconf, f, indent=3)
    else :
        print("edgeconf json data is same. skip save file.")
    
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
