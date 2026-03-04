#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import logging
import argparse
import json
import glob
import re
from datetime import datetime

# Constants & Paths
LOG_KEY = "GARD"
STATE_FILE = "/tmp/bg_chk_flag.bin"
RECOVERY_REQ_FILE = "/tmp/recover_req_init_cam"
EDGE_CONF_DIR = "/root/shared_v"
ORD_CONF_PATH = "/root/shared_v/ord_vcm_conf.json"
EXT_CSD_PATH = "/sys/kernel/debug/mmc2/mmc2:0001/ext_csd"
THERMAL_ZONE0 = "/sys/devices/virtual/thermal/thermal_zone0/temp"
THERMAL_ZONE1 = "/sys/devices/virtual/thermal/thermal_zone1/temp"
CPU_FREQ_BASE = "/sys/devices/system/cpu/cpu{}/cpufreq/cpuinfo_cur_freq"
MCP_TRUST_TOOL = "/opt/pim/bin/mcp_trust_test"

# Default Thresholds
MAX_CPU_TEMP = 85
VOLT_MIN = 20.4
VOLT_MAX = 27.6
DISK_LIMIT_PCT = 95
NUM_CORES = 4

logging.basicConfig(level=logging.INFO, format='%(message)s')
logger = logging.getLogger(LOG_KEY)

def syslog(level, msg):
    cmd = f"logger -p local0.{level} '[{LOG_KEY}] {msg}'"
    subprocess.run(cmd, shell=True)

