#!/usr/bin/env python3
"""Offline contract tests for PIM guardian cold-start grace."""

from __future__ import annotations

import argparse
import builtins
import importlib.util
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "dist/pim/opt/pim/bin/pim_guardian.py"

spec = importlib.util.spec_from_file_location("pim_guardian", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load pim_guardian.py")
guardian_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guardian_module)


def runtime_config() -> dict[str, object]:
    return {
        "VHL_CAM": {
            "vhl_name": "TEST-CAR",
            "final_path": "/mnt/test-sd",
            "tmp_path": "/dev/shm/test",
            "i2c2": {"ch0": {"enable": True}, "ch1": {"enable": False}},
            "i2c1": {"ch2": {"enable": True}, "ch3": {"enable": False}},
        },
        "ORD": {"mode": "test"},
        "VCM": {"mode": "test"},
        "ETC": {"camera_startup_grace_sec": 30},
    }


class Tests:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def check(self, condition: bool, label: str) -> None:
        if condition:
            self.passed += 1
            print(f"  OK   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}")

    def run(self) -> int:
        print("=== pim guardian startup grace ===")
        with tempfile.TemporaryDirectory(prefix="guardian-startup-grace.") as temporary:
            root = Path(temporary)
            start_ts = root / "last_start_ts"
            start_delay = root / "pim_cam_start_delay"
            guardian_module.TMP_START_TS = str(start_ts)
            guardian_module.TMP_START_DELAY = str(start_delay)

            obj = object.__new__(guardian_module.PIMHealthGuardian)
            obj.args = argparse.Namespace()
            obj.conf = {"ord": {"ETC": {"camera_startup_grace_sec": 25}}}
            obj.start_time = 1000.0

            start_ts.write_text("1000\n", encoding="utf-8")
            start_delay.write_text("1\n", encoding="utf-8")
            original_time = guardian_module.time.time
            try:
                guardian_module.time.time = lambda: 1024.0
                self.check(
                    obj._in_startup_grace(),
                    "elapsed 24s is protected even when gstApp -d is 1s",
                )

                start_delay.write_text("22\n", encoding="utf-8")
                guardian_module.time.time = lambda: 1025.0
                self.check(
                    not obj._in_startup_grace(),
                    "elapsed 25s exits grace even when prior -d value is 22s",
                )

                obj.conf = {"ord": {"ETC": {"camera_startup_grace_sec": 30}}}
                guardian_module.time.time = lambda: 1029.0
                self.check(obj._in_startup_grace(), "configured 30s grace is honored")
                guardian_module.time.time = lambda: 1030.0
                self.check(not obj._in_startup_grace(), "configured 30s boundary is exact")

                obj.conf = {"ord": {"ETC": {}}}
                guardian_module.time.time = lambda: 1024.0
                self.check(obj._in_startup_grace(), "missing setting defaults to 25s")

                for malformed in ("30", True, -1, 25.5):
                    obj.conf = {
                        "ord": {"ETC": {"camera_startup_grace_sec": malformed}}
                    }
                    guardian_module.time.time = lambda: 1024.0
                    self.check(
                        obj._in_startup_grace(),
                        f"malformed setting {malformed!r} defaults to 25s",
                    )
                    guardian_module.time.time = lambda: 1025.0
                    self.check(
                        not obj._in_startup_grace(),
                        f"malformed setting {malformed!r} expires at 25s",
                    )
            finally:
                guardian_module.time.time = original_time

            self.runtime_load_tests(root)
            self.selector_tests()
            self.command_tests()
            self.sd_recovery_order_test()

        print()
        print(f"guardian startup grace: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0

    def runtime_load_tests(self, root: Path) -> None:
        runtime_path = root / "pim_runtime.json"
        runtime_path.write_text(json.dumps(runtime_config()), encoding="utf-8")
        old_runtime_path = getattr(guardian_module, "RUNTIME_JSON_PATH", None)
        guardian_module.RUNTIME_JSON_PATH = str(runtime_path)
        try:
            obj = object.__new__(guardian_module.PIMHealthGuardian)
            conf = obj._load_all_configs()
            self.check(
                conf.get("config_status") == "VALID"
                and conf.get("runtime_path") == str(runtime_path),
                "guardian diagnoses the fixed merged runtime path",
            )
            self.check(
                conf.get("edge") is conf.get("ord")
                and conf.get("edge") == runtime_config(),
                "guardian parses one runtime object for both edge and ord views",
            )

            for section in ("VHL_CAM", "ORD", "VCM"):
                malformed = runtime_config()
                malformed[section] = []
                runtime_path.write_text(json.dumps(malformed), encoding="utf-8")
                invalid = obj._load_all_configs()
                self.check(
                    invalid.get("config_status") == "CONFIG_INVALID"
                    and invalid.get("runtime_path") == str(runtime_path),
                    f"guardian fails closed on non-object {section}",
                )

            runtime_path.write_text("{bad json}\n", encoding="utf-8")
            invalid = obj._load_all_configs()
            self.check(
                invalid.get("config_status") == "CONFIG_INVALID",
                "guardian classifies malformed runtime as CONFIG_INVALID",
            )
        finally:
            if old_runtime_path is None:
                delattr(guardian_module, "RUNTIME_JSON_PATH")
            else:
                guardian_module.RUNTIME_JSON_PATH = old_runtime_path

    def selector_tests(self) -> None:
        selector = getattr(guardian_module, "select_guardian_camera_action", None)
        self.check(callable(selector), "guardian exposes a pure camera action selector")
        if not callable(selector):
            return

        mismatch = guardian_module.GUARD_BIT_CAM_MISMATCH
        heartbeat = guardian_module.GUARD_BIT_HB_FROZEN
        non_camera = (
            guardian_module.GUARD_BIT_SD_RO
            | guardian_module.GUARD_BIT_CPU_HOT
            | guardian_module.GUARD_BIT_VOLT_ERR
        )
        self.check(
            selector(mismatch)
            == ("module_reload", "guardian-camera-mismatch mask=0x100"),
            "camera mismatch selects module_reload with an exact reason",
        )
        self.check(
            selector(heartbeat)
            == ("gstapp_restart", "guardian-heartbeat-frozen mask=0x200"),
            "frozen heartbeat selects gstapp_restart with an exact reason",
        )
        self.check(
            selector(mismatch | heartbeat)
            == ("module_reload", "guardian-camera-mismatch mask=0x300"),
            "module_reload wins when mismatch and frozen heartbeat coexist",
        )
        self.check(
            selector(non_camera) is None,
            "SD, CPU, and voltage bits alone select no camera action",
        )

    def command_tests(self) -> None:
        request = getattr(guardian_module.PIMHealthGuardian, "_request_camera_recovery", None)
        handler = getattr(
            guardian_module.PIMHealthGuardian,
            "_handle_automatic_camera_recovery",
            None,
        )
        self.check(callable(request), "guardian exposes one recovery request boundary")
        self.check(callable(handler), "generic watchdog uses a testable recovery handler")
        if not callable(request) or not callable(handler):
            return

        obj = object.__new__(guardian_module.PIMHealthGuardian)
        obj.config_valid = True
        obj.error_count = 3
        calls: list[list[str]] = []
        old_ctl = guardian_module.CAM_RECOVERYCTL
        old_run = guardian_module.subprocess.run
        guardian_module.CAM_RECOVERYCTL = "/test/cam-recoveryctl"

        def fake_run(command: list[str], **_kwargs: object) -> SimpleNamespace:
            calls.append(command)
            return SimpleNamespace(returncode=75, stdout="", stderr="BUSY")

        guardian_module.subprocess.run = fake_run
        try:
            rc = obj._request_camera_recovery(
                "module_reload",
                "guardian-camera-mismatch mask=0x100",
            )
            self.check(rc == 75, "cam-recoveryctl BUSY status propagates exactly")
            self.check(
                calls == [[
                    "/test/cam-recoveryctl",
                    "request",
                    "module_reload",
                    "--source",
                    "pim-guardian",
                    "--reason",
                    "guardian-camera-mismatch mask=0x100",
                ]],
                "guardian sends the exact action, source, and reason",
            )

            calls.clear()
            obj.config_valid = False
            self.check(
                obj._request_camera_recovery("camera_hard_reset", "invalid") == 64
                and not calls,
                "CONFIG_INVALID suppresses every recovery command",
            )

            obj.config_valid = True
            guardian_module.subprocess.run = lambda *_args, **_kwargs: (_ for _ in ()).throw(
                OSError("unavailable")
            )
            self.check(
                obj._request_camera_recovery("gstapp_restart", "unavailable") == 69,
                "cam-recoveryctl unavailable status propagates exactly",
            )

            guardian_module.subprocess.run = fake_run
            calls.clear()
            captured: list[tuple[str, str, object]] = []

            def capture(action: str, reason: str, wait_sec: object = None) -> int:
                captured.append((action, reason, wait_sec))
                return 0

            obj._request_camera_recovery = capture
            self.check(
                obj._recover_cam_disconnect()
                and captured
                == [
                    (
                        "module_reload",
                        "guardian-camera-mismatch mask=0x100",
                        300,
                    )
                ],
                "interactive disconnect requests module_reload through the boundary",
            )

            captured.clear()
            self.check(
                obj._recover_hb_frozen()
                and captured
                == [
                    (
                        "gstapp_restart",
                        "guardian-heartbeat-frozen mask=0x200",
                        120,
                    )
                ],
                "interactive heartbeat requests gstapp_restart through the boundary",
            )

            captured.clear()
            obj.error_count = 3
            result = obj._handle_automatic_camera_recovery(
                guardian_module.GUARD_BIT_CAM_MISMATCH
                | guardian_module.GUARD_BIT_HB_FROZEN
            )
            self.check(
                result == 0
                and captured
                == [
                    (
                        "module_reload",
                        "guardian-camera-mismatch mask=0x300",
                        None,
                    )
                ]
                and obj.error_count == 4,
                "generic watchdog applies selector precedence through cam-recoveryctl",
            )

            captured.clear()
            result = obj._handle_automatic_camera_recovery(
                guardian_module.GUARD_BIT_HB_FROZEN
            )
            self.check(
                result == 0
                and captured
                == [
                    (
                        "gstapp_restart",
                        "guardian-heartbeat-frozen mask=0x200",
                        None,
                    )
                ]
                and obj.error_count == 5,
                "camera anomalies remain at the request boundary after the initial threshold",
            )

            captured.clear()
            result = obj._handle_automatic_camera_recovery(
                guardian_module.GUARD_BIT_SD_RO
                | guardian_module.GUARD_BIT_CPU_HOT
            )
            self.check(
                result is None and not captured and obj.error_count == 0,
                "generic watchdog performs no camera recovery for non-camera bits",
            )
        finally:
            guardian_module.subprocess.run = old_run
            guardian_module.CAM_RECOVERYCTL = old_ctl

    def sd_recovery_order_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="guardian-sd-order.") as raw:
            root = Path(raw)
            class FakeProcess:
                def __init__(self, events: list[tuple[object, ...]]) -> None:
                    self.events = events
                    self.stdout = tempfile.TemporaryFile()

                def poll(self) -> int:
                    return 0

                def wait(self) -> int:
                    return 0

                def kill(self) -> None:
                    return None

            original_popen = guardian_module.subprocess.Popen
            original_run = guardian_module.subprocess.run
            original_open = builtins.open
            had_mount_flag_path = hasattr(guardian_module, "SD_MOUNT_FLAG_PATH")
            original_mount_flag_path = getattr(
                guardian_module, "SD_MOUNT_FLAG_PATH", None
            )

            def run_case(
                name: str,
                *,
                readiness: str,
                redundant_unmount_succeeds: bool,
                filesystem: str | None = "ext4",
                stop_succeeds: bool = True,
            ) -> tuple[
                bool,
                list[tuple[object, ...]],
                dict[str, object],
                Path,
                Path,
            ]:
                case_root = root / name
                case_root.mkdir()
                mount_flag = case_root / "sd_mount_flag"
                recovery_flag = case_root / "sd_ro_recovered"
                guardian_module.SD_MOUNT_FLAG_PATH = str(mount_flag)

                obj = object.__new__(guardian_module.PIMHealthGuardian)
                obj.args = argparse.Namespace(
                    fsck_timeout=30,
                    sd_ready_timeout_sec=0.02,
                    sd_ready_poll_interval_sec=0.001,
                )
                events: list[tuple[object, ...]] = []
                state: dict[str, object] = {
                    "writer_active": True,
                    "mounted": True,
                    "mount_service_active": True,
                    "camera_active": True,
                    "camera_polls": 0,
                }
                mount_flag.write_text("1\n", encoding="utf-8")

                def request(
                    action: str, reason: str, wait_sec: object = None
                ) -> int:
                    events.append(("request", action, reason, wait_sec))
                    return 0

                def step(
                    _step_number: int,
                    _total: int,
                    _description: str,
                    command: list[str],
                    allow_fail: bool = False,
                ) -> bool:
                    events.append(("step", tuple(command), allow_fail))
                    if command == ["systemctl", "stop", "sd-mount"]:
                        if not stop_succeeds:
                            return False
                        # Model the deployed ExecStop=sd_mount_stop.sh contract:
                        # the writer is stopped, the device is unmounted, and
                        # the availability flag is removed before stop returns.
                        state["writer_active"] = False
                        state["mounted"] = False
                        state["mount_service_active"] = False
                        state["camera_active"] = False
                        mount_flag.unlink(missing_ok=True)
                        events.append(("exec-stop-complete",))
                        return True
                    if command and command[0] == "umount":
                        events.append(
                            (
                                "raw-unmount",
                                tuple(command),
                                state["mounted"],
                            )
                        )
                        return redundant_unmount_succeeds
                    if command == ["systemctl", "start", "sd-mount"]:
                        # Default Type=simple reports success as soon as the
                        # long-running automount process has been launched.
                        state["mount_service_active"] = True
                        events.append(("type-simple-start-returned",))
                        return True
                    return True

                def detect_fstype() -> str | None:
                    events.append(("detect-fstype", filesystem))
                    return filesystem

                def fake_popen(
                    command: list[str], **_kwargs: object
                ) -> FakeProcess:
                    events.append(("fsck", tuple(command)))
                    return FakeProcess(events)

                def fake_run(
                    command: list[str], **_kwargs: object
                ) -> SimpleNamespace:
                    if command == ["systemctl", "is-active", "sd-mount"]:
                        if readiness == "service-failed":
                            state["mount_service_active"] = False
                        active = bool(state["mount_service_active"])
                        events.append(("poll-mount-service", active))
                        return SimpleNamespace(
                            returncode=0 if active else 3,
                            stdout="active\n" if active else "failed\n",
                            stderr="",
                        )
                    if command == ["systemctl", "is-active", "cam-operate"]:
                        state["camera_polls"] = int(state["camera_polls"]) + 1
                        if readiness == "ready" and state["camera_polls"] >= 3:
                            state["mounted"] = True
                            state["writer_active"] = True
                            state["camera_active"] = True
                            mount_flag.write_text("1\n", encoding="utf-8")
                        active = bool(state["camera_active"])
                        events.append(("poll-camera", active))
                        return SimpleNamespace(
                            returncode=0 if active else 3,
                            stdout="active\n" if active else "inactive\n",
                            stderr="",
                        )
                    raise AssertionError(f"unexpected subprocess.run: {command!r}")

                def redirected_open(
                    file: object, *args: object, **kwargs: object
                ) -> object:
                    if file == "/tmp/sd_ro_recovered":
                        events.append(("recovery-flag",))
                        file = recovery_flag
                    return original_open(file, *args, **kwargs)

                obj._request_camera_recovery = request
                obj._run_recovery_step = step
                obj._detect_sd_fstype = detect_fstype
                guardian_module.subprocess.Popen = fake_popen
                guardian_module.subprocess.run = fake_run
                builtins.open = redirected_open
                result = obj._recover_sd_ro()
                return result, events, state, mount_flag, recovery_flag

            try:
                result, events, state, mount_flag, recovery_flag = run_case(
                    "deployed-stop",
                    readiness="ready",
                    redundant_unmount_succeeds=False,
                )
                stop_event = (
                    "step",
                    ("systemctl", "stop", "sd-mount"),
                    False,
                )
                fsck_event = next(
                    (event for event in events if event[0] == "fsck"),
                    None,
                )
                start_event = (
                    "step",
                    ("systemctl", "start", "sd-mount"),
                    False,
                )
                requests = [event for event in events if event[0] == "request"]
                self.check(
                    result is True
                    and fsck_event is not None
                    and not requests
                    and stop_event in events
                    and not any(event[0] == "raw-unmount" for event in events)
                    and ("recovery-flag",) in events
                    and start_event in events
                    and events.index(stop_event) < events.index(fsck_event)
                    < events.index(("recovery-flag",)) < events.index(start_event)
                    and mount_flag.read_text(encoding="utf-8").strip() == "1"
                    and recovery_flag.read_text(encoding="utf-8").strip() == "1"
                    and state["writer_active"] is True,
                    "deployed ExecStop is the authoritative unmount before fsck/remount",
                )

                result, events, _state, mount_flag, _recovery_flag = run_case(
                    "type-simple-ready",
                    readiness="ready",
                    redundant_unmount_succeeds=True,
                )
                camera_polls = [
                    bool(event[1]) for event in events if event[0] == "poll-camera"
                ]
                self.check(
                    result is True
                    and camera_polls[:2] == [False, False]
                    and camera_polls[-1:] == [True]
                    and mount_flag.read_text(encoding="utf-8").strip() == "1"
                    and not any(event[0] == "request" for event in events),
                    "Type=simple start waits for flag=1 and active cam-operate without restart request",
                )

                result, events, _state, mount_flag, _recovery_flag = run_case(
                    "never-ready",
                    readiness="never",
                    redundant_unmount_succeeds=True,
                )
                self.check(
                    result is False
                    and not mount_flag.exists()
                    and any(event[0] == "poll-camera" for event in events)
                    and not any(event[0] == "request" for event in events),
                    "bounded not-ready timeout fails with zero camera recovery requests",
                )

                result, events, _state, _mount_flag, _recovery_flag = run_case(
                    "service-failed",
                    readiness="service-failed",
                    redundant_unmount_succeeds=True,
                )
                self.check(
                    result is False
                    and ("poll-mount-service", False) in events
                    and not any(event[0] == "request" for event in events),
                    "failed mount service aborts readiness with zero camera recovery requests",
                )

                result, events, _state, mount_flag, _recovery_flag = run_case(
                    "unknown-fstype",
                    readiness="ready",
                    redundant_unmount_succeeds=True,
                    filesystem=None,
                )
                self.check(
                    result is False
                    and not any(event[0] == "fsck" for event in events)
                    and mount_flag.is_file()
                    and mount_flag.read_text(encoding="utf-8").strip() == "1"
                    and any(event[0] == "poll-camera" for event in events)
                    and not any(event[0] == "request" for event in events),
                    "unknown filesystem restore waits for readiness but remains failed",
                )

                result, events, _state, _mount_flag, _recovery_flag = run_case(
                    "stop-failed",
                    readiness="never",
                    redundant_unmount_succeeds=False,
                    stop_succeeds=False,
                )
                self.check(
                    result is False
                    and events
                    == [
                        (
                            "step",
                            ("systemctl", "stop", "sd-mount"),
                            False,
                        )
                    ],
                    "sd-mount stop failure aborts before fsck, start, or recovery",
                )
            finally:
                guardian_module.subprocess.Popen = original_popen
                guardian_module.subprocess.run = original_run
                builtins.open = original_open
                if had_mount_flag_path:
                    guardian_module.SD_MOUNT_FLAG_PATH = original_mount_flag_path
                else:
                    delattr(guardian_module, "SD_MOUNT_FLAG_PATH")


if __name__ == "__main__":
    raise SystemExit(Tests().run())
