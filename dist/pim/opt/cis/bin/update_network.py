import sys
import json
import subprocess
import ipaddress
import os.path
from filecmp import cmp
import glob
import time
import yaml
import syslog

WLAN_DEV="wlp1s0"

def log_error(message):
    syslog.syslog(syslog.LOG_ERR, message)

def log_notice(message):
    syslog.syslog(syslog.LOG_NOTICE, message)

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

def is_json_key_present(json, key):
    try:
        buf = json[key]
    except KeyError:
        return False
    
    if buf == "":
        return False

    return True

def check_yaml_file(file_path):
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            yaml.safe_load(f)

        return True

    except yaml.YAMLError as e:
        return False

    except OSError as e:
        return False

def calcu_set_static_ip(ip_str, sub_str):
    if not isinstance(ip_str, str) or not isinstance(sub_str, str):
        return ''

    try:
        ipaddress.IPv4Address(ip_str)
    except ipaddress.AddressValueError:
        return ''

    try:
        ipadd = ipaddress.ip_interface(ip_str + '/' + sub_str)
    except ValueError:
        firstNum = int(ip_str.split(".")[0])
        if firstNum < 128 :
            ipadd = ipaddress.ip_interface(ip_str + '/8')
        elif firstNum < 192 :
            ipadd = ipaddress.ip_interface(ip_str + '/16')
        else : 
            ipadd = ipaddress.ip_interface(ip_str + '/24')
    
    return str(ipadd)


def validate_static_network_addresses(edgeconf):
    network = edgeconf.get('NETWORK', {})
    for interface in ('ETH0', 'ETH1', 'WLAN0'):
        interface_config = network.get(interface, {})
        if interface_config.get('method') != 'static':
            continue

        address = calcu_set_static_ip(
            interface_config.get('address'), interface_config.get('netmask')
        )
        if address == '':
            log_error(f"invalid {interface.lower()} static address")
            return False

    return True