class PIMHealthGuardian:
    def __init__(self, args):
        self.args = args
        self.conf = self._load_all_configs()
        self.cam_en_bitmask = self._get_cam_bitmask()
        self.expected_cam_count = bin(self.cam_en_bitmask).count('1')
        self.prev_io_stats = self._get_detailed_io()
        self.prev_net_stats = self._get_net_dev_stats()
        self.error_count = 0
        self.wifi_iface = self._detect_wifi_iface()
        
        self.peak_temp = 0
        self.min_volt = 100.0
        self.max_cpu = 0.0
        self.start_time = time.time()

    def _load_all_configs(self):
        conf = {
            'edge': {}, 'ord': {}, 'sd_path': '/mnt/sd_cam', 'sd_dev': 'mmcblk1',
            'v4l_map': {'csi0': 2, 'csi1': 3}, 'tmp_path': '/dev/shm', 'oht_name': 'VD3001'
        }
        try:
            files = sorted(glob.glob(f"{EDGE_CONF_DIR}/edgeconf_*.json"))
            if files:
                with open(files[-1], 'r') as f:
                    conf['edge'] = json.load(f)
                    cam = conf['edge'].get('VHL_CAM', {})
                    conf['sd_path'] = cam.get('final_path', '/mnt/sd_cam')
                    conf['tmp_path'] = cam.get('tmp_path', '/dev/shm')
                    conf['oht_name'] = cam.get('vhl_name', 'VD3001')
                    v_map = cam.get('v4l_map', cam.get('device_map', {}))
                    if v_map:
                        conf['v4l_map']['csi0'] = v_map.get('csi0_subdev', v_map.get('csi0_video', 2))
                        conf['v4l_map']['csi1'] = v_map.get('csi1_subdev', v_map.get('csi1_video', 3))
            with open('/proc/mounts', 'r') as f:
                for line in f:
                    if conf['sd_path'] in line:
                        m = re.search(r'(mmcblk\d+)', os.path.basename(line.split()[0]))
                        if m: conf['sd_dev'] = m.group(1); break
            if os.path.exists(ORD_CONF_PATH):
                with open(ORD_CONF_PATH, 'r') as f: conf['ord'] = json.load(f)
        except: pass
        return conf

    def _detect_wifi_iface(self):
        for c in ['wlp1s0', 'wlan0']:
            if os.path.exists(f"/sys/class/net/{c}"): return c
        try:
            with open("/proc/net/wireless", "r") as f:
                for line in f:
                    if ":" in line: return line.split(":")[0].strip()
        except: pass
        return "wlan0"

    def _get_cam_bitmask(self):
        cam = self.conf['edge'].get('VHL_CAM', {})
        ch0 = 1 if cam.get('i2c2', {}).get('ch0', {}).get('enable') else 0
        ch1 = 1 if cam.get('i2c2', {}).get('ch1', {}).get('enable') else 0
        ch2 = 1 if cam.get('i2c1', {}).get('ch2', {}).get('enable') else 0
        ch3 = 1 if cam.get('i2c1', {}).get('ch3', {}).get('enable') else 0
        return (ch3 << 3 | ch2 << 2 | ch1 << 1 | ch0)

    def _get_detailed_io(self):
        stats = {}
        try:
            with open("/proc/diskstats", "r") as f:
                for line in f:
                    p = line.split()
                    if len(p) < 13: continue
                    dev = p[2]
                    if "mmcblk" in dev and "p" not in dev:
                        stats[dev] = (int(p[5]), int(p[9]), int(p[12]), time.time())
        except: pass
        return stats

    def calculate_io_metrics(self):
        curr_stats = self._get_detailed_io()
        results = {}
        for dev, curr in curr_stats.items():
            if dev in self.prev_io_stats:
                prev = self.prev_io_stats[dev]
                dt = curr[3] - prev[3]
                if dt > 0:
                    rk = (curr[0] - prev[0]) * 0.5 / dt
                    wk = (curr[1] - prev[1]) * 0.5 / dt
                    util = ((curr[2] - prev[2]) / (dt * 1000.0)) * 100.0
                    results[dev] = {'rk': rk, 'wk': wk, 'util': max(0.0, min(util, 100.0))}
        self.prev_io_stats = curr_stats
        return results

    def _get_net_dev_stats(self):
        stats = {}
        try:
            with open("/proc/net/dev", "r") as f:
                lines = f.readlines()[2:]
                for line in lines:
                    if ":" in line:
                        iface, data = line.split(":")
                        p = data.split()
                        stats[iface.strip()] = (int(p[0]), int(p[8]), time.time())
        except: pass
        return stats

    def get_net_throughput(self):
        curr = self._get_net_dev_stats()
        results = {}
        for iface, c in curr.items():
            if iface in self.prev_net_stats:
                p = self.prev_net_stats[iface]
                dt = c[2] - p[2]
                if dt > 0:
                    rx = (c[0] - p[0]) / 1024.0 / dt
                    tx = (c[1] - p[1]) / 1024.0 / dt
                    results[iface] = (rx, tx)
        self.prev_net_stats = curr
        return results

    def get_app_info(self):
        apps = ["gstApp", "ord", "vcm"]
        res = {}
        for app in apps:
            try:
                out = subprocess.check_output(f"ps -C {app} -o %cpu,%mem,etime --no-headers | head -n 1", shell=True).decode()
                p = out.split()
                if len(p) >= 3:
                    res[app] = {"cpu": f"{float(p[0])/NUM_CORES:.1f}", "mem": p[1], "up": p[2]}
                else: raise Exception()
            except: res[app] = {"cpu": "0.0", "mem": "0.0", "up": "N/A"}
        return res

    def get_pipeline_heartbeat(self):
        pattern = f"{self.conf['tmp_path']}/{self.conf['oht_name']}_*.part"
        files = glob.glob(pattern)
        if not files: return "NO_FILES", 0
        latest_mtime = max([os.path.getmtime(f) for f in files])
        idle_sec = int(time.time() - latest_mtime)
        return ("OK" if idle_sec < 10 else "FROZEN"), idle_sec

    def check_zombies(self):
        try:
            return int(subprocess.check_output("ps -ef | grep defunct | grep -v grep | wc -l", shell=True).decode().strip())
        except: return 0

    def get_net_info(self, iface):
        status, extra = "N/A", ""
        state_path = f"/sys/class/net/{iface}/operstate"
        if os.path.exists(state_path):
            try:
                with open(state_path, 'r') as f: status = "UP" if f.read().strip() == "up" else "DOWN"
                if iface == self.wifi_iface:
                    with open("/proc/net/wireless", "r") as f:
                        for line in f:
                            if iface in line:
                                p = line.split()
                                extra = f"({p[2].replace('.','')}/{p[3].replace('.','')}dBm)"
                                break
            except: status = "ERR"
        return status, extra

    def get_disk_usage(self, path):
        info = {'mounted': False, 'mode': 'RW', 'usage': 0.0, 'size': '0G'}
        try:
            with open('/proc/mounts', 'r') as f:
                for line in f:
                    if path in line:
                        p = line.split(); info['mounted'] = True
                        info['mode'] = 'RO' if 'ro' in p[3].split(',') else 'RW'
                        break
            if info['mounted']:
                st = os.statvfs(path)
                total = (st.f_blocks * st.f_frsize) / (1024**3)
                free = (st.f_bfree * st.f_frsize) / (1024**3)
                info['usage'] = round((1 - free/total) * 100, 1) if total > 0 else 0.0
                info['size'] = f"{total:.1f}G"
        except: pass
        return info

    def get_hw_metrics(self):
        v, v_s = 0.0, "N/A"
        try:
            res = subprocess.check_output(f"{MCP_TRUST_TOOL} | grep voltage", shell=True).decode()
            v = float(res.split(':')[1].strip())
            v_s = "OK" if VOLT_MIN <= v <= VOLT_MAX else "ERR"
        except: pass
        t0 = -1
        try:
            with open(THERMAL_ZONE0, "r") as f: t0 = int(f.read()) // 1000
        except: pass
        la, lb = -1, -1
        try:
            if os.path.exists(EXT_CSD_PATH):
                with open(EXT_CSD_PATH, "r") as f:
                    r = f.read().strip()
                    la, lb = int(r[536:538], 16)*10, int(r[538:540], 16)*10
        except: pass
        try:
            rtc_ok = (subprocess.run("hwclock -r", shell=True, capture_output=True).returncode == 0)
        except: rtc_ok = False
        return v, v_s, t0, la, lb, rtc_ok

    def check_cams(self):
        active_count = 0
        csi0 = f"/dev/v4l-subdev{self.conf['v4l_map']['csi0']}"
        csi1 = f"/dev/v4l-subdev{self.conf['v4l_map']['csi1']}"
        checks = [
            (0x01, csi0, 'ae_on_ch0'),
            (0x02, csi0, 'ae_on_ch1'),
            (0x04, csi1, 'ae_on_ch2'),
            (0x08, csi1, 'ae_on_ch3'),
        ]
        for bit, node, ctrl in checks:
            if self.cam_en_bitmask & bit:
                res = subprocess.run(f"v4l2-ctl -d {node} --get-ctrl={ctrl}", shell=True, capture_output=True)
                if res.returncode == 0:
                    active_count += 1
        return f"{active_count}/{self.expected_cam_count}"

    def get_recent_error(self):
        try:
            # Monitor both journal and dmesg for link losses
            out = subprocess.check_output("journalctl -n 50 | grep -Ei 'error|failed|critical|panic|link loss' | tail -n 1", shell=True).decode().strip()
            if not out: return "None"
            return out[:80] + "..." if len(out) > 80 else out
        except: return "None"

    def start(self):
        syslog("notice", f"PIM Health Guardian 9.2 (Active-Cam) started")
        try:
            while True:
                v, v_s, temp, la, lb, rtc_ok = self.get_hw_metrics()
                thru = self.get_net_throughput()
                wf_s, wf_e = self.get_net_info(self.wifi_iface)
                et_s, _ = self.get_net_info("eth0")
                sd_d = self.get_disk_usage(self.conf['sd_path'])
                app_res = self.get_app_info()
                hb_s, hb_i = self.get_pipeline_heartbeat()
                io = self.calculate_io_metrics()
                cam_s = self.check_cams()
                z_cnt = self.check_zombies()
                last_err = self.get_recent_error()
                try:
                    cpu_t = subprocess.check_output("top -bn1 | grep 'Cpu(s)'", shell=True).decode().split()[1]
                except: cpu_t = "0.0"
                if temp > self.peak_temp: self.peak_temp = temp
                if v > 0 and v < self.min_volt: self.min_volt = v
                if float(cpu_t) > self.max_cpu: self.max_cpu = float(cpu_t)

                ts = datetime.now().strftime('%H:%M:%S')
                wf_thru = thru.get(self.wifi_iface, (0,0))
                et_thru = thru.get('eth0', (0,0))
                logger.info(f"[{ts}] [WF:{wf_s}{wf_e} R{wf_thru[0]:.0f}/T{wf_thru[1]:.0f}K][RTC:{'OK' if rtc_ok else 'ERR'}][CAM:{cam_s}][HB:{hb_s}({hb_i}s)]")
                sd_io = io.get(self.conf['sd_dev'], {'wk':0.0, 'util':0.0})
                logger.info(f"         ├─ [SD:{sd_d['mode']}/{sd_d['usage']}%][SHM:{self.get_disk_usage(self.conf['tmp_path'])['usage']}%][App_CPU: gst({app_res['gstApp']['cpu']}%) ord({app_res['ord']['cpu']}%) vcm({app_res['vcm']['cpu']}%)]")
                logger.info(f"         ├─ [App_Up: gst({app_res['gstApp']['up']}) ord({app_res['ord']['up']}) vcm({app_res['vcm']['up']})] [PWR:{v_s}({v:.2f}V)]")
                logger.info(f"         └─ [CPU:{cpu_t}%/T:{temp}C][IO_Util:{sd_io['util']:.1f}%][W_Speed:{sd_io['wk']:.1f}KB/s][Peak T:{self.peak_temp}C/V_Min:{self.min_volt:.2f}V]")
                logger.info(f"         🚨 Last Log: {last_err}")

                bits = 0
                if sd_d['mode'] == 'RO': bits |= 32
                if temp >= MAX_CPU_TEMP: bits |= 64
                if v_s == "ERR": bits |= 128
                if cam_s.split('/')[0] != cam_s.split('/')[1]: bits |= 1
                if hb_s == "FROZEN": bits |= 2
                try:
                    with open(STATE_FILE, "w") as f: f.write(str(bits))
                except: pass
                if bits > 0 and self.args.recovery and (bits & 1 or bits & 2):
                    self.error_count += 1
                    if self.error_count > 3:
                        syslog("err", f"Anomaly mask:0x{bits:02x}. Requesting recovery.")
                        subprocess.run(f"touch {RECOVERY_REQ_FILE}", shell=True)
                else: self.error_count = 0
                time.sleep(self.args.interval)
        except KeyboardInterrupt: syslog("notice", "Guardian stopped")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument('--recovery', action='store_true')
    p.add_argument('--interval', type=int, default=5)
    args = p.parse_args()
    PIMHealthGuardian(args).start()
