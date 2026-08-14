#!/usr/bin/env python3
"""Offline package integration tests for the MAX9296 health producer."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[2]
PRODUCER = ROOT / "dist/pim/opt/pim/bin/max9296_health_export.py"
AGGREGATOR = ROOT / "dist/pim/opt/pim/bin/camera_healthd.py"
SCHEMA = ROOT / "docs/camera-health/health-v1.schema.json"
REGISTRY = ROOT / "dist/pim/opt/pim/config/camera_health_error_codes_v1.json"
COMPARATOR = ROOT / "dist/pim/opt/pim/bin/camera_health_shadow_compare.py"
UNIT = ROOT / "dist/pim/etc/systemd/system/camera-max9296-health.service"
POSTINST = ROOT / "dist/pim/DEBIAN/postinst"


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


healthd = load_module("camera_healthd_for_max9296_test", AGGREGATOR)
comparator = load_module("camera_health_shadow_compare_for_max9296_test", COMPARATOR)
exporter = load_module("max9296_health_export_for_max9296_test", PRODUCER)


def channel(channel_id: int, enabled: bool, phy: str = "NONE") -> dict[str, Any]:
    if not enabled:
        return {
            "channel": channel_id,
            "enabled": False,
            "phy": "NONE",
            "link": {"status": "N/A", "up": False},
            "control_tunnel": "N/A",
            "serializer": {"status": "N/A", "errno": -61, "device_id": None},
            "isp": {
                "status": "N/A",
                "errno": -61,
                "hinf_count": None,
                "hinf_progress": "NOT_EXPECTED",
            },
            "sensor": {"status": "N/A", "probe": "DEEP_NOT_RUN"},
        }
    return {
        "channel": channel_id,
        "enabled": True,
        "phy": phy,
        "link": {"status": "OK", "up": True},
        "control_tunnel": "OK",
        "serializer": {"status": "OK", "errno": 0, "device_id": 0x91},
        "isp": {
            "status": "OK",
            "errno": 0,
            "hinf_count": 17 + channel_id,
            "hinf_progress": "YES",
        },
        "sensor": {"status": "UNKNOWN", "probe": "DEEP_NOT_RUN"},
    }


def raw_device(
    adapter: int,
    local_base: int,
    channels: list[dict[str, Any]],
    mode: str,
    streaming: bool,
) -> dict[str, Any]:
    local_mask = sum(
        1 << (item["channel"] - local_base) for item in channels if item["enabled"]
    )
    global_mask = sum(1 << item["channel"] for item in channels if item["enabled"])
    return {
        "schema": 1,
        "adapter": adapter,
        "sequence": 9,
        "observed_monotonic_ms": 1000,
        "busy": False,
        "mode": mode,
        "streaming": streaming,
        "configured_local_mask": local_mask,
        "configured_global_mask": global_mask,
        "deserializer": {
            "status": "OK",
            "errno": 0,
            "device_id": 0x96,
            "ctrl3_errno": 0,
            "ctrl3": 0xFA,
            "rx3_errno": 0,
            "rx3": 0x66,
            "link_a_up": True,
            "link_b_up": True,
        },
        "channels": channels,
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
            print(f"  FAIL {label}", file=sys.stderr)

    def run(self) -> int:
        print("=== packaged MAX9296 producer ===")
        with tempfile.TemporaryDirectory(prefix="pim-max9296-test.") as temporary:
            self.package_integration(Path(temporary))
        with tempfile.TemporaryDirectory(prefix="pim-max9296-seam.") as temporary:
            self.shadow_seam(Path(temporary))
        self.stalled_source_freshness()
        self.unit_contract()
        print()
        print(f"packaged MAX9296 producer: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0

    def package_integration(self, root: Path) -> None:
        raw_paths = [root / "i2c2-health.json", root / "i2c1-health.json"]
        raw_documents = [
            raw_device(
                2,
                0,
                [channel(0, True, "B"), channel(1, True, "A")],
                "dual-wide",
                True,
            ),
            raw_device(
                1,
                2,
                [channel(2, False), channel(3, False)],
                "single",
                False,
            ),
        ]
        for path, document in zip(raw_paths, raw_documents):
            path.write_text(json.dumps(document), encoding="utf-8")
        boot_id = root / "boot_id"
        boot_id.write_text("boot-package\n", encoding="utf-8")
        output = root / "max9296.json"
        command = [
            sys.executable,
            str(PRODUCER),
            "--once",
            "--boot-id-file",
            str(boot_id),
            "--output",
            str(output),
        ]
        for path in raw_paths:
            command.extend(("--input", str(path)))

        completed = subprocess.run(command, check=False)
        self.check(
            completed.returncode == 0, "installed producer runs from package path"
        )
        snapshot = json.loads(output.read_text(encoding="utf-8"))
        self.check(
            snapshot["channel_masks"]
            == {
                "configured_channel_mask": 0x3,
                "physical_present_mask": 0x3,
                "stream_domain_active_mask": 0x3,
            },
            "packaged producer preserves the three-mask contract",
        )
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.check(
            not list(Draft202012Validator(schema).iter_errors(snapshot)),
            "packaged output validates against health-v1 schema",
        )

        registry = healthd.load_registry(REGISTRY)
        aggregate = healthd.aggregate(
            root,
            "boot-package",
            snapshot["observed_monotonic_ms"],
            3000,
            registry,
        )
        max_state = next(
            item for item in aggregate["producers"] if item["producer"] == "max9296"
        )
        self.check(
            max_state["state"] == "OK"
            and aggregate["channel_masks"] == snapshot["channel_masks"],
            "shadow aggregator accepts producer output and propagates masks",
        )
        self.check(
            aggregate["legacy_write"] is False
            and aggregate["recovery_requested"] is False,
            "producer integration remains observation-only",
        )

        sentinel = output.read_bytes()
        raw_paths[0].write_text(
            json.dumps({"schema": 1, "busy": True}), encoding="utf-8"
        )
        busy = subprocess.run(
            command, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        self.check(busy.returncode == 75, "busy control path returns temporary failure")
        self.check(
            output.read_bytes() == sentinel,
            "busy sampling does not replace the last valid snapshot",
        )

    def shadow_seam(self, root: Path) -> None:
        """Drive the real producer output into the real comparator.

        The producer/comparator seam had no coverage: the comparator suite built
        synthetic observations, so nothing noticed that a healthy real snapshot
        could never reach AGREE_HEALTHY.
        """
        raw_paths = [root / "i2c2-health.json", root / "i2c1-health.json"]
        raw_documents = [
            raw_device(
                2,
                0,
                [channel(0, True, "B"), channel(1, True, "A")],
                "dual-wide",
                True,
            ),
            raw_device(
                1,
                2,
                [channel(2, True, "B"), channel(3, True, "A")],
                "dual-wide",
                True,
            ),
        ]
        for path, document in zip(raw_paths, raw_documents):
            path.write_text(json.dumps(document), encoding="utf-8")
        boot_id = root / "boot_id"
        boot_id.write_text("boot-seam\n", encoding="utf-8")
        output = root / "max9296.json"
        command = [
            sys.executable,
            str(PRODUCER),
            "--once",
            "--boot-id-file",
            str(boot_id),
            "--output",
            str(output),
        ]
        for path in raw_paths:
            command.extend(("--input", str(path)))
        completed = subprocess.run(command, check=False)
        self.check(completed.returncode == 0, "producer accepts a fully healthy input")

        snapshot = json.loads(output.read_text(encoding="utf-8"))
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.check(
            not list(Draft202012Validator(schema).iter_errors(snapshot)),
            "healthy snapshot validates against health-v1 schema",
        )
        self.check(
            not any(
                item["block"] == "sensor" and item["status"] == "UNKNOWN"
                for item in snapshot["observations"]
            ),
            "shallow ABI emits no UNKNOWN sensor observation",
        )
        self.check(
            snapshot["producer_data"]["sensor_probe"] == "shallow-only",
            "absent sensor probe is still declared in producer_data",
        )
        self.check(
            snapshot["status"] == "OK",
            "healthy input yields an OK producer snapshot",
        )

        domain_scopes = {"ch01": {0, 1}, "ch23": {2, 3}}
        camera_status = comparator.v1_camera_status(snapshot, 0xF, domain_scopes)
        self.check(
            camera_status == "OK",
            "comparator reads the real producer snapshot as OK",
        )
        verdict, _reason = comparator.classify(
            {"state": "OK", "active_camera_mask": 0, "maintenance_flags": []},
            snapshot,
            {"state": "OK", "complete": True},
            camera_status,
            0,
            False,
        )
        self.check(
            verdict == "AGREE_HEALTHY",
            "real producer output can reach AGREE_HEALTHY",
        )

        registry = healthd.load_registry(REGISTRY)
        stale = healthd.aggregate(
            root,
            "boot-seam",
            snapshot["observed_monotonic_ms"] + 4000,
            3000,
            registry,
        )
        stale_state = next(
            item for item in stale["producers"] if item["producer"] == "max9296"
        )
        self.check(
            stale_state["code"] == "PRODUCER_STALE",
            "aggregator can still expire the producer past its TTL",
        )

    def stalled_source_freshness(self) -> None:
        """A stalled driver must age out instead of looking fresh forever."""
        self.check(
            exporter.source_sequences_of(
                [
                    {"adapter": 2, "sequence": 9},
                    {"adapter": 1, "sequence": 4},
                ]
            )
            == {"i2c2": 9, "i2c1": 4},
            "driver sequences are tracked per adapter",
        )
        first = exporter.publication_state(None, {"i2c2": 9, "i2c1": 4}, 1000)
        self.check(
            first["sequence"] == 1 and first["observed_ms"] == 1000,
            "first publication stamps the current observation time",
        )
        unchanged = exporter.publication_state(first, {"i2c2": 9, "i2c1": 4}, 5000)
        self.check(
            unchanged["sequence"] == 1 and unchanged["observed_ms"] == 1000,
            "unchanged driver sequences do not refresh the observation time",
        )
        advanced = exporter.publication_state(unchanged, {"i2c2": 10, "i2c1": 4}, 6000)
        self.check(
            advanced["sequence"] == 2 and advanced["observed_ms"] == 6000,
            "advanced driver sequences publish a new observation time",
        )

    def unit_contract(self) -> None:
        unit = UNIT.read_text(encoding="utf-8")
        unit_directives = {
            line.strip()
            for line in unit.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        postinst = POSTINST.read_text(encoding="utf-8")
        producer = PRODUCER.read_text(encoding="utf-8")
        self.check(
            "ExecStart=/opt/pim/bin/max9296_health_export.py --interval-ms 1000"
            in unit,
            "static service runs the packaged producer at one-second cadence",
        )
        self.check(
            "[Install]" not in unit_directives
            and "camera-max9296-health" not in postinst,
            "package does not enable or start the producer",
        )
        self.check(
            all(
                token not in producer
                for token in (
                    "systemctl",
                    "modprobe",
                    "rmmod",
                    "reboot",
                    "restart_flag",
                )
            ),
            "producer contains no recovery or process-control command",
        )


if __name__ == "__main__":
    raise SystemExit(Tests().run())