def _shell(cmd_list):
    if not isinstance(cmd_list, (list, tuple)):
        return False

    if not all(isinstance(arg, str) for arg in cmd_list):
        return False

    try:
        subprocess.run(
            cmd_list,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

def _shell_output(cmd_list):
    if not isinstance(cmd_list, (list, tuple)):
        return None

    if not all(isinstance(arg, str) for arg in cmd_list):
        return None

    try:
        result = subprocess.run(
            cmd_list,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

def _wpa_cli_cmd(*args):
    return [
        "wpa_cli",
        "-i", WLAN_DEV,
        *args
    ]

def set_wpa_bgscan(bgscan_parm):
    bgscan_value = f'"{bgscan_parm}"'
    set_cmd = _wpa_cli_cmd("set_network", "0", "bgscan", bgscan_value)

    for i in range(5):
        if _shell(set_cmd) == True:
            current_bgscan = _shell_output(_wpa_cli_cmd("get_network", "0", "bgscan"))
            if current_bgscan != "FAIL":
                log_notice(f"current_bgscan: {current_bgscan}")
                return current_bgscan is not None
        time.sleep(1)
        log_notice(f"set bgscan FAIL, retry {i}")

    return False

def set_wpa_reassociate():
    set_cmd = _wpa_cli_cmd("reassociate")

    for i in range(5):
        if _shell(set_cmd) == True:
            log_notice(f"set reassociate SUC")
            return True
        time.sleep(1)
        log_notice(f"set reassociate FAIL, retry {i}")

    return False

def set_wpa_suppl():
    _shell(["/usr/bin/killall","wpa_supplicant"])
    time.sleep(1)
    for var in range(1,5):
        if _shell(["/sbin/wpa_supplicant", "-c", "/etc/wpa_supplicant/wpa_supplicant.conf", "-i", WLAN_DEV, "-D", "nl80211,wext", "-B"]):
            return True
        time.sleep(1)
    return False

def is_active_wpa_supplicant():
    return _shell(["systemctl", "is-active", "wpa_supplicant"])
    #return _shell(["systemctl", "is-active", "netplan-wpa-wlan0.service"])

#################################################

def update_network(force=False):
    
    if force :
        log_notice(f"update_network --force")
    else :
        log_notice(f"update_network")

    json_path = get_global_conf()
    #print("json_path : "+json_path)

    with open(json_path, "r") as f :
        edgeconf = json.load(f)

    assert edgeconf['NETWORK']
    assert edgeconf['NETWORK']['ETH0']
    assert edgeconf['NETWORK']['ETH1']
    assert edgeconf['NETWORK']['WLAN0']

    if validate_static_network_addresses(edgeconf) == False:
        return False

    change_netplan_flag = False
    sel_interface = None
    if 'used' in edgeconf['NETWORK'] and \
       edgeconf['NETWORK'].get('used',None) in {'ETH0', 'ETH1', 'WLAN0'} :
       sel_interface = edgeconf['NETWORK']['used']

    with open("/tmp/eth0.yaml", "w") as f :
        f.write("network:\n  version: 2\n  ethernets:\n    eth0:\n      renderer: networkd\n")
        if edgeconf['NETWORK']['ETH0']['method'] == 'static' :
            f.write("      addresses: [")
            f.write(calcu_set_static_ip(edgeconf['NETWORK']['ETH0']['address'], edgeconf['NETWORK']['ETH0']['netmask']))
            f.write("]\n")
            
            if is_json_key_present(edgeconf['NETWORK']['ETH0'], 'gateway') == True and edgeconf['NETWORK']['used'] == 'ETH0' :
                f.write("      gateway4: ")
                f.write(edgeconf['NETWORK']['ETH0']['gateway'])
                f.write("\n")
            
            if is_json_key_present(edgeconf['NETWORK']['ETH0'], 'dns-nameservers') == True :
                f.write("      nameservers:\n        addresses: [")
                f.write(edgeconf['NETWORK']['ETH0']['dns-nameservers'])
                f.write("]\n")
            f.write("      dhcp4: no\n")
        else :
            f.write("      dhcp4: yes\n")
            #f.write("      link-local: [ipv4]\n")

        if sel_interface is not None and sel_interface != 'ETH0' :
            f.write("      dhcp4-overrides:\n")
            f.write("         use-routes: false\n")
        
        f.close()

    file_conn_eth0 = '/etc/netplan/eth0.yaml'
    if check_yaml_file('/tmp/eth0.yaml') :
        if os.path.isfile(file_conn_eth0) == False or cmp('/tmp/eth0.yaml',file_conn_eth0) == False :
            change_netplan_flag = True
            _shell(['cp','/tmp/eth0.yaml',file_conn_eth0])
    else :
        log_error(f"invalid eth0.yaml")

    _shell(['rm','/tmp/eth0.yaml'])

    with open("/tmp/eth1.yaml", "w") as f :
        f.write("network:\n  version: 2\n  ethernets:\n    eth1:\n      renderer: networkd\n")
        if edgeconf['NETWORK']['ETH1']['method'] == 'static' :
            f.write("      addresses: [")
            f.write(calcu_set_static_ip(edgeconf['NETWORK']['ETH1']['address'], edgeconf['NETWORK']['ETH1']['netmask']))
            f.write("]\n")
            
            if is_json_key_present(edgeconf['NETWORK']['ETH1'], 'gateway') == True and edgeconf['NETWORK']['used'] == 'ETH1' :
                f.write("      gateway4: ")
                f.write(edgeconf['NETWORK']['ETH1']['gateway'])
                f.write("\n")
            
            if is_json_key_present(edgeconf['NETWORK']['ETH1'], 'dns-nameservers') == True :
                f.write("      nameservers:\n        addresses: [")
                f.write(edgeconf['NETWORK']['ETH1']['dns-nameservers'])
                f.write("]\n")
            f.write("      dhcp4: no\n")
        else :
            f.write("      dhcp4: yes\n")
            #f.write("      link-local: [ipv4]\n")
        
        if sel_interface is not None and sel_interface != 'ETH1' :
            f.write("      dhcp4-overrides:\n")
            f.write("         use-routes: false\n")

        f.close()

    file_conn_eth1 = '/etc/netplan/eth1.yaml'
    if check_yaml_file('/tmp/eth1.yaml') :
        if os.path.isfile(file_conn_eth1) == False or cmp('/tmp/eth1.yaml',file_conn_eth1) == False :
            change_netplan_flag = True
            _shell(['cp','/tmp/eth1.yaml',file_conn_eth1])
    else :
        log_error(f"invalid eth1.yaml")

    _shell(['rm','/tmp/eth1.yaml'])


    temp_conn_wlan0="/tmp/"+WLAN_DEV+".yaml"

    wlan_chmask_use = False
    try:
        if edgeconf['NETWORK']['WLAN0']['chmask'] == True :
            if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'mask_freq') == True :
                if isinstance(edgeconf['NETWORK']['WLAN0']['mask_freq'], list):
                    if len(edgeconf['NETWORK']['WLAN0']['mask_freq']) > 0 :
                        wlan_chmask_use = True
    except:
    	wlan_chmask_use = False

    with open(temp_conn_wlan0, "w") as f :
        f.write("network:\n  version: 2\n  wifis:\n    "+WLAN_DEV+":\n      renderer: networkd\n")
        if edgeconf['NETWORK']['WLAN0']['security'] == 'PSK' :
            f.write("      access-points:\n")
            f.write("        ")
            f.write(edgeconf['NETWORK']['WLAN0']['ssid'])
            f.write(":\n")
            f.write("          password: ")
            f.write(edgeconf['NETWORK']['WLAN0']['passwd'])
            f.write("\n")
        elif edgeconf['NETWORK']['WLAN0']['security'] == 'EAP' :
            f.write("      optional: true\n")
            f.write("      access-points:\n")
            f.write("        ")
            f.write(edgeconf['NETWORK']['WLAN0']['ssid'])
            f.write(":\n")
            f.write("          auth:\n")
            f.write("            key-management: eap\n")
            f.write("            password: ")
            f.write(edgeconf['NETWORK']['WLAN0']['passwd'])
            f.write("\n")
            f.write("            method: peap\n")
            f.write("            identity: ")
            f.write(edgeconf['NETWORK']['WLAN0']['identity'])
            f.write("\n")
        elif edgeconf['NETWORK']['WLAN0']['security'] == 'OPEN' :
            f.write("      access-points:\n")
            f.write("        ")
            f.write(edgeconf['NETWORK']['WLAN0']['ssid'])
            f.write(": {}\n")
        
        if edgeconf['NETWORK']['WLAN0']['method'] == 'static' :
            f.write("      addresses: [")
            f.write(calcu_set_static_ip(edgeconf['NETWORK']['WLAN0']['address'], edgeconf['NETWORK']['WLAN0']['netmask']))
            f.write("]\n")
            
            if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'gateway') == True and edgeconf['NETWORK']['used'] == 'WLAN0':
                f.write("      gateway4: ")
                f.write(edgeconf['NETWORK']['WLAN0']['gateway'])
                f.write("\n")
            
            if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'dns-nameservers') == True :
                f.write("      nameservers:\n        addresses: [")
                f.write(edgeconf['NETWORK']['WLAN0']['dns-nameservers'])
                f.write("]\n")
            f.write("      dhcp4: no\n")
        else :
            f.write("      dhcp4: yes\n")
            f.write("      dhcp-identifier: mac\n")

        if sel_interface is not None and sel_interface != 'WLAN0' :
            f.write("      dhcp4-overrides:\n")
            f.write("         use-routes: false\n")

        f.close()


    wpa_bgscan_parm = 'simple:3:-65:30'
    if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'bgscan') == True :
        wpa_bgscan_parm = edgeconf['NETWORK']['WLAN0']['bgscan']

    wpa_autoscan_parm = 'periodic:30'
    if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'autoscan') == True :
        wpa_autoscan_parm = edgeconf['NETWORK']['WLAN0']['autoscan']

    change_wpa_supplicant_flag = False
    file_wpa_supplicant = '/etc/wpa_supplicant/wpa_supplicant.conf'
    if wlan_chmask_use == True :
        with open("/tmp/wpa_supplicant.conf", "w") as f :
            f.write("ctrl_interface=/var/run/wpa_supplicant\n")
            f.write("autoscan=\"")
            f.write(wpa_autoscan_parm)
            f.write("\"\n")
            f.write("freq_list=")
            freq_list=edgeconf['NETWORK']['WLAN0']['mask_freq']
            output_str= ' '.join(str(item) for item in freq_list)
            f.write(output_str)
            f.write("\n")
            f.write("\n")
            f.write("network={")
            f.write("\n")
            f.write("    ssid=\"")
            f.write(edgeconf['NETWORK']['WLAN0']['ssid'])
            f.write("\"\n")
            if edgeconf['NETWORK']['WLAN0']['security'] == 'PSK' :
                f.write("    psk=\"")
                f.write(edgeconf['NETWORK']['WLAN0']['passwd'])
                f.write("\"\n")
                f.write("    key_mgmt=WPA-PSK\n")    
            elif edgeconf['NETWORK']['WLAN0']['security'] == 'EAP' :
                f.write("    key_mgmt=WPA-EAP\n    eap=PEAP\n")    
                f.write("    identity=\"")
                f.write(edgeconf['NETWORK']['WLAN0']['identity'])
                f.write("\"\n    password=\"")
                f.write(edgeconf['NETWORK']['WLAN0']['passwd'])
                f.write("\"\n")
            elif edgeconf['NETWORK']['WLAN0']['security'] == 'OPEN' :
                f.write("    key_mgmt=NONE\n")    
            f.write("    scan_freq=")
            f.write(output_str)
            f.write("\n")
            f.write("    bgscan=\"")
            f.write(wpa_bgscan_parm)
            f.write("\"\n")
            f.write("}\n")
            f.close()
        
        if os.path.isfile(file_wpa_supplicant) == False or cmp('/tmp/wpa_supplicant.conf',file_wpa_supplicant) == False :
            _shell(['cp','/tmp/wpa_supplicant.conf',file_wpa_supplicant])
            _shell(['chmod','644',file_wpa_supplicant])
            change_wpa_supplicant_flag = True
        _shell(['rm','/tmp/wpa_supplicant.conf'])   
    else :
        if os.path.isfile(file_wpa_supplicant):
            _shell(['rm',file_wpa_supplicant])
            change_wpa_supplicant_flag = True

    if WLAN_DEV == "wlan0" :
        _shell(['rm','/etc/netplan/wlp1s0.yaml'])
    elif WLAN_DEV == "wlp1s0" :
        _shell(['rm','/etc/netplan/wlan0.yaml'])

    file_conn_wlan0 = '/etc/netplan/'+WLAN_DEV+'.yaml'
    if check_yaml_file(temp_conn_wlan0) :
        if os.path.isfile(file_conn_wlan0) == False or cmp(temp_conn_wlan0,file_conn_wlan0) == False :
            change_netplan_flag = True
            _shell(['cp',temp_conn_wlan0,file_conn_wlan0])
    else :
        log_error(f"invalid {WLAN_DEV}.yaml")

    _shell(['rm',temp_conn_wlan0])

    if wlan_chmask_use == True :
        if is_active_wpa_supplicant() == True or change_wpa_supplicant_flag == True or force == True :
            _shell(['/usr/bin/killall','wpa_supplicant'])
            time.sleep(1)
            change_netplan_flag = True
    else :
        if is_active_wpa_supplicant() == False :
            _shell(['/usr/bin/killall','wpa_supplicant'])
            time.sleep(1)
            _shell(['/usr/bin/systemctl','start','wpa_supplicant'])
            change_netplan_flag = True

    if change_netplan_flag == True or force == True:
        _shell(['netplan','generate'])
        _shell(['netplan','apply'])
        if wlan_chmask_use == True :
            set_wpa_suppl()

    if wlan_chmask_use == False :
        #wpa_cli -p /run/wpa_supplicant -i wlan0 set_network 0 bgscan '"simple:3:-65:30"'
        set_wpa_bgscan(wpa_bgscan_parm)
        #wpa_cli -p /run/wpa_supplicant -i wlan0 autoscan '"periodic:30"'
        _shell(_wpa_cli_cmd("autoscan", f'"{wpa_autoscan_parm}"'))

    set_wpa_reassociate()


def _parse_bool(value):
    return str(value).lower() in {"1", "true", "yes", "y", "on"}


def main(force=False):
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            if arg == "--force":
                force = True
            elif arg.startswith("--force="):
                force = _parse_bool(arg.split("=", 1)[1])
            elif arg.startswith("force="):
                force = _parse_bool(arg.split("=", 1)[1])

    update_network(force=force)
    return 0


if __name__ == "__main__":
    syslog.openlog("update_network", syslog.LOG_PID, syslog.LOG_LOCAL0)
    sys.exit(main())
