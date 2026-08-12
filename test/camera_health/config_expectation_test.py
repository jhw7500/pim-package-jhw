#!/usr/bin/env python3
"""Offline tests for /tmp/config camera-domain expectation resolution."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Mapping


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "dist/pim/opt/pim/bin/camera_config_expectation.py"

spec = importlib.util.spec_from_file_location("camera_config_expectation", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load camera_config_expectation.py")
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


def edgeconf(enabled: Mapping[int, object], width: object = 1920, height: object = 1080, fps: object = 30) -> Dict[str, Any]:
    return {
        "VHL_CAM": {
            "cam_width": width,
            "cam_height": height,
            "fps": fps,
            "i2c2": {
                "ch0": {"enable": enabled.get(0, False)},
                "ch1": {"enable": enabled.get(1, False)},
            },
            "i2c1": {
                "ch2": {"enable": enabled.get(2, False)},
                "ch3": {"enable": enabled.get(3, False)},
            },
        }
    }


def resolve(config: Mapping[str, Any]) -> Dict[str, Any]:
    return resolver.resolve_expectation(
        config,
        "boot-a",
        "1" * 64,
        "1" * 64,
        Path("/tmp/config/edgeconf_pim.json"),
        1000,
    )


def domains(document: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {item["id"]: item for item in document["domains"]}


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
            print(f"  FAIL {label}", file=sys.stderr)

    def rejects(self, action: object, label: str) -> None:
        try:
            action()  # type: ignore[operator]
        except resolver.ConfigError:
            self.check(True, label)
        else:
            self.check(False, label)

    def run(self) -> int:
        print("=== camera config expectation ===")
        self.mode_tests()
        self.validation_tests()
        with tempfile.TemporaryDirectory(prefix="camera-expectation-test.") as temporary:
            self.file_tests(Path(temporary))
        print()
        print(f"camera config expectation: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0

    def mode_tests(self) -> None:
        result = resolve(edgeconf({0: True, 1: True, 2: True, 3: True}))
        indexed = domains(result)
        self.check(result["configured_channel_mask"] == 15, "four configured channels produce mask 0xF")
        self.check(result["stream_mode"] == "dual-wide", "two fully populated pairs are dual-wide")
        self.check(
            indexed["ch01"]["mode"] == "dual-wide"
            and indexed["ch01"]["active_channels"] == [0, 1]
            and indexed["ch01"]["expected_format"]["width"] == 3840,
            "ch01 dual-wide uses both channel identities and doubled CSI input width",
        )
        self.check(
            indexed["ch23"]["configured_channel_mask"] == 12,
            "ch23 domain retains physical channel bits 2 and 3",
        )

        result = resolve(edgeconf({0: True}))
        indexed = domains(result)
        self.check(
            result["stream_mode"] == "single"
            and indexed["ch01"]["mode"] == "single"
            and indexed["ch01"]["active_channels"] == [0]
            and indexed["ch01"]["expected_format"]["width"] == 1920,
            "one configured channel produces a single-stream expectation",
        )
        self.check(
            indexed["ch23"]["mode"] == "disabled"
            and indexed["ch23"]["expected_format"] == {"width": 0, "height": 0, "fps": 0},
            "empty peer domain is explicitly disabled",
        )

        result = resolve(edgeconf({0: True, 1: True, 2: True}))
        self.check(
            result["stream_mode"] == "independent",
            "mixed dual-wide and single domains are reported as independent",
        )

        result = resolve(edgeconf({}))
        self.check(
            result["stream_mode"] == "unknown"
            and result["configured_channel_mask"] == 0
            and all(item["mode"] == "disabled" for item in result["domains"]),
            "all-disabled config has no fabricated stream expectation",
        )

        missing_enable = edgeconf({0: True})
        del missing_enable["VHL_CAM"]["i2c2"]["ch1"]["enable"]
        self.check(
            domains(resolve(missing_enable))["ch01"]["active_channels"] == [0],
            "missing enable field defaults to disabled",
        )

    def validation_tests(self) -> None:
        self.rejects(lambda: resolve(edgeconf({0: 1})), "non-boolean enable is rejected")
        self.rejects(lambda: resolve(edgeconf({}, width=0)), "zero camera width is rejected")
        self.rejects(lambda: resolve(edgeconf({}, height=True)), "boolean camera height is rejected")
        self.rejects(lambda: resolve(edgeconf({}, fps="30")), "non-integer FPS is rejected")
        self.rejects(lambda: resolve({}), "missing VHL_CAM object is rejected")

    def file_tests(self, root: Path) -> None:
        config_dir = root / "config"
        config_dir.mkdir()
        boot_id_file = root / "boot_id"
        boot_id_file.write_text("boot-file\n", encoding="utf-8")
        edge_path = config_dir / "edgeconf_pim.json"
        raw = json.dumps(edgeconf({1: True, 2: True}), sort_keys=True).encode()
        edge_path.write_bytes(raw)
        imported_hash = hashlib.sha256(raw).hexdigest()
        ready = {
            "schema": 1,
            "boot_id": "boot-file",
            "files": {"edgeconf_pim": {"sha256": imported_hash}},
        }
        (config_dir / "READY").write_text(json.dumps(ready), encoding="utf-8")

        result = resolver.resolve_from_files(config_dir, boot_id_file, 1234)
        self.check(not result["runtime_override"], "unchanged boot import is not a runtime override")
        self.check(
            result["configured_channel_mask"] == 6
            and domains(result)["ch01"]["active_channels"] == [1]
            and domains(result)["ch23"]["active_channels"] == [2],
            "file resolver maps enabled channels to both capture domains",
        )

        changed = json.dumps(edgeconf({0: True, 1: True}), sort_keys=True).encode()
        temporary = config_dir / ".edgeconf.runtime"
        temporary.write_bytes(changed)
        temporary.replace(edge_path)
        result = resolver.resolve_from_files(config_dir, boot_id_file, 1235)
        self.check(
            result["runtime_override"]
            and result["boot_import_sha256"] == imported_hash
            and result["config_sha256"] == hashlib.sha256(changed).hexdigest(),
            "atomic runtime edit remains authoritative and is diagnosed by hash",
        )

        output = root / "run/config-expectation.json"
        subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--config-dir",
                str(config_dir),
                "--boot-id-file",
                str(boot_id_file),
                "--output",
                str(output),
            ],
            check=True,
        )
        published = json.loads(output.read_text(encoding="utf-8"))
        self.check(published["boot_id"] == "boot-file", "CLI publishes current boot expectation")
        self.check(oct(output.stat().st_mode & 0o777) == "0o640", "CLI output mode is 0640")
        self.check(not list(output.parent.glob(".config-expectation.json.*")), "CLI atomic write leaves no temporary")

        stale_ready = dict(ready)
        stale_ready["boot_id"] = "older-boot"
        (config_dir / "READY").write_text(json.dumps(stale_ready), encoding="utf-8")
        self.rejects(
            lambda: resolver.resolve_from_files(config_dir, boot_id_file, 1236),
            "stale READY from another boot is rejected",
        )

        stale_ready["boot_id"] = "boot-file"
        stale_ready["files"] = {"edgeconf_pim": {"sha256": "not-a-hash"}}
        (config_dir / "READY").write_text(json.dumps(stale_ready), encoding="utf-8")
        self.rejects(
            lambda: resolver.resolve_from_files(config_dir, boot_id_file, 1237),
            "invalid READY import hash is rejected",
        )


if __name__ == "__main__":
    raise SystemExit(Tests().run())
