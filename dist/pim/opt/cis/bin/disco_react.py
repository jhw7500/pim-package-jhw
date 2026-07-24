#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import asyncio
import signal
from scapy.all import AsyncSniffer, UDP, IP, Raw, Ether, sendp  # type: ignore
from scapy.all import get_if_hwaddr, get_if_addr
from typing import Dict, Tuple, Optional
import json
import random
from jsonpath_ng import jsonpath, parse
import netifaces
import yaml
import glob
from fnmatch import fnmatch, fnmatchcase
import re
import os
import ipaddress
import subprocess
import logging
import logging.handlers as handlers
import sys


def is_ipv4_address(addr: str) -> bool:
    try:
        ipaddress.IPv4Address(addr)
        return True
    except ipaddress.AddressValueError:
        return False

def get_jsonexpr_value(fpath, key) :
    if os.path.exists(fpath):
        try:
            with open(fpath, "r") as f :
                jsonconf = json.load(f)
            jsonpath_expr = parse(f"$.{key}")
            matches = jsonpath_expr.find(jsonconf)
            if len(matches) == 0:
                return None
            elif len(matches) == 1:
                return matches[0].value
            else :
                return [match.value for match in matches]
        except:
            return None
    else:
        None

def get_global_ipv4_info(iface: str):
    addrs = netifaces.ifaddresses(iface).get(netifaces.AF_INET, [])
    for a in addrs:
        ip = a.get('addr')
        mask = a.get('netmask')
        if not ip:
            continue
        ipobj = ipaddress.ip_address(ip)
        if ipobj.is_loopback or ipobj.is_link_local:
            continue
        return (ip, mask)

    for a in addrs:
        ip = a.get('addr')
        mask = a.get('netmask')
        if ip and ipaddress.ip_address(ip).is_link_local:
            return (ip, mask)

    return None

class MyLogger(logging.Logger):
    def __init__(self, name, level=logging.NOTSET):
        super().__init__(name, level)

        if not self.hasHandlers():
            console_handler = logging.StreamHandler(sys.stdout)
            console_handler.setLevel(logging.DEBUG)

            formatter = logging.Formatter('[%(asctime)s] [%(levelname)s] %(message)s')
            console_handler.setFormatter(formatter)
            self.addHandler(console_handler)

            syslog_handler = handlers.SysLogHandler(address='/dev/log', facility=handlers.SysLogHandler.LOG_LOCAL2)
            syslog_handler.setLevel(logging.INFO)
            formatter = logging.Formatter('%(name)s %(message)s')
            syslog_handler.setFormatter(formatter)
            self.addHandler(syslog_handler)

