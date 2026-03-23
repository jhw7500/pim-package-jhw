#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os
import sys
import select
import time
import subprocess
import logging
import argparse
import json
import glob
import re
from typing import Callable, Dict, List, Mapping, Optional, Tuple, TypedDict, cast
from datetime import datetime

# Constants & Paths
LOG_KEY = "GARD"
BG_FLAG_FILE = "/tmp/bg_chk_flag.bin"
GUARDIAN_STATE_FILE = "/tmp/pim_guardian_state.json"
RECOVERY_REQ_FILE = "/tmp/recover_req_init_cam"
EDGE_CONF_DIR = "/root/shared_v"
ORD_CONF_PATH = "/root/shared_v/ord_vcm_conf.json"
EXT_CSD_PATH = "/sys/kernel/debug/mmc2/mmc2:0001/ext_csd"
THERMAL_ZONE0 = "/sys/devices/virtual/thermal/thermal_zone0/temp"
THERMAL_ZONE1 = "/sys/devices/virtual/thermal/thermal_zone1/temp"
CPU_FREQ_BASE = "/sys/devices/system/cpu/cpu{}/cpufreq/cpuinfo_cur_freq"
MCP_TRUST_TOOL = "/opt/pim/bin/mcp_trust_test"

TMP_BG_CAM_ERR_STREAK = "/tmp/bg_cam_err_streak"
TMP_CAM_STATE_JSON = "/tmp/cam_state.json"
TMP_PART_STATE = "/tmp/chk_cam_operate.part_state"
TMP_CHK_MMC_VAR = "/tmp/chk_mmc_var"
TMP_ERR_SDCARD_LOG = "/tmp/err_sdcard.log"
TMP_FILE_CHECK = "/tmp/file_check"
TMP_START_DELAY = "/tmp/pim_cam_start_delay"
TMP_START_TS = "/tmp/pim_cam_start_ts"
TMP_VHL_CACHE = "/tmp/pim_vhl_name.cache"
TMP_VHL_CACHE_SRC = "/tmp/pim_vhl_name.cache.src"
TMP_SESSION_DEBUG_LOG = "/tmp/session_debug.log"
TMP_START_VIDEO_TIME_CHK = "/tmp/start_video_time_chk"
TMP_START_VIDEO_TIME_CPY = "/tmp/start_video_time_cpy"
SESSION_VIDEO_DONE_GLOB = "/tmp/session_*.video_done"
SESSION_SRT_DONE_GLOB = "/tmp/session_*.srt_done"

TMP_RECENT_ERROR_MAX_AGE_SEC = 180
TMP_RECENT_ERROR_LIST_MAX_ITEMS = 5
TMP_ERROR_FLAG_FILES: List[Tuple[str, str]] = [
    ("/tmp/err_sdcard.log", "SD"),
    ("/tmp/err_wifi.log", "WiFi"),
    ("/tmp/err_cpu_temp.log", "CPU_TEMP"),
    ("/tmp/err_voltage.log", "VOLTAGE"),
    ("/tmp/err_cam0.log", "CAM0"),
    ("/tmp/err_cam1.log", "CAM1"),
    ("/tmp/err_cam2.log", "CAM2"),
    ("/tmp/err_cam3.log", "CAM3"),
]

# Default Thresholds
MAX_CPU_TEMP = 85
TEMP_WARN_THRESHOLD = 80
TEMP_WARN_CLEAR_THRESHOLD = 75
TEMP_WARN_LOG_PERIOD_SEC = 30
TMP_SYNC_WARN_CONSECUTIVE = 3
TMP_SYNC_WARN_LOG_PERIOD_SEC = 30
RAM_DELTA_WARN_THRESHOLD_KBPS = 16384.0
RAM_DELTA_WARN_CLEAR_THRESHOLD_KBPS = 8192.0
RAM_DELTA_WARN_LOG_PERIOD_SEC = 30
STARTUP_GRACE_EXTRA_SEC = 10
VOLT_MIN = 20.4
VOLT_MAX = 27.6
DISK_LIMIT_PCT = 95
NUM_CORES = 4

GUARD_BIT_CAM_MISMATCH = 1 << 8
GUARD_BIT_HB_FROZEN = 1 << 9
GUARD_BIT_SD_RO = 1 << 10
GUARD_BIT_CPU_HOT = 1 << 11
GUARD_BIT_VOLT_ERR = 1 << 12

RECOVERY_PROMPT_TIMEOUT_SEC = 30
SD_DEV_PARTITION = "/dev/mmcblk1p1"
SD_MOUNT_PATH = "/mnt/sd_cam"
SD_MOUNT_SERVICE = "sd-mount"
FSCK_TOOLS: Dict[str, List[str]] = {
    "ext4": ["fsck.ext4", "-y"],
    "ext3": ["fsck.ext3", "-y"],
    "ext2": ["fsck.ext2", "-y"],
    "vfat": ["fsck.vfat", "-a"],
    "exfat": ["fsck.exfat"],
}
BIN_DIR = "/opt/pim/bin"

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(LOG_KEY)


class IOMetric(TypedDict):
    rk: float
    wk: float
    util: float


class DiskUsageInfo(TypedDict):
    mounted: bool
    mode: str
    usage: Optional[float]
    size: str
    total_bytes: int
    used_bytes: int


class AppProcInfo(TypedDict):
    cpu: str
    mem: str
    up: str


def syslog(level: str, msg: str) -> None:
    cmd = f"logger -p local0.{level} '[{LOG_KEY}] {msg}'"
    _ = subprocess.run(cmd, shell=True)


