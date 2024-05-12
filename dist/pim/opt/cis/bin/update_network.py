import sys
sys.path.append("/opt/cis/bin")
import getconfval
import json
import subprocess
import ipaddress
import os.path
from filecmp import cmp
import glob

def is_json_key_present(json, key):
    try:
        buf = json[key]
    except KeyError:
        return False
    
    if buf == "":
        return False

    return True

def calcu_set_static_ip(ip_str, sub_str):
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

def _run_command(command):
    result = True
    try:
        subprocess.run(command, shell=True, check=True, capture_output=True)
        result = True
    except subprocess.CalledProcessError as e:
        result = False
    return result

def set_wpa_suppl():
    wlan_dev = getconfval.get_json_val("dev_wlan")
    subprocess.run("/usr/bin/killall wpa_supplicant", shell=True)
    for var in range(1,5):
        if _run_command("/sbin/wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant.conf -i"+wlan_dev+" -Dnl80211,wext -B") == True:
            return
    return

def is_active_wpa_supplicant():
    result = True
    try:
        out = subprocess.run("systemctl is-active wpa_supplicant", shell=True, check=True, capture_output=True)
        if out == "inactive":
            result = False
    except subprocess.CalledProcessError as e:
        result = False
    return result

#################################################

json_path = getconfval.get_global_conf()
#print("json_path : "+json_path)

with open(json_path, "r") as f :
    edgeconf = json.load(f)

assert edgeconf['NETWORK']
assert edgeconf['NETWORK']['ETH0']
assert edgeconf['NETWORK']['ETH1']
assert edgeconf['NETWORK']['WLAN0']

change_netplan_flag = False

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

    if edgeconf['NETWORK']['used'] != 'ETH0' :
        f.write("      dhcp4-overrides:\n")
        f.write("         use-routes: false\n")
    
    f.close()

file_conn_eth0 = '/etc/netplan/eth0.yaml'
if os.path.isfile(file_conn_eth0) == False or cmp('/tmp/eth0.yaml',file_conn_eth0) == False :
    change_netplan_flag = True
    subprocess.call(['cp','/tmp/eth0.yaml',file_conn_eth0])

subprocess.call(['rm','/tmp/eth0.yaml'])

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
    
    if edgeconf['NETWORK']['used'] != 'ETH1' :
        f.write("      dhcp4-overrides:\n")
        f.write("         use-routes: false\n")

    f.close()

file_conn_eth1 = '/etc/netplan/eth1.yaml'
if os.path.isfile(file_conn_eth1) == False or cmp('/tmp/eth1.yaml',file_conn_eth1) == False :
    change_netplan_flag = True
    subprocess.call(['cp','/tmp/eth1.yaml',file_conn_eth1])

subprocess.call(['rm','/tmp/eth1.yaml'])


wlan_dev = getconfval.get_json_val("dev_wlan")
temp_conn_wlan0="/tmp/"+wlan_dev+".yaml"

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
    f.write("network:\n  version: 2\n  wifis:\n    "+wlan_dev+":\n      renderer: networkd\n")
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

    if edgeconf['NETWORK']['used'] != 'WLAN0' :
        f.write("      dhcp4-overrides:\n")
        f.write("         use-routes: false\n")

    f.close()


wpa_bgscan_parm = 'simple:3:-70:300'
if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'bgscan') == True :
    wpa_bgscan_parm = edgeconf['NETWORK']['WLAN0']['bgscan']

wpa_autoscan_parm = 'periodic:30'
if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'autoscan') == True :
    wpa_autoscan_parm = edgeconf['NETWORK']['WLAN0']['autoscan']

change_wpa_supplicant_flag = False

if wlan_chmask_use == True :
    with open("/tmp/wpa_supplicant.conf", "w") as f :
        f.write("ctrl_interface=/var/run/wpa_supplicant\n")
        f.write("bgscan=\"")
        f.write(wpa_bgscan_parm)
        f.write("\"\n")
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
        f.write("}\n")
        f.close()
else :
    with open("/tmp/wpa_supplicant.conf", "w") as f :
        f.write('ctrl_interface=/run/wpa_supplicant\nctrl_interface_group=0\nupdate_config=1\ncountry=KR\nap_scan=1\npassive_scan=0\n')
        f.write("bgscan=\"")
        f.write(wpa_bgscan_parm)
        f.write("\"\n")
        f.write("autoscan=\"")
        f.write(wpa_autoscan_parm)
        f.write("\"\n")
        f.close()

file_wpa_supplicant = '/etc/wpa_supplicant/wpa_supplicant.conf'
if os.path.isfile(file_wpa_supplicant) == False or cmp('/tmp/wpa_supplicant.conf',file_wpa_supplicant) == False :
    subprocess.call(['cp','/tmp/wpa_supplicant.conf',file_wpa_supplicant])
    subprocess.call(['chmod','644',file_wpa_supplicant])
    change_wpa_supplicant_flag = True

subprocess.call(['rm','/tmp/wpa_supplicant.conf'])

if wlan_dev == "wlan0" :
    subprocess.run("rm /etc/netplan/wlp1s0.yaml > /dev/null 2>&1", shell=True)
elif wlan_dev == "wlp1s0" :
    subprocess.run("rm /etc/netplan/wlan0.yaml > /dev/null 2>&1", shell=True)

file_conn_wlan0 = '/etc/netplan/'+wlan_dev+'.yaml'
if os.path.isfile(file_conn_wlan0) == False or cmp(temp_conn_wlan0,file_conn_wlan0) == False :
    change_netplan_flag = True
    subprocess.call(['cp',temp_conn_wlan0,file_conn_wlan0])

subprocess.call(['rm',temp_conn_wlan0])

if wlan_chmask_use == True :
    if is_active_wpa_supplicant() == True :
        subprocess.call(['/usr/bin/killall','wpa_supplicant'])
        change_netplan_flag = True
else :
    if is_active_wpa_supplicant() == False :
        subprocess.call(['/usr/bin/killall','wpa_supplicant'])
        subprocess.call(['/usr/bin/systemctl','start','wpa_supplicant'])
        change_netplan_flag = True

if change_netplan_flag == True :
    subprocess.call(['netplan','generate'])
    subprocess.call(['netplan','apply'])
    if wlan_chmask_use == True :
        set_wpa_suppl()
    else :
        subprocess.call(['/opt/cis/bin/update_wpaprm.sh'])

subprocess.run("wpa_cli -i "+wlan_dev+" scan > /dev/null 2>&1", shell=True)