class UdpBroadcastResponder(object):
    def __init__(self, iface, port, loop=None):
        if iface == "eth0":
            self.net_node = "ETH0"
        elif iface == "eth1":
            self.net_node = "ETH1"
        elif iface == "wlp1s0":
            self.net_node = "WLAN0"
        elif iface == "wlan0":
            self.net_node = "WLAN0"
        self.iface = iface
        self.port = int(port)
        self.loop = loop or asyncio.get_event_loop()
        self.mac = get_if_hwaddr(iface)

        self.model=""
        self.fwver=""
        try :
            model_name = get_jsonexpr_value("/etc/cts/model_info.json","model_name")
            self.model = model_name.replace('-', '_').upper()
            if model_name and model_name[-1].isdigit() :
                self.fwver = os.popen("dpkg -l pim-mp | grep 'pim-mp' | awk '{print $3}'").readline().rstrip('\n')
            else :
                self.fwver = os.popen("dpkg -l cis | grep 'cis' | awk '{print $3}'").readline().rstrip('\n')
        except :
            pass

        self._sniffer = None
        self._recv_q = asyncio.Queue()
        self._worker = None
        self._running = False

    async def start(self):
        if self._running:
            return
        self._running = True

        self._worker = self.loop.create_task(self._do_work())
        bpf = "udp and dst port {} and broadcast".format(self.port)
        self._sniffer = AsyncSniffer(
            iface=self.iface,
            filter=bpf,
            prn=self._on_packet,
            store=False,
        )
        self._sniffer.start()

    async def stop(self):
        if not self._running:
            return
        self._running = False

        if self._sniffer:
            try:
                self._sniffer.stop()
            finally:
                self._sniffer = None

        await self._recv_q.put(None)
        await asyncio.gather(self._worker, return_exceptions=True)

    def send(self, payload, meta):
        iface_info = get_global_ipv4_info(self.iface)
        if not iface_info:
            logger.warning(f"{iface} No IPv4 address")
            return
        if_addr, _ = iface_info
        eth_frame = Ether(dst=meta["src_mac"], src=self.mac) / IP(dst=meta["src_ip"],src=if_addr) / UDP(dport=meta["src_port"],sport=self.port) / payload
        sendp(eth_frame, iface=self.iface, count=1, inter=0, verbose=False)

    # ---------- internal ----------
    def _on_packet(self, pkt):
        try:
            if UDP in pkt and Raw in pkt:
                payload = bytes(pkt[Raw].load)
                msg = json.loads(payload.decode("utf-8"))
                meta = {
                    "src_mac": pkt[Ether].src.upper(),
                    "dst_mac": pkt[Ether].dst.upper(),
                    "src_ip": pkt[IP].src,
                    "src_port": pkt[UDP].sport,
                    "dst_ip": pkt[IP].dst,
                    "dst_port": pkt[UDP].dport,
                    "ifname": self.iface,
                }
                self.loop.call_soon_threadsafe(
                    self._recv_q.put_nowait, (msg, meta)
                )
        except Exception:
            pass

    async def _do_work(self):
        while True:
            item = await self._recv_q.get()
            if item is None:
                self._recv_q.task_done()
                break
            req, meta = item
            try:
                msg_type=req.get("msg",None)
                if not msg_type in {"DISCOVER_REQ", "CONFIG_SET_REQ"}:
                    continue
                src_ip = meta["src_ip"]
                src_port= meta["src_port"]
                logger.debug(f"[RECV] {self.iface} {meta['src_ip']}:{meta['src_port']}, req:{req}")
                
                if msg_type == "DISCOVER_REQ" :
                    response = self.discover_req(req)
                    if response:
                        await asyncio.sleep(random.uniform(5, 150) / 1000.0)
                        resp_payload = json.dumps(response).encode("utf-8")
                        self.send(resp_payload, meta)
                        logger.debug(f"[SENT] {self.iface} {src_ip}:{src_port}, rsp:{response}")
                elif msg_type == "CONFIG_SET_REQ":
                    response = self.config_set_req(req)
                    if response:
                        resp_payload = json.dumps(response).encode("utf-8")
                        self.send(resp_payload, meta)
                        logger.debug(f"[SENT] {self.iface} {src_ip}:{src_port}, rsp:{response}")
                        self.undate_new_ip(req['ip'])
            finally:
                self._recv_q.task_done()

    def discover_req(self,req):
        if "filter" in req:
            if "mac" in req["filter"]:
                req_mac = str(req["filter"]["mac"]).lower()
                if self.mac != req_mac:
                    return None
            if "model" in req["filter"]:
                if isinstance(req["filter"]["model"], str) :
                    patterns = [req["filter"]["model"]]
                elif isinstance(req["filter"]["model"], list) :
                    patterns = req["filter"]["model"]
                else :
                    return None
                is_pass = True
                for pattern in patterns :
                    if fnmatchcase(self.model, pattern):
                        is_pass = False
                        break
                if is_pass:
                    return None
        ip = self.get_interface_info(self.iface)
        extra_info = self.get_extra_info()
        return {
            "msg": "DISCOVER_RSP",
            "model": self.model,
            "fw_ver": self.fwver,
            "mac": self.mac,
            "ip": ip,
            "extra_info": extra_info
        }

    def config_set_req(self,req):
        try:
            if "target" not in req:
                raise KeyError(f"Missing required key: target")
            req_target = str(req["target"]).lower()
            if self.mac != req_target:
                return None
            
            if "ip" not in req:
                raise KeyError(f"Missing required key: ip")
            
            new_ip = req["ip"]
            if "mode" not in new_ip:
                raise KeyError(f"Missing required key: mode")
            mode = new_ip["mode"]
            if not isinstance(mode, str) :
                raise TypeError(f"Invalid type for key: mode, got {type(mode)}")

            if mode == "STATIC" :
                if "addr" in new_ip:
                    if (not isinstance(new_ip["addr"], str)) or \
                       (not is_ipv4_address(new_ip["addr"])) :
                        raise ValueError(f"Invalid value for key: addr, got {new_ip['addr']}")
                else :
                    raise KeyError(f"Missing required key: addr")

                if "netmask" in new_ip:
                    if (not isinstance(new_ip["netmask"], str)) or \
                       (not is_ipv4_address(new_ip["netmask"])) :
                        raise ValueError(f"Invalid value for key: netmask, got {new_ip['netmask']}")
                else :
                    raise KeyError(f"Missing required key: netmask")
                
                if "gw" in new_ip:
                    if new_ip["gw"] != "" :
                        if (not isinstance(new_ip["gw"], str)) or \
                        (not is_ipv4_address(new_ip["gw"])) :
                            raise ValueError(f"Invalid value for key: gw, got {new_ip['gw']}")
            elif mode != "DHCP" :
                raise ValueError(f"Invalid value for key: mode, got {mode}")
            return {
                "msg": "CONFIG_SET_ACK",
                "target": self.mac,
                "ip": new_ip
            }
        except Exception as e:
            logger.warning(f"{self.iface} config_set_req Error: {e}")
        return None

    def undate_new_ip(self,new_ip):
        try:
            conf_list = glob.glob(r"/root/shared_v/edgeconf_*.json")
            if len(conf_list) != 1:
                logger.warning(f"{self.iface} Invalid conf_path: {conf_list}")
                return False
            conf_path = conf_list[0]
            edgeconf = {}
            with open(conf_path) as json_file:
                edgeconf = json.load(json_file)
            prev_json_str = json.dumps(edgeconf, indent=3)

            mode = new_ip["mode"]
            if mode == "STATIC" :
                edgeconf["NETWORK"][self.net_node]["method"] = "static"
                if "addr" in new_ip:
                    edgeconf["NETWORK"][self.net_node]["address"] = new_ip["addr"]
                if "netmask" in new_ip:
                    edgeconf["NETWORK"][self.net_node]["netmask"] = new_ip["netmask"]
                if "gw" in new_ip:
                    edgeconf["NETWORK"][self.net_node]["gateway"] = new_ip["gw"]
            elif mode == "DHCP" :
                edgeconf["NETWORK"][self.net_node]["method"] = "DHCP"

            new_json_str = json.dumps(edgeconf, indent=3)
            if prev_json_str != new_json_str :
                logger.info(f"{self.iface} do new_ip: {new_ip}")
                with open(conf_path, 'w') as f:
                    json_string = json.dump(edgeconf, f, indent=3)
                subprocess.run("python3 /opt/cis/bin/update_network.py",shell=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True)
                ip = self.get_interface_info(self.iface)
                logger.info(f"{self.iface} done ip: {ip}")
            return True
        except Exception as e:
            logger.warning(f"{self.iface} undate_new_ip Error: {e}")
        return False

    @staticmethod
    def get_interface_info(iface):
        info = {'mode': None, 'addr': "", 'netmask': "", 'gw': ""}
        yaml_path = f"/etc/netplan/{iface}.yaml"
        try:
            with open(yaml_path, 'r') as f:
                data = yaml.safe_load(f)
            if iface == 'eth0' or iface == 'eth1':
                ethernets = data.get('network', {}).get('ethernets', {})
                iface_conf = ethernets.get(iface, {})
                dhcp4 = iface_conf.get('dhcp4')
                info['mode'] = "DHCP" if dhcp4 else "STATIC"
            else :
                ethernets = data.get('network', {}).get('wifis', {})
                iface_conf = ethernets.get(iface, {})
                dhcp4 = iface_conf.get('dhcp4')
                info['mode'] = "DHCP" if dhcp4 else "STATIC"

            iface_info = get_global_ipv4_info(iface)
            if iface_info:
                addr, mask = iface_info
                info['addr'] = addr
                info['netmask'] = mask
            gateways = netifaces.gateways()
            default_gw = gateways.get('default', {}).get(netifaces.AF_INET)
            if default_gw and default_gw[1] == iface:
                info['gw'] = default_gw[0]

        except Exception as e:
            logger.warning(f"{iface} get_interface_info Error: {e}")

        return info

    @staticmethod
    def get_extra_info():
        extra_info = {'device_id': None, 'vhl_name': None, 'floor': None, 'line': None}
        try:
            conf_list = glob.glob(r"/root/shared_v/edgeconf_*.json")
            if len(conf_list) == 1:
                extra_info['device_id'] = get_jsonexpr_value(conf_list[0],"device_id") or ""
                extra_info['vhl_name'] = get_jsonexpr_value(conf_list[0],"VHL_CAM.vhl_name") or ""
                extra_info['floor'] = get_jsonexpr_value(conf_list[0],"VHL_CAM.floor") or ""
                extra_info['line'] = get_jsonexpr_value(conf_list[0],"VHL_CAM.line") or ""

            pim_manager_path = "/root/shared_v/pim_gate/pim_manager.json"
            if os.path.exists(pim_manager_path):
                extra_info['pim_group'] = get_jsonexpr_value(pim_manager_path, "base.id_conf.group") or ""
                extra_info['pim_id'] = get_jsonexpr_value(pim_manager_path, "base.id_conf.pim_id") or ""
        except Exception as e:
            logger.warning(f"get_extra_info Error: {e}")
        return extra_info