class PIMHealthGuardian:
    def __init__(self, args: argparse.Namespace):
        self.args: argparse.Namespace = args
        self.conf: Dict[str, object] = self._load_all_configs()
        interval_raw = getattr(args, "interval", 5)
        self.interval: int = interval_raw if isinstance(interval_raw, int) else 5

        error_window_raw = getattr(
            args, "error_window_sec", TMP_RECENT_ERROR_MAX_AGE_SEC
        )
        if isinstance(error_window_raw, int):
            self.recent_error_max_age_sec: int = max(0, error_window_raw)
        else:
            self.recent_error_max_age_sec = TMP_RECENT_ERROR_MAX_AGE_SEC

        error_list_max_raw = getattr(
            args, "error_list_max", TMP_RECENT_ERROR_LIST_MAX_ITEMS
        )
        if isinstance(error_list_max_raw, int):
            self.recent_error_list_max_items: int = max(1, error_list_max_raw)
        else:
            self.recent_error_list_max_items = TMP_RECENT_ERROR_LIST_MAX_ITEMS

        self.recovery_enabled: bool = bool(getattr(args, "recovery", False))
        self.cam_en_bitmask: int = self._get_cam_bitmask()
        self.expected_cam_count: int = bin(self.cam_en_bitmask).count("1")
        self.prev_io_stats: Dict[str, Tuple[int, int, int, float]] = (
            self._get_detailed_io()
        )
        self.prev_net_stats: Dict[str, Tuple[int, int, float]] = (
            self._get_net_dev_stats()
        )
        self.prev_cpu_stat: Optional[Tuple[int, int]] = self._read_cpu_stat()
        self.error_count: int = 0
        self.wifi_iface: str = self._detect_wifi_iface()

        self.peak_temp: int = 0
        self.min_volt: float = 100.0
        self.max_cpu: float = 0.0
        self.start_time: float = time.time()
        self.tmp_sync_false_streak: int = 0
        self.tmp_sync_warn_active: bool = False
        self.tmp_sync_warn_since: float = 0.0
        self.tmp_sync_last_warn_ts: float = 0.0
        self.temp_warn_active: bool = False
        self.temp_warn_since: float = 0.0
        self.temp_warn_peak: int = 0
        self.temp_warn_last_log_ts: float = 0.0
        self.ram_delta_warn_active: bool = False
        self.ram_delta_warn_since: float = 0.0
        self.ram_delta_warn_peak: float = 0.0
        self.ram_delta_warn_last_log_ts: float = 0.0
        self.prev_tmp_used_bytes: Optional[int] = None
        self.prev_tmp_ts: Optional[float] = None

        self._recovery_skipped: Dict[str, bool] = {}
        self._recovery_prev_anomaly: Dict[str, bool] = {}

    # ── Interactive Recovery ───────────────────────────────────────────

    def _prompt_recovery(
        self,
        event_key: str,
        message: str,
        action_fn: Callable[[], bool],
    ) -> bool:
        is_anomaly_now = True
        was_anomaly_before = self._recovery_prev_anomaly.get(event_key, False)
        self._recovery_prev_anomaly[event_key] = is_anomaly_now

        if not was_anomaly_before:
            self._recovery_skipped[event_key] = False

        if self._recovery_skipped.get(event_key, False):
            return False

        print("\n========================================")
        print(f"[RECOVERY] {message}")
        sys.stdout.write(f"(y/n, {RECOVERY_PROMPT_TIMEOUT_SEC}s timeout): ")
        sys.stdout.flush()

        ready, _, _ = select.select([sys.stdin], [], [], RECOVERY_PROMPT_TIMEOUT_SEC)
        if ready:
            answer = sys.stdin.readline().strip().lower()
        else:
            answer = ""
            print("")

        if answer == "y":
            print("")
            ok = action_fn()
            if ok:
                print(f"[RECOVERY] === {event_key} recovery completed successfully ===")
            else:
                print(
                    f"[RECOVERY] === {event_key} recovery FAILED. Manual intervention may be required. ==="
                )
            print("========================================\n")
            return ok
        else:
            if not ready:
                print(f"[RECOVERY] Timeout. Skipping {event_key} recovery.")
            else:
                print(f"[RECOVERY] Skipped {event_key} recovery.")
            print("========================================\n")
            self._recovery_skipped[event_key] = True
            return False

    def _run_recovery_step(
        self,
        step: int,
        total: int,
        desc: str,
        cmd: List[str],
        allow_fail: bool = False,
    ) -> bool:
        sys.stdout.write(f"[RECOVERY] [{step}/{total}] {desc}...")
        sys.stdout.flush()
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            if result.returncode == 0 or allow_fail:
                print(
                    f" OK"
                    if result.returncode == 0
                    else f" WARN (exit code {result.returncode})"
                )
                if result.stdout.strip():
                    for line in result.stdout.strip().splitlines():
                        print(f"  {line}")
                return True
            else:
                print(f" FAILED (exit code {result.returncode})")
                if result.stderr.strip():
                    for line in result.stderr.strip().splitlines():
                        print(f"  {line}")
                if result.stdout.strip():
                    for line in result.stdout.strip().splitlines():
                        print(f"  {line}")
                return False
        except subprocess.TimeoutExpired:
            print(" FAILED (timeout)")
            return False
        except Exception as e:
            print(f" FAILED ({e})")
            return False

    def _detect_sd_fstype(self) -> Optional[str]:
        for cmd in (
            ["blkid", "-o", "value", "-s", "TYPE", SD_DEV_PARTITION],
            ["lsblk", "-no", "FSTYPE", SD_DEV_PARTITION],
        ):
            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                fs = result.stdout.strip()
                if fs:
                    return fs
            except:
                pass
        return None

    def _recover_sd_ro(self) -> bool:
        total = 7
        step = 0

        step += 1
        if not self._run_recovery_step(
            step,
            total,
            "Stopping camera pipeline",
            [f"{BIN_DIR}/kill_test.sh"],
        ):
            return False

        step += 1
        self._run_recovery_step(
            step,
            total,
            f"Stopping {SD_MOUNT_SERVICE} service",
            ["systemctl", "stop", SD_MOUNT_SERVICE],
            allow_fail=True,
        )

        step += 1
        if not self._run_recovery_step(
            step,
            total,
            f"Unmounting {SD_MOUNT_PATH}",
            ["umount", SD_MOUNT_PATH],
        ):
            self._run_recovery_step(
                step,
                total,
                f"Force unmounting {SD_MOUNT_PATH}",
                ["umount", "-f", SD_MOUNT_PATH],
            )

        step += 1
        fs_type = self._detect_sd_fstype()
        if fs_type:
            print(f"[RECOVERY] [{step}/{total}] Detected filesystem: {fs_type}")
        else:
            print(
                f"[RECOVERY] [{step}/{total}] Filesystem type: UNKNOWN (blkid/lsblk failed)"
            )
            print(f"[RECOVERY] Cannot run fsck without knowing filesystem type.")
            print(
                f"[RECOVERY] SD card may be physically damaged or partition table corrupted."
            )
            self._run_recovery_step(
                total - 1,
                total,
                f"Starting {SD_MOUNT_SERVICE} service",
                ["systemctl", "start", SD_MOUNT_SERVICE],
                allow_fail=True,
            )
            self._run_recovery_step(
                total,
                total,
                "Starting camera pipeline",
                [f"{BIN_DIR}/start_cam.sh"],
                allow_fail=True,
            )
            return False

        step += 1
        fsck_cmd = FSCK_TOOLS.get(fs_type, ["fsck", "-y"])
        full_cmd = list(fsck_cmd) + [SD_DEV_PARTITION]
        fsck_timeout = getattr(self.args, "fsck_timeout", 1800)
        timeout_str = "no limit" if fsck_timeout == 0 else f"{fsck_timeout}s"
        print(f"[RECOVERY] [{step}/{total}] Running {' '.join(full_cmd)} (timeout {timeout_str})")
        sys.stdout.flush()
        try:
            proc = subprocess.Popen(
                full_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
            )
            start_ts = time.monotonic()
            last_heartbeat = start_ts
            buf = b""
            while True:
                elapsed = int(time.monotonic() - start_ts)
                if fsck_timeout > 0 and elapsed >= fsck_timeout:
                    proc.kill()
                    proc.wait()
                    raise subprocess.TimeoutExpired(full_cmd, fsck_timeout)
                ready, _, _ = select.select([proc.stdout], [], [], 1.0)
                if ready:
                    chunk = os.read(proc.stdout.fileno(), 4096)
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        text = line.decode("utf-8", errors="replace").rstrip()
                        if text:
                            print(f"  {text}")
                            sys.stdout.flush()
                    last_heartbeat = time.monotonic()
                else:
                    if proc.poll() is not None:
                        break
                    now = time.monotonic()
                    if now - last_heartbeat >= 10:
                        print(f"[RECOVERY] [{step}/{total}] fsck in progress... ({elapsed}s elapsed)")
                        sys.stdout.flush()
                        last_heartbeat = now
            if buf.strip():
                print(f"  {buf.decode('utf-8', errors='replace').rstrip()}")
            returncode = proc.wait()
            elapsed = int(time.monotonic() - start_ts)
            if returncode in (0, 1):
                print(f"[RECOVERY] [{step}/{total}] Filesystem check... OK ({elapsed}s)")
                fsck_ok = True
            else:
                print(
                    f"[RECOVERY] [{step}/{total}] Filesystem check... FAILED (exit code {returncode}, {elapsed}s)"
                )
                fsck_ok = False
        except subprocess.TimeoutExpired:
            print(f"[RECOVERY] [{step}/{total}] Filesystem check... FAILED (timeout {fsck_timeout}s)")
            fsck_ok = False
        except Exception as e:
            print(f"[RECOVERY] [{step}/{total}] Filesystem check... FAILED ({e})")
            fsck_ok = False

        # Signal automnt_sd_for_emmc_boot.sh to exit RO fallback state
        if fsck_ok:
            try:
                with open("/tmp/sd_ro_recovered", "w") as f:
                    f.write("1\n")
                print(f"[RECOVERY] [{step}/{total}] RO recovery flag set for automnt")
            except Exception as e:
                print(f"[RECOVERY] [{step}/{total}] Failed to set recovery flag: {e}")

        step += 1
        self._run_recovery_step(
            step,
            total,
            f"Starting {SD_MOUNT_SERVICE} service",
            ["systemctl", "start", SD_MOUNT_SERVICE],
            allow_fail=True,
        )

        step += 1
        self._run_recovery_step(
            step,
            total,
            "Starting camera pipeline",
            [f"{BIN_DIR}/start_cam.sh"],
            allow_fail=True,
        )

        return fsck_ok

    def _recover_cam_disconnect(self) -> bool:
        total = 1
        return self._run_recovery_step(
            1,
            total,
            "Running init_cam to reload driver",
            [f"{BIN_DIR}/init_cam.sh"],
        )

    def _recover_hb_frozen(self) -> bool:
        total = 2
        step = 0

        step += 1
        if not self._run_recovery_step(
            step,
            total,
            "Stopping camera pipeline",
            [f"{BIN_DIR}/kill_test.sh"],
        ):
            return False

        step += 1
        return self._run_recovery_step(
            step,
            total,
            "Starting camera pipeline",
            [f"{BIN_DIR}/start_cam.sh"],
        )

    def _clear_recovery_state(self, event_key: str) -> None:
        if self._recovery_prev_anomaly.get(event_key, False):
            self._recovery_prev_anomaly[event_key] = False
            self._recovery_skipped[event_key] = False

    # ── Utility ────────────────────────────────────────────────────────

    def _safe_read_int_file(self, path: str, default: int = 0) -> int:
        try:
            with open(path, "r") as f:
                return int(f.read().strip())
        except:
            return default

    def _safe_read_text_file(self, path: str, default: str = "") -> str:
        try:
            with open(path, "r") as f:
                return f.read().strip()
        except:
            return default

    def _safe_file_mtime_age(self, path: str) -> Optional[int]:
        try:
            return int(time.time() - os.path.getmtime(path))
        except:
            return None

    def _count_glob_files(self, pattern: str) -> int:
        try:
            return len(glob.glob(pattern))
        except:
            return 0

    def _safe_tail_line(
        self, path: str, max_bytes: int = 2048, max_len: int = 120
    ) -> str:
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as f:
                if size > max_bytes:
                    _ = f.seek(-max_bytes, os.SEEK_END)
                data = f.read().decode("utf-8", errors="replace")
            lines = [ln for ln in data.splitlines() if ln.strip()]
            if not lines:
                return ""
            last = lines[-1].strip()
            if len(last) > max_len:
                return last[:max_len] + "..."
            return last
        except:
            return ""

    def _safe_tail_lines(
        self,
        path: str,
        max_bytes: int = 8192,
        max_lines: int = 5,
        max_len: int = 0,
    ) -> List[str]:
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as f:
                if size > max_bytes:
                    _ = f.seek(-max_bytes, os.SEEK_END)
                data = f.read().decode("utf-8", errors="replace")
            lines = [ln.strip() for ln in data.splitlines() if ln.strip()]
            if len(lines) > max_lines:
                lines = lines[-max_lines:]
            out: List[str] = []
            for line in lines:
                if max_len > 0 and len(line) > max_len:
                    out.append(line[:max_len] + "...")
                else:
                    out.append(line)
            return out
        except:
            return []

    def _parse_tmp_error_line(self, line: str) -> Tuple[Optional[float], str, str]:
        raw = line.strip()
        m = re.match(
            r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:,(\d{1,3}))?\s*(.*)$",
            raw,
        )
        if not m:
            return None, "", raw

        dt_base = m.group(1)
        msec = m.group(2) or "000"
        msg = (m.group(3) or "").strip()
        msec = msec.ljust(3, "0")[:3]
        ts_text = f"{dt_base},{msec}"
        try:
            dt_obj = datetime.strptime(ts_text, "%Y-%m-%d %H:%M:%S,%f")
            return dt_obj.timestamp(), ts_text, msg
        except:
            return None, ts_text, msg if msg else raw

    def _parse_journal_error_line(self, line: str) -> Tuple[Optional[float], str]:
        raw = line.strip()
        m = re.match(r"^([A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+", raw)
        if not m:
            return None, raw
        ts_prefix = m.group(1)
        now_ts = time.time()
        now_dt = datetime.fromtimestamp(now_ts)
        try:
            dt_obj = datetime.strptime(
                f"{now_dt.year} {ts_prefix}", "%Y %b %d %H:%M:%S"
            )
            if dt_obj.timestamp() > now_ts + 86400:
                dt_obj = dt_obj.replace(year=dt_obj.year - 1)
            return dt_obj.timestamp(), raw
        except:
            return None, raw

    def _to_int(self, value: object, default: int) -> int:
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            return int(value)
        if isinstance(value, str):
            try:
                return int(value)
            except:
                return default
        try:
            return int(str(value))
        except:
            return default

    def _conf_str(self, key: str, default: str) -> str:
        value = self.conf.get(key, default)
        return value if isinstance(value, str) else default

    def _as_dict(self, value: object) -> Dict[str, object]:
        if not isinstance(value, dict):
            return {}
        value_dict = cast(Dict[object, object], value)
        out: Dict[str, object] = {}
        for k, v in value_dict.items():
            if isinstance(k, str):
                out[k] = v
        return out

    def _read_cam_state(self) -> Tuple[str, int]:
        state = "unknown"
        streak = 0
        try:
            if os.path.exists(TMP_CAM_STATE_JSON):
                with open(TMP_CAM_STATE_JSON, "r") as f:
                    data_raw = cast(object, json.load(f))
                data = self._as_dict(data_raw)
                if data:
                    s = data.get("state")
                    if isinstance(s, str) and s:
                        state = s
                    streak = self._to_int(data.get("streak", streak), streak)
        except:
            pass

        shadow_state = self._safe_read_text_file("/tmp/cam_state.state", "")
        if shadow_state:
            state = shadow_state
        shadow_streak_text = self._safe_read_text_file("/tmp/cam_state.streak", "")
        if shadow_streak_text:
            try:
                streak = int(shadow_streak_text)
            except:
                pass

        return state, streak

    def _cam_channels_from_mask(self, mask: int) -> List[str]:
        channels: List[str] = []
        for idx in range(4):
            if mask & (1 << idx):
                channels.append(f"CAM{idx}")
        return channels

    def collect_tmp_signals(self) -> Dict[str, object]:
        bg_streak = self._safe_read_int_file(TMP_BG_CAM_ERR_STREAK, 0)
        file_check_raw = self._safe_read_text_file(TMP_FILE_CHECK, "")
        file_check = file_check_raw if file_check_raw else "EMPTY"
        file_check_age = self._safe_file_mtime_age(TMP_FILE_CHECK)
        chk_mmc_var = self._safe_read_text_file(TMP_CHK_MMC_VAR, "")
        start_ts = self._safe_read_int_file(TMP_START_TS, 0)
        start_delay = self._safe_read_int_file(TMP_START_DELAY, 0)
        err_sdcard_age = self._safe_file_mtime_age(TMP_ERR_SDCARD_LOG)
        cam_state_recording: Dict[str, str] = {
            "start_video_time_actual": "",
            "start_video_time": "",
            "start_video_time_chk": "",
            "start_video_time_cpy": "",
            "start_video_time_vib": "",
        }

        vhl_cache = self._safe_read_text_file(TMP_VHL_CACHE, "")
        vhl_cache_src = self._safe_read_text_file(TMP_VHL_CACHE_SRC, "")
        vhl_cache_name_match = None
        oht_name = self._conf_str("oht_name", "")
        edge_conf_path = self._conf_str("edge_conf_path", "")
        if vhl_cache and oht_name:
            vhl_cache_name_match = vhl_cache == oht_name
        vhl_cache_src_match = None
        if vhl_cache_src and edge_conf_path:
            vhl_cache_src_match = vhl_cache_src == edge_conf_path
        if vhl_cache_name_match is not None and vhl_cache_src_match is not None:
            vhl_cache_match = vhl_cache_name_match and vhl_cache_src_match
        elif vhl_cache_name_match is not None:
            vhl_cache_match = vhl_cache_name_match
        else:
            vhl_cache_match = None

        video_done_cnt = self._count_glob_files(SESSION_VIDEO_DONE_GLOB)
        srt_done_cnt = self._count_glob_files(SESSION_SRT_DONE_GLOB)

        start_time_chk = self._safe_read_text_file(TMP_START_VIDEO_TIME_CHK, "")
        start_time_cpy = self._safe_read_text_file(TMP_START_VIDEO_TIME_CPY, "")
        try:
            if os.path.exists(TMP_CAM_STATE_JSON):
                with open(TMP_CAM_STATE_JSON, "r") as f:
                    cam_state_raw = cast(object, json.load(f))
                cam_state_data = self._as_dict(cam_state_raw)
                if cam_state_data:
                    recording_raw = cam_state_data.get("recording")
                    recording_data = self._as_dict(recording_raw)
                    for key in cam_state_recording:
                        value = recording_data.get(key, "")
                        if isinstance(value, str):
                            cam_state_recording[key] = value
        except:
            pass
        if start_time_chk and start_time_cpy:
            start_time_sync = start_time_chk == start_time_cpy
        else:
            start_time_sync = None

        part_state_lines = 0
        try:
            if os.path.exists(TMP_PART_STATE):
                with open(TMP_PART_STATE, "r") as f:
                    part_state_lines = sum(1 for _ in f)
        except:
            part_state_lines = 0

        session_debug_last = self._safe_tail_line(TMP_SESSION_DEBUG_LOG)

        return {
            "bg_cam_err_streak": bg_streak,
            "file_check": file_check,
            "file_check_age_sec": file_check_age,
            "chk_mmc_var": chk_mmc_var,
            "cam_state_json_exists": os.path.exists(TMP_CAM_STATE_JSON),
            "part_state_lines": part_state_lines,
            "err_sdcard_age_sec": err_sdcard_age,
            "pim_cam_start_ts": start_ts,
            "pim_cam_start_delay": start_delay,
            "vhl_cache": vhl_cache,
            "vhl_cache_src": vhl_cache_src,
            "vhl_cache_name_match": vhl_cache_name_match,
            "vhl_cache_src_match": vhl_cache_src_match,
            "vhl_cache_match": vhl_cache_match,
            "video_done_cnt": video_done_cnt,
            "srt_done_cnt": srt_done_cnt,
            "done_delta": video_done_cnt - srt_done_cnt,
            "start_video_time_chk": start_time_chk,
            "start_video_time_cpy": start_time_cpy,
            "cam_state_recording": cam_state_recording,
            "start_time_sync": start_time_sync,
            "session_debug_last": session_debug_last,
        }

    def _write_guardian_state(self, payload: Mapping[str, object]) -> None:
        tmp = f"{GUARDIAN_STATE_FILE}.tmp.{os.getpid()}"
        try:
            with open(tmp, "w") as f:
                json.dump(payload, f, separators=(",", ":"))
            os.replace(tmp, GUARDIAN_STATE_FILE)
        except:
            try:
                _ = os.unlink(tmp)
            except:
                pass

    def _request_recovery(self, reason: str) -> None:
        if os.path.exists(RECOVERY_REQ_FILE):
            return
        ts = int(time.time())
        try:
            with open(RECOVERY_REQ_FILE, "w") as f:
                _ = f.write(f"{ts} {reason}\n")
        except:
            pass

    def _load_all_configs(self) -> Dict[str, object]:
        conf: Dict[str, object] = {
            "edge": {},
            "ord": {},
            "sd_path": "/mnt/sd_cam",
            "sd_dev": "mmcblk1",
            "emmc_dev": "mmcblk0",
            "v4l_map": {"csi0": 2, "csi1": 3},
            "tmp_path": "/dev/shm",
            "oht_name": "VD3001",
            "edge_conf_path": "",
        }
        try:
            files = sorted(glob.glob(f"{EDGE_CONF_DIR}/edgeconf_*.json"))
            if files:
                conf["edge_conf_path"] = files[-1]
                with open(files[-1], "r") as f:
                    edge_conf_raw = cast(object, json.load(f))
                    edge_conf = self._as_dict(edge_conf_raw)
                    conf["edge"] = edge_conf

                    cam = self._as_dict(edge_conf.get("VHL_CAM", {}))

                    final_path = cam.get("final_path")
                    tmp_path = cam.get("tmp_path")
                    vhl_name = cam.get("vhl_name")
                    if isinstance(final_path, str):
                        conf["sd_path"] = final_path
                    if isinstance(tmp_path, str):
                        conf["tmp_path"] = tmp_path
                    if isinstance(vhl_name, str):
                        conf["oht_name"] = vhl_name

                    v_map = self._as_dict(cam.get("v4l_map", cam.get("device_map", {})))
                    if v_map:
                        v4l_map_raw = self._as_dict(conf.get("v4l_map", {}))
                        v4l_map = {
                            "csi0": self._to_int(
                                v_map.get("csi0_subdev", v_map.get("csi0_video", 2)),
                                self._to_int(v4l_map_raw.get("csi0", 2), 2),
                            ),
                            "csi1": self._to_int(
                                v_map.get("csi1_subdev", v_map.get("csi1_video", 3)),
                                self._to_int(v4l_map_raw.get("csi1", 3), 3),
                            ),
                        }
                        conf["v4l_map"] = v4l_map
            with open("/proc/mounts", "r") as f:
                for line in f:
                    fields = line.split()
                    if len(fields) >= 2 and fields[1] == "/":
                        root_dev = os.path.basename(fields[0])
                        m_root = re.search(r"(mmcblk\d+)", root_dev)
                        if m_root:
                            conf["emmc_dev"] = m_root.group(1)
                    sd_path = conf.get("sd_path", "")
                    if isinstance(sd_path, str) and sd_path in line:
                        m = re.search(r"(mmcblk\d+)", os.path.basename(line.split()[0]))
                        if m:
                            conf["sd_dev"] = m.group(1)
                            break

            if conf["emmc_dev"] == conf["sd_dev"]:
                try:
                    with open("/proc/diskstats", "r") as f:
                        for line in f:
                            p = line.split()
                            if len(p) < 3:
                                continue
                            dev = p[2]
                            if (
                                dev.startswith("mmcblk")
                                and "p" not in dev
                                and dev != conf["sd_dev"]
                            ):
                                conf["emmc_dev"] = dev
                                break
                except:
                    pass

            if os.path.exists(ORD_CONF_PATH):
                with open(ORD_CONF_PATH, "r") as f:
                    ord_conf_raw = cast(object, json.load(f))
                    conf["ord"] = self._as_dict(ord_conf_raw)
        except:
            pass
        return conf

    def _detect_wifi_iface(self) -> str:
        for c in ["wlp1s0", "wlan0"]:
            if os.path.exists(f"/sys/class/net/{c}"):
                return c
        try:
            with open("/proc/net/wireless", "r") as f:
                for line in f:
                    if ":" in line:
                        return line.split(":")[0].strip()
        except:
            pass
        return "wlan0"

    def _get_cam_bitmask(self) -> int:
        edge = self._as_dict(self.conf.get("edge", {}))
        cam = self._as_dict(edge.get("VHL_CAM", {}))
        if not cam:
            return 0

        def _enabled(bus_key: str, ch_key: str) -> int:
            bus = self._as_dict(cam.get(bus_key, {}))
            ch = self._as_dict(bus.get(ch_key, {}))
            return 1 if ch.get("enable") else 0

        ch0 = _enabled("i2c2", "ch0")
        ch1 = _enabled("i2c2", "ch1")
        ch2 = _enabled("i2c1", "ch2")
        ch3 = _enabled("i2c1", "ch3")
        return ch3 << 3 | ch2 << 2 | ch1 << 1 | ch0

    def _get_detailed_io(self) -> Dict[str, Tuple[int, int, int, float]]:
        stats: Dict[str, Tuple[int, int, int, float]] = {}
        try:
            with open("/proc/diskstats", "r") as f:
                for line in f:
                    p = line.split()
                    if len(p) < 13:
                        continue
                    dev = p[2]
                    if "mmcblk" in dev and "p" not in dev:
                        stats[dev] = (int(p[5]), int(p[9]), int(p[12]), time.time())
        except:
            pass
        return stats

    def calculate_io_metrics(self) -> Dict[str, IOMetric]:
        curr_stats = self._get_detailed_io()
        results: Dict[str, IOMetric] = {}
        for dev, curr in curr_stats.items():
            if dev in self.prev_io_stats:
                prev = self.prev_io_stats[dev]
                dt = curr[3] - prev[3]
                if dt > 0:
                    rk = (curr[0] - prev[0]) * 0.5 / dt
                    wk = (curr[1] - prev[1]) * 0.5 / dt
                    util = ((curr[2] - prev[2]) / (dt * 1000.0)) * 100.0
                    results[dev] = {
                        "rk": rk,
                        "wk": wk,
                        "util": max(0.0, min(util, 100.0)),
                    }
        self.prev_io_stats = curr_stats
        return results

    def _get_net_dev_stats(self) -> Dict[str, Tuple[int, int, float]]:
        stats: Dict[str, Tuple[int, int, float]] = {}
        try:
            with open("/proc/net/dev", "r") as f:
                lines = f.readlines()[2:]
                for line in lines:
                    if ":" in line:
                        iface, data = line.split(":")
                        p = data.split()
                        stats[iface.strip()] = (int(p[0]), int(p[8]), time.time())
        except:
            pass
        return stats

    def get_net_throughput(self) -> Dict[str, Tuple[float, float]]:
        curr = self._get_net_dev_stats()
        results: Dict[str, Tuple[float, float]] = {}
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

    def _read_cpu_stat(self) -> Optional[Tuple[int, int]]:
        try:
            with open("/proc/stat", "r") as f:
                line = f.readline().strip()
            parts = line.split()
            if len(parts) < 5 or parts[0] != "cpu":
                return None

            vals = [int(x) for x in parts[1:]]
            user = vals[0]
            nice = vals[1] if len(vals) > 1 else 0
            system = vals[2] if len(vals) > 2 else 0
            idle = vals[3] if len(vals) > 3 else 0
            iowait = vals[4] if len(vals) > 4 else 0
            irq = vals[5] if len(vals) > 5 else 0
            softirq = vals[6] if len(vals) > 6 else 0
            steal = vals[7] if len(vals) > 7 else 0

            idle_all = idle + iowait
            non_idle = user + nice + system + irq + softirq + steal
            total = idle_all + non_idle
            return total, idle_all
        except:
            return None

    def get_total_cpu_usage(self) -> float:
        curr = self._read_cpu_stat()
        if curr is None:
            return 0.0
        if self.prev_cpu_stat is None:
            self.prev_cpu_stat = curr
            return 0.0

        totald = curr[0] - self.prev_cpu_stat[0]
        idled = curr[1] - self.prev_cpu_stat[1]
        self.prev_cpu_stat = curr

        if totald <= 0:
            return 0.0

        usage = (totald - idled) * 100.0 / totald
        return max(0.0, min(usage, 100.0))

    def get_app_info(self) -> Dict[str, AppProcInfo]:
        apps: List[str] = ["gstApp", "ord", "vcm"]
        res: Dict[str, AppProcInfo] = {}
        for app in apps:
            try:
                out = subprocess.check_output(
                    f"ps -C {app} -o %cpu,%mem,etime --no-headers | head -n 1",
                    shell=True,
                ).decode()
                p = out.split()
                if len(p) >= 3:
                    res[app] = {
                        "cpu": f"{float(p[0]):.1f}",
                        "mem": p[1],
                        "up": p[2],
                    }
                else:
                    raise Exception()
            except:
                res[app] = {"cpu": "0.0", "mem": "0.0", "up": "N/A"}
        return res

    def get_pipeline_heartbeat(self) -> Tuple[str, int]:
        tmp_path = self._conf_str("tmp_path", "/dev/shm")
        oht_name = self._conf_str("oht_name", "VD3001")
        pattern = f"{tmp_path}/{oht_name}_*.part"
        files = glob.glob(pattern)
        if not files:
            return "NO_FILES", 0
        mtimes = []
        for f in files:
            try:
                mtimes.append(os.path.getmtime(f))
            except FileNotFoundError:
                continue
        if not mtimes:
            return "NO_FILES", 0
        idle_sec = int(time.time() - max(mtimes))
        return ("OK" if idle_sec < 10 else "FROZEN"), idle_sec

    def check_zombies(self) -> int:
        try:
            return int(
                subprocess.check_output(
                    "ps -ef | grep defunct | grep -v grep | wc -l", shell=True
                )
                .decode()
                .strip()
            )
        except:
            return 0

    def get_net_info(self, iface: str) -> Tuple[str, str]:
        status, extra = "N/A", ""
        state_path = f"/sys/class/net/{iface}/operstate"
        if os.path.exists(state_path):
            try:
                with open(state_path, "r") as f:
                    status = "UP" if f.read().strip() == "up" else "DOWN"
                if iface == self.wifi_iface:
                    with open("/proc/net/wireless", "r") as f:
                        for line in f:
                            if iface in line:
                                p = line.split()
                                extra = f"({p[2].replace('.', '')}/{p[3].replace('.', '')}dBm)"
                                break
            except:
                status = "ERR"
        return status, extra

    def get_disk_usage(self, path: str) -> DiskUsageInfo:
        info: DiskUsageInfo = {
            "mounted": False,
            "mode": "N/A",
            "usage": None,
            "size": "0G",
            "total_bytes": 0,
            "used_bytes": 0,
        }
        try:
            with open("/proc/mounts", "r") as f:
                for line in f:
                    if path in line:
                        p = line.split()
                        info["mounted"] = True
                        info["mode"] = "RO" if "ro" in p[3].split(",") else "RW"
                        break
            if info["mounted"]:
                st = os.statvfs(path)
                total_bytes = st.f_blocks * st.f_frsize
                free_bytes = st.f_bfree * st.f_frsize
                used_bytes = max(total_bytes - free_bytes, 0)
                total = total_bytes / (1024**3)
                free = free_bytes / (1024**3)
                info["usage"] = round((1 - free / total) * 100, 1) if total > 0 else 0.0
                info["size"] = f"{total:.1f}G"
                info["total_bytes"] = int(total_bytes)
                info["used_bytes"] = int(used_bytes)
        except:
            pass
        return info

    def _estimate_tmp_delta_kbps(self, tmp_disk_info: DiskUsageInfo) -> float:
        now = time.time()

        if not tmp_disk_info.get("mounted"):
            self.prev_tmp_used_bytes = None
            self.prev_tmp_ts = now
            return 0.0

        used_bytes = tmp_disk_info["used_bytes"]
        if self.prev_tmp_used_bytes is None or self.prev_tmp_ts is None:
            self.prev_tmp_used_bytes = used_bytes
            self.prev_tmp_ts = now
            return 0.0

        dt = now - self.prev_tmp_ts
        if dt <= 0:
            return 0.0

        delta = used_bytes - self.prev_tmp_used_bytes
        self.prev_tmp_used_bytes = used_bytes
        self.prev_tmp_ts = now

        return delta / 1024.0 / dt

    def get_hw_metrics(self) -> Tuple[float, str, int, int, int, bool]:
        v, v_s = 0.0, "N/A"
        try:
            res = subprocess.check_output(
                f"{MCP_TRUST_TOOL} | grep voltage", shell=True
            ).decode()
            v = float(res.split(":")[1].strip())
            v_s = "OK" if VOLT_MIN <= v <= VOLT_MAX else "ERR"
        except:
            pass
        t0 = -1
        try:
            with open(THERMAL_ZONE0, "r") as f:
                t0 = int(f.read()) // 1000
        except:
            pass
        la, lb = -1, -1
        try:
            if os.path.exists(EXT_CSD_PATH):
                with open(EXT_CSD_PATH, "r") as f:
                    r = f.read().strip()
                    la, lb = int(r[536:538], 16) * 10, int(r[538:540], 16) * 10
        except:
            pass
        try:
            rtc_ok = (
                subprocess.run("hwclock -r", shell=True, capture_output=True).returncode
                == 0
            )
        except:
            rtc_ok = False
        return v, v_s, t0, la, lb, rtc_ok

    def check_cams(self) -> str:
        active_count = 0
        v4l_map = self._as_dict(self.conf.get("v4l_map", {}))

        csi0 = f"/dev/v4l-subdev{self._to_int(v4l_map.get('csi0', 2), 2)}"
        csi1 = f"/dev/v4l-subdev{self._to_int(v4l_map.get('csi1', 3), 3)}"
        checks = [
            (0x01, csi0, "ae_on_ch0"),
            (0x02, csi0, "ae_on_ch1"),
            (0x04, csi1, "ae_on_ch2"),
            (0x08, csi1, "ae_on_ch3"),
        ]
        for bit, node, ctrl in checks:
            if self.cam_en_bitmask & bit:
                res = subprocess.run(
                    f"v4l2-ctl -d {node} --get-ctrl={ctrl}",
                    shell=True,
                    capture_output=True,
                )
                if res.returncode == 0:
                    active_count += 1
        return f"{active_count}/{self.expected_cam_count}"

    def get_recent_error_list(self) -> List[str]:
        now_ts = time.time()
        records: List[Tuple[float, str]] = []

        for path, label in TMP_ERROR_FLAG_FILES:
            age = self._safe_file_mtime_age(path)
            if age is None or age > self.recent_error_max_age_sec:
                continue

            fallback_ts = now_ts - age
            fallback_ts_text = datetime.fromtimestamp(fallback_ts).strftime(
                "%Y-%m-%d %H:%M:%S"
            )
            lines = self._safe_tail_lines(
                path,
                max_lines=self.recent_error_list_max_items,
                max_len=0,
            )
            if not lines:
                lines = ["error flag present"]

            for line in lines:
                parsed_ts, parsed_ts_text, parsed_msg = self._parse_tmp_error_line(line)
                ts_epoch = parsed_ts if parsed_ts is not None else fallback_ts
                ts_text = parsed_ts_text if parsed_ts_text else fallback_ts_text
                msg = parsed_msg if parsed_msg else "error flag present"
                records.append((ts_epoch, f"{ts_text} [{label}] {msg}"))

        try:
            journal_out = (
                subprocess.check_output(
                    "journalctl -n 120 --no-pager | grep -Ei 'error|failed|critical|panic|link loss' | tail -n 20",
                    shell=True,
                )
                .decode(errors="replace")
                .splitlines()
            )
            for line in journal_out:
                if not line.strip():
                    continue
                parsed_ts, raw_line = self._parse_journal_error_line(line)
                ts_epoch = parsed_ts if parsed_ts is not None else 0.0
                records.append((ts_epoch, raw_line.strip()))
        except:
            pass

        if not records:
            return []

        records.sort(key=lambda item: item[0], reverse=True)

        out: List[str] = []
        seen: Dict[str, bool] = {}
        for _ts, text in records:
            if text in seen:
                continue
            seen[text] = True
            out.append(text)
            if len(out) >= self.recent_error_list_max_items:
                break
        return out

    def get_recent_error(self) -> str:
        recent = self.get_recent_error_list()
        if recent:
            return recent[0]
        return "None"

    def _check_tmp_sync_warning(self, sync_state: Optional[bool]) -> None:
        now = time.time()

        if sync_state is False:
            self.tmp_sync_false_streak += 1
        else:
            self.tmp_sync_false_streak = 0

        debounced_lost = self.tmp_sync_false_streak >= TMP_SYNC_WARN_CONSECUTIVE

        if debounced_lost and not self.tmp_sync_warn_active:
            self.tmp_sync_warn_active = True
            self.tmp_sync_warn_since = now
            self.tmp_sync_last_warn_ts = now
            est_sec = self.tmp_sync_false_streak * self.interval
            logger.warning(
                f"         ! [TMP Sync Warning] sync=False for {self.tmp_sync_false_streak} consecutive samples (~{est_sec}s)."
            )
        elif (not debounced_lost) and self.tmp_sync_warn_active:
            duration = int(now - self.tmp_sync_warn_since)
            logger.info(
                f"         ! [TMP Sync Recovered] sync restored after {duration}s."
            )
            self.tmp_sync_warn_active = False
            self.tmp_sync_warn_since = 0.0
            self.tmp_sync_last_warn_ts = 0.0

        if self.tmp_sync_warn_active:
            duration = int(now - self.tmp_sync_warn_since)
            if now - self.tmp_sync_last_warn_ts >= TMP_SYNC_WARN_LOG_PERIOD_SEC:
                self.tmp_sync_last_warn_ts = now
                logger.warning(
                    f"         ! [TMP Sync Warning] still unstable for {duration}s (false_streak={self.tmp_sync_false_streak})."
                )

    def _check_temp_warning(self, temp: int) -> None:
        now = time.time()

        if temp >= TEMP_WARN_THRESHOLD:
            if not self.temp_warn_active:
                self.temp_warn_active = True
                self.temp_warn_since = now
                self.temp_warn_peak = temp
                self.temp_warn_last_log_ts = now
                logger.warning(
                    f"         ! [Temp Warning] CPU temperature is high: {temp}C (threshold={TEMP_WARN_THRESHOLD}C)."
                )
            else:
                if temp > self.temp_warn_peak:
                    self.temp_warn_peak = temp
                if now - self.temp_warn_last_log_ts >= TEMP_WARN_LOG_PERIOD_SEC:
                    self.temp_warn_last_log_ts = now
                    duration = int(now - self.temp_warn_since)
                    logger.warning(
                        f"         ! [Temp Warning] CPU temp remains high: {temp}C for {duration}s (peak={self.temp_warn_peak}C)."
                    )
            return

        if self.temp_warn_active:
            if temp < TEMP_WARN_CLEAR_THRESHOLD:
                duration = int(now - self.temp_warn_since)
                logger.info(
                    f"         ! [Temp Recovered] CPU temp normalized: {temp}C after {duration}s (peak={self.temp_warn_peak}C)."
                )
                self.temp_warn_active = False
                self.temp_warn_since = 0.0
                self.temp_warn_peak = 0
                self.temp_warn_last_log_ts = 0.0
            elif now - self.temp_warn_last_log_ts >= TEMP_WARN_LOG_PERIOD_SEC:
                self.temp_warn_last_log_ts = now
                duration = int(now - self.temp_warn_since)
                logger.warning(
                    f"         ! [Temp Warning] warm zone hold: {temp}C for {duration}s (clear<{TEMP_WARN_CLEAR_THRESHOLD}C)."
                )

    def _check_ram_delta_warning(
        self, ram_delta_kbps: float, shm_usage: Optional[float]
    ) -> None:
        now = time.time()
        shm_usage_str = "N/A" if shm_usage is None else f"{shm_usage}%"

        if ram_delta_kbps >= RAM_DELTA_WARN_THRESHOLD_KBPS:
            if not self.ram_delta_warn_active:
                self.ram_delta_warn_active = True
                self.ram_delta_warn_since = now
                self.ram_delta_warn_peak = ram_delta_kbps
                self.ram_delta_warn_last_log_ts = now
                logger.warning(
                    f"         ! [RAM Delta Warning] tmpfs usage is growing fast: +{ram_delta_kbps:.1f}KB/s"
                    + f" (threshold={RAM_DELTA_WARN_THRESHOLD_KBPS:.1f}KB/s, SHM={shm_usage_str})."
                )
            else:
                if ram_delta_kbps > self.ram_delta_warn_peak:
                    self.ram_delta_warn_peak = ram_delta_kbps
                if (
                    now - self.ram_delta_warn_last_log_ts
                    >= RAM_DELTA_WARN_LOG_PERIOD_SEC
                ):
                    self.ram_delta_warn_last_log_ts = now
                    duration = int(now - self.ram_delta_warn_since)
                    logger.warning(
                        f"         ! [RAM Delta Warning] high growth persists: +{ram_delta_kbps:.1f}KB/s"
                        + f" for {duration}s (peak=+{self.ram_delta_warn_peak:.1f}KB/s, SHM={shm_usage_str})."
                    )
            return

        if self.ram_delta_warn_active:
            if ram_delta_kbps <= RAM_DELTA_WARN_CLEAR_THRESHOLD_KBPS:
                duration = int(now - self.ram_delta_warn_since)
                logger.info(
                    f"         ! [RAM Delta Recovered] growth normalized: {ram_delta_kbps:+.1f}KB/s"
                    + f" after {duration}s (peak=+{self.ram_delta_warn_peak:.1f}KB/s, SHM={shm_usage_str})."
                )
                self.ram_delta_warn_active = False
                self.ram_delta_warn_since = 0.0
                self.ram_delta_warn_peak = 0.0
                self.ram_delta_warn_last_log_ts = 0.0
            elif now - self.ram_delta_warn_last_log_ts >= RAM_DELTA_WARN_LOG_PERIOD_SEC:
                self.ram_delta_warn_last_log_ts = now
                duration = int(now - self.ram_delta_warn_since)
                logger.warning(
                    f"         ! [RAM Delta Warning] elevated growth hold: +{ram_delta_kbps:.1f}KB/s"
                    + f" for {duration}s (clear<={RAM_DELTA_WARN_CLEAR_THRESHOLD_KBPS:.1f}KB/s, SHM={shm_usage_str})."
                )

    def _in_startup_grace(self) -> bool:
        now = int(time.time())
        start_ts = self._safe_read_int_file(TMP_START_TS, 0)
        start_delay = self._safe_read_int_file(TMP_START_DELAY, 0)
        if start_ts > 0 and start_delay >= 0:
            return (now - start_ts) < (start_delay + STARTUP_GRACE_EXTRA_SEC)
        return (time.time() - self.start_time) < STARTUP_GRACE_EXTRA_SEC

    def start(self) -> None:
        syslog("notice", f"PIM Health Guardian 10.0 (Interactive-Recovery) started")
        try:
            while True:
                v, v_s, temp, _la, _lb, rtc_ok = self.get_hw_metrics()
                thru = self.get_net_throughput()
                wf_s, wf_e = self.get_net_info(self.wifi_iface)

                sd_path = self._conf_str("sd_path", "/mnt/sd_cam")
                tmp_path = self._conf_str("tmp_path", "/dev/shm")
                sd_dev = self._conf_str("sd_dev", "mmcblk1")
                emmc_dev = self._conf_str("emmc_dev", "")

                sd_d: DiskUsageInfo = self.get_disk_usage(sd_path)
                shm_d: DiskUsageInfo = self.get_disk_usage(tmp_path)
                app_res = self.get_app_info()
                hb_s, hb_i = self.get_pipeline_heartbeat()
                io = self.calculate_io_metrics()
                cam_active, cam_expected = self.check_cams().split("/")
                cam_active_n = int(cam_active)
                cam_expected_n = int(cam_expected)
                cam_hw_s = f"{cam_active_n}/{cam_expected_n}"
                bg_bits = self._safe_read_int_file(BG_FLAG_FILE, 0)
                bg_cam_mask = bg_bits & 0x0F
                bg_cam_mask_en = bg_cam_mask & self.cam_en_bitmask
                bg_cam_channels = self._cam_channels_from_mask(bg_cam_mask_en)
                bg_cam_channels_str = (
                    ",".join(bg_cam_channels) if bg_cam_channels else "none"
                )
                bg_err_count = bin(bg_cam_mask_en).count("1")
                cam_bg_active_n = max(cam_expected_n - bg_err_count, 0)
                pipeline_apps_up = (
                    app_res["gstApp"]["up"] != "N/A" and app_res["vcm"]["up"] != "N/A"
                )
                in_startup_grace = self._in_startup_grace()

                if in_startup_grace:
                    cam_effective = f"STARTING(hw={cam_hw_s})"
                    cam_reason = "startup_grace"
                elif bg_cam_mask_en != 0:
                    cam_effective = f"{cam_bg_active_n}/{cam_expected_n}"
                    cam_reason = f"bg_cam_err_mask=0x{bg_cam_mask_en:x}"
                elif pipeline_apps_up:
                    cam_effective = cam_hw_s
                    cam_reason = "ok"
                else:
                    cam_effective = f"UNKNOWN(app_down hw={cam_hw_s})"
                    cam_reason = "pipeline_down"
                cam_err_tag = ""
                if bg_cam_mask_en != 0 and not in_startup_grace:
                    cam_err_tag = f" [CamErr:{bg_cam_channels_str}]"
                _z_cnt = self.check_zombies()
                recent_err_list = self.get_recent_error_list()
                last_err = recent_err_list[0] if recent_err_list else "None"
                cpu_t = self.get_total_cpu_usage()
                if temp > self.peak_temp:
                    self.peak_temp = temp
                if v > 0 and v < self.min_volt:
                    self.min_volt = v
                if cpu_t > self.max_cpu:
                    self.max_cpu = cpu_t

                ts = datetime.now().strftime("%H:%M:%S")
                wf_thru = thru.get(self.wifi_iface, (0, 0))
                sd_usage_str = (
                    f"{sd_d['usage']}%"
                    if sd_d["mounted"] and sd_d["usage"] is not None
                    else "N/A"
                )
                shm_usage_str = (
                    f"{shm_d['usage']}%"
                    if shm_d["mounted"] and shm_d["usage"] is not None
                    else "N/A"
                )
                logger.info(
                    f"[{ts}] [WiFi:{wf_s}{wf_e} RX:{wf_thru[0]:.0f}KB/s TX:{wf_thru[1]:.0f}KB/s]"
                    + f" [RTC:{'OK' if rtc_ok else 'ERR'}]"
                    + f" [Camera:{cam_effective}]{cam_err_tag} [Heartbeat:{hb_s}({hb_i}s)]"
                )

                default_io: IOMetric = {"rk": 0.0, "wk": 0.0, "util": 0.0}
                sd_io = io.get(sd_dev, default_io)

                emmc_io: Optional[IOMetric] = None
                if emmc_dev and emmc_dev != sd_dev:
                    emmc_candidate = io.get(emmc_dev)
                    if emmc_candidate is not None:
                        emmc_io = emmc_candidate
                        emmc_io_str = f"{emmc_io['util']:.1f}%/{emmc_io['wk']:.1f}KB/s"
                    else:
                        emmc_io_str = "0.0%/0.0KB/s"
                else:
                    emmc_io_str = "N/A"

                ram_delta_kbps = self._estimate_tmp_delta_kbps(shm_d)

                logger.info(
                    f"         |- [Storage: SD({sd_d['mode']}/{sd_usage_str}) SHM({shm_usage_str})]"
                    + f" [App CPU: gstApp({app_res['gstApp']['cpu']}%) ord({app_res['ord']['cpu']}%) vcm({app_res['vcm']['cpu']}%)]"
                )
                logger.info(
                    f"         |- [App Uptime: gstApp({app_res['gstApp']['up']}) ord({app_res['ord']['up']}) vcm({app_res['vcm']['up']})]"
                    + f" [Power:{v_s}({v:.2f}V)]"
                )
                logger.info(
                    f"         `- [System: CPU({cpu_t:.1f}%/{temp}C)]"
                    + f" [DiskIO: SD({sd_dev} {sd_io['util']:.1f}%/{sd_io['wk']:.1f}KB/s)"
                    + f" eMMC({emmc_dev or 'N/A'} {emmc_io_str})]"
                    + f" [RAMDelta:{ram_delta_kbps:+.1f}KB/s]"
                    + f" [Peaks: Temp({self.peak_temp}C) MinVolt({self.min_volt:.2f}V)]"
                )
                logger.info(f"         ! [Recent Error] {last_err}")
                if recent_err_list:
                    logger.info(
                        f"         ! [Error List] {len(recent_err_list)} item(s), newest first"
                    )
                    for err_item in recent_err_list:
                        logger.info(f"         !   - {err_item}")
                else:
                    logger.info("         ! [Error List] None")

                guardian_bits = 0
                if hb_s == "FROZEN":
                    guardian_bits |= GUARD_BIT_HB_FROZEN
                if sd_d["mode"] == "RO":
                    guardian_bits |= GUARD_BIT_SD_RO
                if temp >= MAX_CPU_TEMP:
                    guardian_bits |= GUARD_BIT_CPU_HOT
                if v_s == "ERR":
                    guardian_bits |= GUARD_BIT_VOLT_ERR

                cam_state, cam_streak = self._read_cam_state()
                tmp_sig = self.collect_tmp_signals()

                logger.info(
                    f"         ! [Camera Health] effective={cam_effective} reason={cam_reason} hw={cam_hw_s} bgMask=0x{bg_cam_mask_en:x} channels={bg_cam_channels_str}"
                )

                sync_state_obj = tmp_sig.get("start_time_sync")
                sync_state: Optional[bool] = (
                    sync_state_obj if isinstance(sync_state_obj, bool) else None
                )

                self._check_tmp_sync_warning(sync_state)
                self._check_temp_warning(temp)
                self._check_ram_delta_warning(ram_delta_kbps, shm_d["usage"])

                sync_raw = sync_state
                if sync_raw is True:
                    sync_raw_str = "OK"
                elif sync_raw is False:
                    sync_raw_str = "MISMATCH"
                else:
                    sync_raw_str = "N/A"
                sync_debounced = "WARN" if self.tmp_sync_warn_active else "OK"

                vhl_match = tmp_sig["vhl_cache_match"]
                vhl_str = "N/A" if vhl_match is None else str(vhl_match)

                sd_err_age = tmp_sig["err_sdcard_age_sec"]
                sd_err_age_str = "N/A" if sd_err_age is None else str(sd_err_age)

                file_age = tmp_sig["file_check_age_sec"]
                file_age_str = "N/A" if file_age is None else str(file_age)

                logger.info(
                    f"         |- [TMP: file={tmp_sig['file_check']} fileAge={file_age_str}s camErrStreak={tmp_sig['bg_cam_err_streak']}"
                    + f" done(video/srt)={tmp_sig['video_done_cnt']}/{tmp_sig['srt_done_cnt']}"
                    + f" syncRaw={sync_raw_str} syncDebounced={sync_debounced} bgCamMask=0x{bg_cam_mask:x} bgCamCh={bg_cam_channels_str}"
                    + f" vhl={vhl_str} sdErrAge={sd_err_age_str}s]"
                )

                if in_startup_grace:
                    cam_mismatch = False
                elif bg_cam_mask_en != 0:
                    cam_mismatch = True
                elif not pipeline_apps_up:
                    cam_mismatch = True
                else:
                    cam_mismatch = cam_active_n != cam_expected_n

                if cam_mismatch:
                    guardian_bits |= GUARD_BIT_CAM_MISMATCH
                else:
                    guardian_bits &= ~GUARD_BIT_CAM_MISMATCH

                self._write_guardian_state(
                    {
                        "ts": int(time.time()),
                        "guardian_bits": guardian_bits,
                        "bg_bits": bg_bits,
                        "cam_state": cam_state,
                        "cam_streak": cam_streak,
                        "hb": {"status": hb_s, "idle_sec": hb_i},
                        "cam": cam_hw_s,
                        "cam_effective": cam_effective,
                        "cam_reason": cam_reason,
                        "cam_bg_mask": bg_cam_mask,
                        "cam_bg_channels": bg_cam_channels,
                        "sd": {"mode": sd_d["mode"], "usage": sd_d["usage"]},
                        "io": {
                            "sd_dev": sd_dev,
                            "sd_util": round(sd_io["util"], 1),
                            "sd_write_kb_s": round(sd_io["wk"], 1),
                            "emmc_dev": emmc_dev,
                            "emmc_util": round(emmc_io["util"], 1) if emmc_io else None,
                            "emmc_write_kb_s": round(emmc_io["wk"], 1)
                            if emmc_io
                            else None,
                            "ram_delta_kb_s": round(ram_delta_kbps, 1),
                            "ram_delta_warn_active": self.ram_delta_warn_active,
                        },
                        "power": {"volt": round(v, 2), "status": v_s},
                        "cpu": {"usage": cpu_t, "temp": temp},
                        "tmp": tmp_sig,
                    }
                )

                if (
                    guardian_bits > 0
                    and self.recovery_enabled
                    and (guardian_bits & (GUARD_BIT_CAM_MISMATCH | GUARD_BIT_HB_FROZEN))
                ):
                    self.error_count += 1
                    if self.error_count > 3:
                        syslog(
                            "err",
                            f"Guardian anomaly mask:0x{guardian_bits:x}. Requesting recovery.",
                        )
                        self._request_recovery(
                            f"guardian_watchdog mask=0x{guardian_bits:x}"
                        )
                else:
                    self.error_count = 0

                # ── Interactive recovery prompts ──
                sd_ro_fallback = not sd_d["mounted"] and os.path.exists("/dev/shm/sd_mount_flag") and open("/dev/shm/sd_mount_flag").read().strip() == "0"
                if (sd_d["mode"] == "RO" and sd_d["mounted"]) or sd_ro_fallback:
                    self._prompt_recovery(
                        "sd_ro",
                        "SD card became read-only. Run filesystem check and remount?",
                        self._recover_sd_ro,
                    )
                else:
                    self._clear_recovery_state("sd_ro")

                if bg_cam_mask_en != 0 and not in_startup_grace:
                    self._prompt_recovery(
                        "cam_disconnect",
                        f"Camera channel(s) [{bg_cam_channels_str}] disconnected. Run init_cam to reload driver?",
                        self._recover_cam_disconnect,
                    )
                else:
                    self._clear_recovery_state("cam_disconnect")

                if hb_s == "FROZEN" and not in_startup_grace:
                    self._prompt_recovery(
                        "hb_frozen",
                        "Pipeline heartbeat frozen. Restart camera pipeline?",
                        self._recover_hb_frozen,
                    )
                else:
                    self._clear_recovery_state("hb_frozen")

                time.sleep(self.interval)
        except KeyboardInterrupt:
            syslog("notice", "Guardian stopped")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    _ = p.add_argument("--recovery", action="store_true")
    _ = p.add_argument("--interval", type=int, default=5)
    _ = p.add_argument(
        "--error-window-sec", type=int, default=TMP_RECENT_ERROR_MAX_AGE_SEC
    )
    _ = p.add_argument(
        "--error-list-max", type=int, default=TMP_RECENT_ERROR_LIST_MAX_ITEMS
    )
    _ = p.add_argument(
        "--fsck-timeout", type=int, default=0,
        help="fsck timeout in seconds (0 = no timeout, default: 0)"
    )
    args = p.parse_args()
    PIMHealthGuardian(args).start()
