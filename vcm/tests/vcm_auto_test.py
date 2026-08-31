#!/usr/bin/env python3
import json
import subprocess
import time
import os
import signal
import socket
import argparse
import struct

# --- 경로 및 환경 설정 ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(BASE_DIR)
SHARED_V = "/tmp/shared_v" 
SYSROOT = "/shared/fsl-imx-xwayland/5.10-hardknott/sysroots/cortexa53-crypto-poky-linux"
VCM_BIN = os.path.join(PROJECT_ROOT, "vcm")
MSG_Q_KEY = 0x64

# --- 테스트 케이스 정의 ---
test_cases = [
    {
        "id": 1,
        "name": "Standard_Boot_Check",
        "vhl_cam": {"vhl_name": "BOOT_TEST"},
        "vcm": {"port_num": 11001, "srt_test": False}
    },
    {
        "id": 6,
        "name": "Deep_SRT_Generation_Logic",
        "vhl_cam": {"vhl_name": "DEEP_SRT_GEN"},
        "vcm": {"port_num": 11006, "srt_test": True},
        "is_deep": True
    }
]

def update_config(vhl_cam_updates, vcm_updates):
    os.makedirs(SHARED_V, exist_ok=True)
    for f in os.listdir(SHARED_V): os.remove(os.path.join(SHARED_V, f))
    for filename, section, updates in [("edgeconf_pim.json", "VHL_CAM", vhl_cam_updates), ("ord_vcm_conf.json", "VCM", vcm_updates)]:
        path = os.path.join(SHARED_V, filename)
        data = {section: {"vhl_name": "DEFAULT", "recording_time": 1, "tmp_path": "/tmp", "port_num": 10009}}
        if os.path.exists(path):
            with open(path, 'r') as f: data = json.load(f)
        data[section].update(updates)
        with open(path, 'w') as f: json.dump(data, f, indent=2)

def validate_tcp_response(port, payload):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            s.sendall(json.dumps(payload).encode())
            resp = s.recv(4096)
            return b"RET\":0" in resp or b"REP\"" in resp
    except: return False

def run_test(case, global_deep=False):
    if case.get('is_deep') and not global_deep:
        return True

    print(f"🚀 Case {case['id']}: {case['name']}...")
    subprocess.run(["killall", "-9", "qemu-aarch64", "vcm"], stderr=subprocess.DEVNULL)
    update_config(case.get('vhl_cam', {}), case.get('vcm', {}))
    
    # stdbuf -oL를 사용하여 로그 출력을 실시간으로 강제
    proc = subprocess.Popen(["stdbuf", "-oL", "qemu-aarch64", "-L", SYSROOT, VCM_BIN], 
                            cwd=PROJECT_ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, 
                            preexec_fn=os.setsid, text=True)
    
    success = False
    port = case.get('vcm', {}).get('port_num', 10009)
    wait_limit = 120 if case.get('is_deep') else 20
    
    print(f"  ⏳ Monitoring (Limit {wait_limit}s)...", end="", flush=True)
    start_t = time.time()
    while time.time() - start_t < wait_limit:
        # TCP 체크
        if not success and validate_tcp_response(port, {"REQ": "GET_CONFIG"}):
            print("✅ TCP OK", end="", flush=True)
            success = True
            if not case.get('is_deep'): break
            
        # SRT 체크 (Deep mode 전용)
        if case.get('is_deep'):
            vhl_name = case['vhl_cam']['vhl_name']
            if any(vhl_name in f for f in os.listdir("/tmp") if f.endswith(".srt.part")):
                print(" ✅ SRT OK", end="", flush=True)
                success = True; break
        
        print(".", end="", flush=True)
        time.sleep(5)
    print("")

    print(f"  {'✅ PASSED' if success else '❌ FAILED'}")
    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    return success

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--deep", action="store_true")
    args = parser.parse_args()
    results = [run_test(c, args.deep) for c in test_cases if not (c.get('is_deep') and not args.deep)]
    print(f"\nResult: {results.count(True)}/{len(results)} Passed")
    exit(0 if all(results) else 1)