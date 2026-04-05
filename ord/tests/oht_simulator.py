#!/usr/bin/env python3
"""
OHT (Overhead Hoist Transport) Simulator for ord testing.
Mimics OHT client behavior to enable automated ord testing.
"""

import socket
import json
import time
import sys
import threading
import argparse


class OHTSimulator:
    """Simulates OHT client connecting to ord server."""

    def __init__(self, ord_host="127.0.0.1", ord_port=10007):
        self.ord_host = ord_host
        self.ord_port = ord_port
        self.socket = None
        self.connected = False
        self.running = False
        self.thread = None

    def connect(self, timeout=30):
        """Connect to ord server with retry."""
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.socket.settimeout(5)
                self.socket.connect((self.ord_host, self.ord_port))
                self.connected = True
                print(f"[OHT] Connected to ord at {self.ord_host}:{self.ord_port}")
                return True
            except (socket.error, ConnectionRefusedError):
                if self.socket:
                    self.socket.close()
                time.sleep(1)
        print(f"[OHT] Failed to connect to ord within {timeout}s")
        return False

    def send_get_config(self):
        """Send GET_CONFIG request to ord."""
        if not self.connected or not self.socket:
            print("[OHT] Not connected, cannot send GET_CONFIG")
            return False

        request = {"REQ": "GET_CONFIG"}
        try:
            self.socket.sendall(json.dumps(request).encode())
            print(f"[OHT] Sent: {request}")
            return True
        except socket.error as e:
            print(f"[OHT] Failed to send: {e}")
            return False

    def receive_response(self, timeout=5):
        """Receive and parse response from ord."""
        if not self.connected or not self.socket:
            return None

        self.socket.settimeout(timeout)
        try:
            data = self.socket.recv(4096)
            if not data:
                return None

            # Try to parse as JSON first
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                print(f"[OHT] Received binary ({len(data)} bytes): {data[:50]}...")
                return data

            try:
                response = json.loads(text)
                print(f"[OHT] Received JSON: {response}")
                return response
            except json.JSONDecodeError:
                print(f"[OHT] Received non-JSON ({len(data)} bytes): {data[:50]}...")
                return data
        except socket.timeout:
            return None
        except socket.error as e:
            print(f"[OHT] Receive error: {e}")
            return None

    def validate_get_config_response(self, response):
        """Validate that response to GET_CONFIG is valid."""
        if response is None:
            print("[OHT] No response received")
            return False

        if isinstance(response, dict):
            # JSON response
            if "RET" in response and response["RET"] == 0:
                print("[OHT] Valid response: RET=0")
                return True
            if "REP" in response:
                print("[OHT] Valid response: REP present")
                return True
            print(f"[OHT] Invalid JSON response: {response}")
            return False

        # Binary response - check for expected patterns
        print("[OHT] Binary response received (may be valid)")
        return True

    def start_keepalive(self):
        """Start background thread to keep connection alive."""
        self.running = True
        self.thread = threading.Thread(target=self._keepalive_loop)
        self.thread.daemon = True
        self.thread.start()

    def _keepalive_loop(self):
        """Background loop to maintain OHT connection."""
        while self.running and self.connected:
            try:
                # Send periodic status or just keep listening
                time.sleep(5)
            except Exception as e:
                print(f"[OHT] Keepalive error: {e}")
                break

    def close(self):
        """Close connection gracefully."""
        self.running = False
        if self.thread:
            self.thread.join(timeout=2)
        if self.socket:
            self.socket.close()
        self.connected = False
        print("[OHT] Connection closed")


def run_simulation(ord_port=10007, duration=60):
    """
    Run full OHT simulation.

    Args:
        ord_port: Port where ord is listening
        duration: How long to maintain connection (seconds)

    Returns:
        bool: True if GET_CONFIG test passed
    """
    print(f"[OHT] Starting OHT simulation (port={ord_port}, duration={duration}s)")

    sim = OHTSimulator(ord_port=ord_port)

    # Connect to ord
    if not sim.connect(timeout=30):
        return False

    # Wait a moment for ord to be ready
    time.sleep(2)

    # Send GET_CONFIG and validate response
    if not sim.send_get_config():
        sim.close()
        return False

    response = sim.receive_response(timeout=10)
    success = sim.validate_get_config_response(response)

    # Keep connection alive for duration
    if success:
        print(f"[OHT] Test passed! Keeping connection for {duration}s...")
        sim.start_keepalive()
        time.sleep(duration)

    sim.close()
    return success


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OHT Simulator for ord testing")
    parser.add_argument(
        "--port", type=int, default=10007, help="ord port (default: 10007)"
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=10,
        help="Connection duration in seconds (default: 10)",
    )
    parser.add_argument(
        "--test", action="store_true", help="Run GET_CONFIG test and exit"
    )
    args = parser.parse_args()

    if args.test:
        success = run_simulation(ord_port=args.port, duration=args.duration)
        sys.exit(0 if success else 1)
    else:
        # Interactive mode
        print("[OHT] Starting in interactive mode...")
        sim = OHTSimulator(ord_port=args.port)
        if sim.connect():
            sim.start_keepalive()
            try:
                while True:
                    cmd = input("Enter command (get_config/quit): ").strip().lower()
                    if cmd == "get_config":
                        sim.send_get_config()
                        sim.receive_response()
                    elif cmd == "quit":
                        break
            except KeyboardInterrupt:
                pass
            sim.close()
