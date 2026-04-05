#!/usr/bin/env python3
import sys
import struct
import time
import json
import socket
import os

try:
    import sysv_ipc
except ImportError:
    print("Warning: sysv_ipc module not found. IPC simulation disabled.")

try:
    import redis
except ImportError:
    print("Warning: redis module not found. Redis simulation disabled.")

# VCM Constants (matched with tcpServer.h)
MSG_Q_KEY = 0x64
CMD_STATUSINFO_BLACKBOX = 41001
MACHINE_TYPE_BLACKBOX = 0x06

# Redis Constants
RDS_OPS_HEADER = "OPS"
RDS_DATA_CMD = "recent_data"
RDS_TAG_KEY = "tag"
RDS_OFFSET_KEY = "offset"

def send_redis_data(tag, offset):
    """VCM이 읽어가는 Redis OPS 데이터를 시뮬레이션하여 주입"""
    try:
        r = redis.Redis(host='127.0.0.1', port=6379, db=0)
        key = f"{RDS_OPS_HEADER}:{RDS_DATA_CMD}"
        data = {
            RDS_TAG_KEY: str(tag),
            RDS_OFFSET_KEY: float(offset)
        }
        r.set(key, json.dumps(data))
        print(f"[Redis] Set Data: {key} = {data}")
    except Exception as e:
        print(f"[Redis] Error: {e}")

def send_ipc_data(node_id, speed, status='G'):
    """VCM의 Message Queue에 OHT 데이터를 시뮬레이션하여 전송"""
    try:
        mq = sysv_ipc.MessageQueue(MSG_Q_KEY, sysv_ipc.IPC_CREAT, mode=0o660)
        
        machine_type = 0x3233 
        machine_id = b"VD3001"
        cmd = CMD_STATUSINFO_BLACKBOX
        
        curMode = ord('A')
        curStatus = ord(status)
        curNodeID = int(node_id)
        tagetNodeID = 9999
        curNodeOffset = 100
        drivingSpeed = float(speed)
        
        header = struct.pack("<H6sH", machine_type, machine_id, cmd)
        overlay_data = struct.pack("<BBIIid", curMode, curStatus, curNodeID, tagetNodeID, curNodeOffset, drivingSpeed)
        
        padding = b'\x00' * (55 - len(header) - len(overlay_data))
        full_msg = header + overlay_data + padding
        
        mq.send(full_msg, type=1)
        print(f"[IPC] Sent Data: NodeID={node_id}, Speed={speed}, Status={status}")
    except Exception as e:
        print(f"[IPC] Error: {e}")

def test_tcp_interface():
    """TCP 포트 10009에 접속하여 설정 요청 테스트"""
    print("[TCP] Connecting to VCM...")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(("127.0.0.1", 10009))
            
            req = json.dumps({"REQ": "GET_CONFIG"})
            s.sendall(req.encode())
            data = s.recv(1024)
            print(f"[TCP] Received Config: {data.decode()}")
            
            req = json.dumps({"REQ": "SET_OVERLAY_START"})
            s.sendall(req.encode())
            print("[TCP] Overlay Started. Waiting for stream data...")
            
            s.settimeout(5.0)
            while True:
                data = s.recv(1024)
                if not data: break
                print(f"[TCP] Stream Data: {data.decode()}")
                break
    except Exception as e:
        print(f"[TCP] Error: {e}")

if __name__ == "__main__":
    print("=== VCM Advanced Functional Simulator ===")
    
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "tcp":
            test_tcp_interface()
        elif arg == "redis":
            print("Starting Redis OPS data loop (Press Ctrl+C to stop)")
            offset = 0.0
            try:
                while True:
                    send_redis_data("TEST_TAG", offset)
                    offset += 0.5
                    time.sleep(0.5)
            except KeyboardInterrupt:
                print("\nStopped.")
        elif arg == "all":
            print("Starting Integrated simulation (IPC + Redis)")
            node = 2000
            offset = 0.0
            try:
                while True:
                    send_ipc_data(node, 2.5)
                    send_redis_data("AUTO_NODE", offset)
                    node += 1
                    offset += 0.1
                    time.sleep(0.5)
            except KeyboardInterrupt:
                print("\nStopped.")
    else:
        print("Usage: python3 vcm_simulator.py [tcp|redis|all]")
        print("Starting Default IPC data loop (Press Ctrl+C to stop)")
        node = 1000
        try:
            while True:
                send_ipc_data(node, 1.25)
                node += 1
                time.sleep(0.5)
        except KeyboardInterrupt:
            print("\nStopped.")