#!/usr/bin/env python3
import json
import subprocess
import time
import os
import signal
import socket
import argparse

# --- 경로 및 환경 설정 ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(BASE_DIR)
SHARED_V = "/tmp/shared_v"
SYSROOT = "/shared/fsl-imx-xwayland/5.10-hardknott/sysroots/cortexa53-crypto-poky-linux"
ORD_BIN = os.path.join(PROJECT_ROOT, "ord")

OHT_SIMULATOR = os.path.join(BASE_DIR, "oht_simulator.py")

# --- 테스트 케이스 정의 ---
test_cases = [
    {
        "id": 1,
        "name": "ORD_OHT_Interface_Check",
        "vhl_cam": {"vhl_name": "ORD_TEST"},
        "ord": {"port_num": 10007},
        "payload": {"REQ": "GET_CONFIG"},
        "use_simulator": True,
    }
]


def start_oht_simulator(port, duration=30):
    cmd = [
        "python3",
        OHT_SIMULATOR,
        "--port",
        str(port),
        "--test",
        "--duration",
        str(duration),
    ]
    return subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )


def run_with_simulator(case):
    print(f"🚀 Case {case['id']}: {case['name']} (OHT 시뮬레이터)...")
    subprocess.run(["killall", "-9", "qemu-aarch64", "ord"], stderr=subprocess.DEVNULL)
    update_config(case.get("vhl_cam", {}), case.get("ord", {}))

    proc = subprocess.Popen(
        ["stdbuf", "-oL", "qemu-aarch64", "-L", SYSROOT, ORD_BIN],
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
        text=True,
    )

    port = case.get("ord", {}).get("port_num", 10007)
    time.sleep(3)

    print(f"  🤖 OHT 시뮬레이터 시작 (port {port})")
    sim_proc = start_oht_simulator(port, duration=30)

    success = False
    start_t = time.time()
    print("  ⏳ ord-oht 핸드셰이크 대기 (Max 60s)...", end="", flush=True)
    while time.time() - start_t < 60:
        ret = sim_proc.poll()
        if ret == 0:
            success = True
            break
        if ret is not None and ret != 0:
            break
        print(".", end="", flush=True)
        time.sleep(2)
    print("")

    if sim_proc.poll() is None:
        sim_proc.terminate()
        try:
            sim_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            sim_proc.kill()

    if not success:
        out, _ = sim_proc.communicate()
        if out:
            print(f"  📄 OHT 시뮬레이터 출력:\n{out}")

    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    print(f"  {'✅ PASSED' if success else '❌ FAILED'}")
    return success


def update_config(vhl_cam_updates, ord_updates):
    os.makedirs(SHARED_V, exist_ok=True)
    # 공식 설정 파일을 기반으로 업데이트
    for filename, section, updates in [
        ("edgeconf_pim.json", "VHL_CAM", vhl_cam_updates),
        ("ord_vcm_conf.json", "ORD", ord_updates),
    ]:
        path = os.path.join(SHARED_V, filename)

        if not os.path.exists(path):
            # 파일이 없으면 docs 디렉토리에서 복사 시도
            src_path = os.path.join(PROJECT_ROOT, "docs", filename)
            if os.path.exists(src_path):
                import shutil

                shutil.copy(src_path, path)
            else:
                # 최후의 수단으로 기본 구조 생성
                with open(path, "w") as f:
                    json.dump({section: {}}, f)

        with open(path, "r") as f:
            try:
                data = json.load(f)
            except:
                data = {section: {}}

        if section not in data:
            data[section] = {}

        data[section].update(updates)
        with open(path, "w") as f:
            json.dump(data, f, indent=2)


def validate_tcp(port, payload):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            s.sendall(json.dumps(payload).encode())
            resp = s.recv(4096)
            return b'RET":0' in resp or b'REP"' in resp
    except:
        return False


def run_test(case):
    if case.get("use_simulator", False):
        return run_with_simulator(case)

    print(f"🚀 Case {case['id']}: {case['name']}...")
    subprocess.run(["killall", "-9", "qemu-aarch64", "ord"], stderr=subprocess.DEVNULL)
    update_config(case.get("vhl_cam", {}), case.get("ord", {}))

    # ord 실행 (로그 버퍼링 해제)
    proc = subprocess.Popen(
        ["stdbuf", "-oL", "qemu-aarch64", "-L", SYSROOT, ORD_BIN],
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
        text=True,
    )

    success = False
    port = case.get("ord", {}).get("port_num", 10007)

    print(
        f"  ⏳ Waiting for OHT connection on port {port} (Max 60s)...",
        end="",
        flush=True,
    )
    start_t = time.time()
    while time.time() - start_t < 60:
        if validate_tcp(port, case.get("payload")):
            success = True
            break
        print(".", end="", flush=True)
        time.sleep(5)
    print("")

    print(f"  {'✅ PASSED' if success else '❌ FAILED'}")
    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    return success


if __name__ == "__main__":
    if not os.path.exists(ORD_BIN):
        print("Error: Run make first.")
        exit(1)
    results = [run_test(c) for c in test_cases]
    print(f"\nResult: {results.count(True)}/{len(results)} Passed")
    exit(0 if all(results) else 1)
