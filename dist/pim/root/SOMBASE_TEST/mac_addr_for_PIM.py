import sys
import subprocess
from struct import pack

def is_hex(s):
    hex_digits = set("0123456789abcdef")
    for char in s:
        if not (char in hex_digits):
            return False
    return True

def is_valid_mac_addr(val):
	if len(val) != 17 :
		print("error 1")
		return False
	if val.find(':') != -1 :
		print("error 2")
		return False
	table = val.maketrans('/', ' ')
	fixed_val = val.translate(table)
	split_val = fixed_val.split()
	s = split_val[0] + split_val[1] + split_val[2] + split_val[3] + split_val[4] + split_val[5]
	return is_hex(s)

def fn_read_eth0_mac_addr() :
	try :
		ret = subprocess.check_output("hexdump /sys/devices/platform/soc@0/30000000.bus/30350000.efuse/imx-ocotp0/nvmem | grep ^0000090", shell = True, stderr=subprocess.STDOUT, encoding='utf-8')
		split_ret = ret.split(' ')
		ret = ""
		read_seq = [3, 2, 1]
		for i in read_seq :
			split_idx_ret = split_ret[i]
			append_ret = split_idx_ret[0:2] + '/' + split_idx_ret[2:4] + '/'
			ret += append_ret
			
		list_ret = list(ret)
		list_ret[-1] = ''
		str_ret = ''.join(list_ret)
		return str_ret
	except subprocess.CalledProcessError as e:
		return ""

def fn_read_eth1_mac_addr() :
	try :
		ret = subprocess.check_output("hexdump /sys/devices/platform/soc@0/30000000.bus/30350000.efuse/imx-ocotp0/nvmem | grep ^0000090", shell = True, stderr=subprocess.STDOUT, encoding='utf-8')
		split_ret = ret.split(' ')
		ret = ""
		read_seq = [6, 5, 4]
		for i in read_seq :
			split_idx_ret = split_ret[i]
			append_ret = split_idx_ret[0:2] + '/' + split_idx_ret[2:4] + '/'
			ret += append_ret
			
		list_ret = list(ret)
		list_ret[-1] = ''
		str_ret = ''.join(list_ret)
		return str_ret
	except subprocess.CalledProcessError as e:
		return ""

def read_eth0_mac_addr() :
	rd_mac = fn_read_eth0_mac_addr()
	if rd_mac == "" :
		print('DATA:00/00/00/00/00/00')
		return False
	print('DATA:eth0 '+rd_mac)
	return True

def read_eth1_mac_addr() :
	rd_mac = fn_read_eth1_mac_addr()
	if rd_mac == "" :
		print('DATA:00/00/00/00/00/00')
		return False
	print('DATA:eth1 '+rd_mac)
	return True

def write_eth0_mac_addr(mac_addr) :
	rd_mac = fn_read_eth0_mac_addr()
	if rd_mac != "" :
		if rd_mac != "00/00/00/00/00/00" :
			print('DATA:eth0 '+rd_mac)
			print("ERROR:already written")
			return False

	table = mac_addr.maketrans('/', ' ')
	fixed_mac_addr = mac_addr.translate(table)
	split_mac_addr = fixed_mac_addr.split()

	str_ret0 = split_mac_addr[2] + split_mac_addr[3] + split_mac_addr[4] + split_mac_addr[5]
	str_ret1 = split_mac_addr[0] + split_mac_addr[1]
	# print(str_ret0)
	# print(str_ret1)

	int_ret0 = int(str_ret0, 16)
	int_ret1 = int(str_ret1, 16)
	# print(int_ret0)
	# print(int_ret1)

	f = open('/sys/devices/platform/soc@0/30000000.bus/30350000.efuse/imx-ocotp0/nvmem', 'br+')
	f.seek(0x90)
	f.write(pack('<L', int_ret0))
	# f.write(pack('<L', 0x01020304))

	f.seek(0x94)
	f.write(pack('<L', int_ret1))
	# f.write(pack('<L', 0x0506))

	f.close()

	# print("[Success] Mac address writing finished")

	read_eth0_mac_addr()
	return True

def write_eth1_mac_addr(mac_addr) :
	rd_mac = fn_read_eth1_mac_addr()
	if rd_mac != "" :
		if rd_mac != "00/00/00/00/00/00" :
			print('DATA:eth1 '+rd_mac)
			print("ERROR:already written")
			return False

	table = mac_addr.maketrans('/', ' ')
	fixed_mac_addr = mac_addr.translate(table)
	split_mac_addr = fixed_mac_addr.split()

	str_ret0 = split_mac_addr[4] + split_mac_addr[5] + '0000'
	str_ret1 = split_mac_addr[0] + split_mac_addr[1] + split_mac_addr[2] + split_mac_addr[3]
	# print(str_ret0)
	# print(str_ret1)

	int_ret0 = int(str_ret0, 16)
	int_ret1 = int(str_ret1, 16)
	# print(int_ret0)
	# print(int_ret1)

	f = open('/sys/devices/platform/soc@0/30000000.bus/30350000.efuse/imx-ocotp0/nvmem', 'br+')
	f.seek(0x94)
	f.write(pack('<L', int_ret0))
	# f.write(pack('<L', 0x01020304))

	f.seek(0x98)
	f.write(pack('<L', int_ret1))
	# f.write(pack('<L', 0x0506))

	f.close()

	# print("[Success] Mac address writing finished")

	read_eth1_mac_addr()
	return True


cmd = sys.argv[1]
ethx = sys.argv[2]

if cmd != "read" and cmd != "write" :
	print("ERROR:wrong format")
	exit()

if ethx != "eth0" and ethx != "eth1" :
	print("ERROR:wrong format")
	exit()

if cmd == "read" :
	if ethx == "eth0" :
		read_eth0_mac_addr()
	elif ethx == "eth1" :
		read_eth1_mac_addr()
elif cmd == "write" :
	mac_addr = sys.argv[3]
	if is_valid_mac_addr(mac_addr) == False:
		print("ERROR:wrong format")
		exit()
	if ethx == "eth0" :
		rd_mac = fn_read_eth0_mac_addr()
		if mac_addr == rd_mac :
			print('DATA:eth0 '+mac_addr)
			exit()
		write_eth0_mac_addr(mac_addr)
	elif ethx == "eth1" :
		rd_mac = fn_read_eth1_mac_addr()
		if mac_addr == rd_mac :
			print('DATA:eth1 '+mac_addr)
			exit()
		write_eth1_mac_addr(mac_addr)