def main():
    logging.setLoggerClass(MyLogger)
    global logger
    logger = logging.getLogger("disco_react")
    logger.setLevel(logging.DEBUG)

    loop = asyncio.get_event_loop()
    ifaces = [ "eth0", "eth1", "wlp1s0" ]
    port = 15353

    responderes = []
    for iface in ifaces :
        responderes.append( UdpBroadcastResponder(
            iface, port, loop=loop
        ))

    stop_event = asyncio.Event()

    def _ask_stop(*_):
        try:
            stop_event.set()
        except Exception:
            pass

    try:
        loop.add_signal_handler(signal.SIGINT, _ask_stop)
        loop.add_signal_handler(signal.SIGTERM, _ask_stop)
    except NotImplementedError:
        pass

    async def runner():
        for responder in responderes:
            await responder.start()
            logger.info("[RUNNING] iface={} filter='udp and dst port {} and broadcast'".format(responder.iface, port))
        try:
            await stop_event.wait()
        except asyncio.CancelledError:
            pass
        for responder in responderes:
            await responder.stop()
        logger.info("[STOPPED]")

    try:
        loop.run_until_complete(runner())
    except KeyboardInterrupt:
        for responder in responderes:
            loop.run_until_complete(responder.stop())
    finally:
        pending = asyncio.Task.all_tasks(loop=loop)
        for t in pending:
            t.cancel()
        try:
            loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
        except Exception:
            pass
        loop.close()

if __name__ == "__main__":
    main()
