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

def calcu_set_gateway_ip(ip_str, sub_str):
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
    
    return str(ipadd.network[1])

def search_conf(pattern):
    conf_file = ""
    conf_list = glob.glob(pattern)
    if len(conf_list) == 1:
        return conf_list[0]
    else :
        return False

def get_global_conf():
    global_conf_path = "/root/shared_v/edgeconf_pim.json"
#    global_conf_path = ""
#    try:
#        with open("/tmp/global_edgeconf_path", "r") as f :
#            global_conf_path = f.readline()
#            global_conf_path = global_conf_path.replace('\n',"")
#            f.close()
#    except:
#        return ""    
    return global_conf_path

#################################################

json_path = get_global_conf()
#print("json_path : "+json_path)

with open(json_path, "r") as f :
    edgeconf = json.load(f)

#sysinfo = {

#}

#try:
#    with open("/etc/cts/sysinfo.json", "r") as sys_f :
#        sysinfo = json.load(sys_f)
#except:
#	print("/etc/cts/sysinfo.json file not found")

assert edgeconf['NETWORK']
assert edgeconf['NETWORK']['ETH0']
assert edgeconf['NETWORK']['ETH1']
assert edgeconf['NETWORK']['WLAN0']

change_netplan_flag = False

with open("/tmp/eth0.yaml", "w") as f :
    #f.write("network:\n  version: 2\n  ethernets:\n    eth0:\n      renderer: NetworkManager\n")
    f.write("network:\n  version: 2\n  ethernets:\n    eth0:\n      renderer: networkd\n")
    if edgeconf['NETWORK']['ETH0']['method'] == 'static' :
        f.write("      addresses: [")
        f.write(calcu_set_static_ip(edgeconf['NETWORK']['ETH0']['address'], edgeconf['NETWORK']['ETH0']['netmask']))
        f.write("]\n")
        
        if is_json_key_present(edgeconf['NETWORK']['ETH0'], 'gateway') == True :
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
    
    f.close()

file_conn_eth0 = '/etc/netplan/eth0.yaml'
if os.path.isfile(file_conn_eth0) == False or cmp('/tmp/eth0.yaml',file_conn_eth0) == False :
    change_netplan_flag = True
    subprocess.call(['cp','/tmp/eth0.yaml',file_conn_eth0])

subprocess.call(['rm','/tmp/eth0.yaml'])

with open("/tmp/eth1.yaml", "w") as f :
    #f.write("network:\n  version: 2\n  ethernets:\n    eth1:\n      renderer: NetworkManager\n")
    f.write("network:\n  version: 2\n  ethernets:\n    eth1:\n      renderer: networkd\n")
    if edgeconf['NETWORK']['ETH1']['method'] == 'static' :
        f.write("      addresses: [")
        f.write(calcu_set_static_ip(edgeconf['NETWORK']['ETH1']['address'], edgeconf['NETWORK']['ETH1']['netmask']))
        f.write("]\n")
        
        if is_json_key_present(edgeconf['NETWORK']['ETH1'], 'gateway') == True :
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
    
    f.close()

file_conn_eth1 = '/etc/netplan/eth1.yaml'
if os.path.isfile(file_conn_eth1) == False or cmp('/tmp/eth1.yaml',file_conn_eth1) == False :
    change_netplan_flag = True
    subprocess.call(['cp','/tmp/eth1.yaml',file_conn_eth1])

subprocess.call(['rm','/tmp/eth1.yaml'])


with open("/tmp/wlp1s0.yaml", "w") as f :
    f.write("network:\n  version: 2\n  wifis:\n    wlp1s0:\n      renderer: networkd\n")
    if edgeconf['NETWORK']['WLAN0']['security'] == 'PSK' :
        f.write("      access-points:\n")
        f.write("        ")
        if edgeconf['NETWORK']['WLAN0']['chmask'] == True :
            f.write("dummy_ssid: {}\n")
        else :
            f.write(edgeconf['NETWORK']['WLAN0']['ssid'])
            f.write(":\n")
            f.write("          password: ")
            f.write(edgeconf['NETWORK']['WLAN0']['passwd'])
            f.write("\n")
    elif edgeconf['NETWORK']['WLAN0']['security'] == 'EAP' :
        f.write("      optional: true\n")
        f.write("      access-points:\n")
        f.write("        ")
        if edgeconf['NETWORK']['WLAN0']['chmask'] == True :
            f.write("dummy_ssid: {}\n")
        else :
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
        if edgeconf['NETWORK']['WLAN0']['chmask'] == True :
            f.write("dummy_ssid: {}\n")
        else :
            f.write(edgeconf['NETWORK']['WLAN0']['ssid'])
        f.write(": {}\n")
    
    if edgeconf['NETWORK']['WLAN0']['method'] == 'static' :
        f.write("      addresses: [")
        f.write(calcu_set_static_ip(edgeconf['NETWORK']['WLAN0']['address'], edgeconf['NETWORK']['WLAN0']['netmask']))
        f.write("]\n")
        
        if is_json_key_present(edgeconf['NETWORK']['WLAN0'], 'gateway') == True :
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
    f.close()

if edgeconf['NETWORK']['WLAN0']['chmask'] == True :
    with open("/tmp/wpa_supplicant.conf", "w") as f :
        f.write("ctrl_interface=/var/run/wpa_supplicant\n")
        f.write("bgscan=\"")
        f.write(edgeconf['NETWORK']['WLAN0']['bgscan'])
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
        
    file_wpa_supplicant = '/etc/wpa_supplicant/wpa_supplicant.conf'
    if os.path.isfile(file_wpa_supplicant) == False or cmp('/tmp/wpa_supplicant.conf',file_wpa_supplicant) == False :
        subprocess.call(['cp','/tmp/wpa_supplicant.conf',file_wpa_supplicant])
        subprocess.call(['chmod','644',file_wpa_supplicant])
        change_wpa_supplicant_flag = True

    subprocess.call(['rm','/tmp/wpa_supplicant.conf'])



#wpa_autoscan_parm = ''
#wpa_bgscan_parm = ''
#change_wpa_supplicant_flag = False
#with open("/tmp/wpa_supplicant.conf", "w") as f :
    #f.write('ctrl_interface=/run/wpa_supplicant\nctrl_interface_group=0\nupdate_config=1\ncountry=KR\nap_scan=1\npassive_scan=0\n')
    #if is_json_key_present(sysinfo, 'wifi_autoscan_param') == True :
    #    wpa_autoscan_parm = '"' + str(sysinfo['wifi_autoscan_param']) +'"'
    #    f.write('autoscan=')
    #    f.write(wpa_autoscan_parm)
    #    f.write("\n")
    
#    if is_json_key_present(sysinfo, 'wifi_bgscan_param') == True :
#        wpa_bgscan_parm = '"' + str(sysinfo['wifi_bgscan_param']) +'"'
#        f.write('bgscan=')
#        f.write(wpa_bgscan_parm)
#        f.write("\n")
    
#    f.close()



file_conn_wlan0 = '/etc/netplan/wlp1s0.yaml'
if os.path.isfile(file_conn_wlan0) == False or cmp('/tmp/wlp1s0.yaml',file_conn_wlan0) == False :
    change_netplan_flag = True
    subprocess.call(['cp','/tmp/wlp1s0.yaml',file_conn_wlan0])

subprocess.call(['rm','/tmp/wlp1s0.yaml'])

if change_netplan_flag == True :
    subprocess.call(['/usr/bin/killall','wpa_supplicant'])
    subprocess.call(['netplan','generate'])
    subprocess.call(['netplan','apply'])
    if edgeconf['NETWORK']['WLAN0']['chmask'] == True :
        subprocess.call(['/opt/pim/bin/set_wpa_suppl.sh'])
#subprocess.call(['wpa_cli','-i', 'wlan0','scan'])
