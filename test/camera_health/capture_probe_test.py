#!/usr/bin/env python3
"""Offline tests for the i.MX8MP CSI2/ISI read-only producer."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "dist/pim/opt/pim/bin/camera_capture_probe.py"
MAPPING_PATH = ROOT / "dist/pim/opt/pim/config/camera_capture_map_v1.json"
FIXTURES = Path(__file__).resolve().parent / "fixtures/interrupts"
SCHEMA_PATH = ROOT / "docs/camera-health/health-v1.schema.json"
REGISTRY_PATH = ROOT / "docs/camera-health/error-codes-v1.json"

spec = importlib.util.spec_from_file_location("camera_capture_probe", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load camera_capture_probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def load(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def by_block(document: Dict[str, Any], scope_id: str) -> Dict[str, Dict[str, Any]]:
    return {
        item["block"]: item
        for item in document["observations"]
        if item["scope"]["id"] == scope_id
    }


def evidence_value(item: Dict[str, Any], name: str) -> object:
    return next(value["value"] for value in item["evidence"] if value["name"] == name)


class Tests:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0
        self.mapping = probe.load_mapping(MAPPING_PATH)
        self.before = probe.parse_interrupts((FIXTURES / "before.txt").read_text())

    def check(self, condition: bool, label: str) -> None:
        if condition:
            self.passed += 1
            print(f"  OK   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}", file=sys.stderr)

    def snapshot(self, after_name: str, enabled: set[str], nodes: Path) -> Dict[str, Any]:
        after = probe.parse_interrupts((FIXTURES / after_name).read_text())
        return probe.build_snapshot(
            self.mapping,
            self.before,
            after,
            1000,
            enabled,
            nodes,
            "boot-a",
            1,
            1000,
        )

    def run(self) -> int:
        print("=== camera CSI2/capture probe ===")
        self.check(
            self.before["32e50000.csi"] == 400
            and self.before["32e02000.isi"] == 200,
            "per-CPU IRQ counters are summed by exact device label",
        )
        self.check(
            {"32e50000.csi", "32e02000.isi", "32e40000.csi", "32e00000.isi"}
            <= set(self.before),
            "all configured exact device labels are parsed",
        )
        with tempfile.TemporaryDirectory(prefix="capture-probe-test.") as temporary:
            nodes = Path(temporary)
            (nodes / "dev").mkdir()
            (nodes / "dev/video4").touch()
            self.good_test(nodes)
            self.no_progress_test(nodes)
            self.node_missing_test(nodes)
            self.unreliable_isi_test(nodes)
            self.counter_reset_test(nodes)
            self.missing_irq_test(nodes)
            self.no_expectation_test(nodes)
            self.cli_test(nodes)
        print()
        print(f"camera capture probe: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0

    def good_test(self, nodes: Path) -> None:
        result = self.snapshot("after_good.txt", {"ch01"}, nodes)
        ch01 = by_block(result, "csi1")
        self.check(ch01["csi2"]["status"] == "OK", "expected CSI2 progression is OK")
        self.check(ch01["capture"]["status"] == "OK", "reliable ISI activity is OK")
        self.check(
            evidence_value(ch01["csi2"], "csi_frame_rate") == 30.0,
            "CSI frame rate uses IRQ delta divided by two",
        )
        self.check(
            evidence_value(ch01["capture"], "csi_irq_per_isi_irq") == 2.0,
            "CSI/ISI ratio is retained",
        )
        self.check(result["status"] == "UNKNOWN", "unconfigured peer remains UNKNOWN, not false FAIL")

    def no_progress_test(self, nodes: Path) -> None:
        result = self.snapshot("before.txt", {"ch01"}, nodes)
        ch01 = by_block(result, "csi1")
        self.check(
            ch01["csi2"]["status"] == "UNKNOWN"
            and ch01["csi2"]["code"] == "CSI2_NO_PROGRESS"
            and ch01["csi2"]["root_cause"] is False,
            "single zero window is unresolved, not a confirmed CSI root",
        )
        self.check(
            ch01["capture"]["code"] == "CAPTURE_PATH_STALL",
            "zero CSI/ISI window reports unresolved capture path stall",
        )

    def node_missing_test(self, nodes: Path) -> None:
        (nodes / "dev/video4").unlink()
        result = self.snapshot("after_good.txt", {"ch01"}, nodes)
        ch01 = by_block(result, "csi1")
        self.check(ch01["csi2"]["status"] == "OK", "missing node does not erase CSI IRQ evidence")
        self.check(
            ch01["capture"]["status"] == "FAIL"
            and ch01["capture"]["code"] == "CAPTURE_NODE_MISSING",
            "missing expected video node is capture FAIL",
        )
        (nodes / "dev/video4").touch()

    def unreliable_isi_test(self, nodes: Path) -> None:
        result = self.snapshot("after_unreliable_isi.txt", {"ch01"}, nodes)
        ch01 = by_block(result, "csi1")
        self.check(ch01["csi2"]["status"] == "OK", "unreliable ISI does not degrade CSI2")
        self.check(
            ch01["capture"]["status"] == "UNKNOWN"
            and ch01["capture"]["code"] == "ISI_ACTIVITY_UNRELIABLE",
            "out-of-range ISI ratio is activity-only UNKNOWN",
        )

    def counter_reset_test(self, nodes: Path) -> None:
        result = self.snapshot("after_reset.txt", {"ch01"}, nodes)
        ch01 = by_block(result, "csi1")
        self.check(
            ch01["csi2"]["code"] == "IRQ_COUNTER_RESET"
            and ch01["capture"]["code"] == "IRQ_COUNTER_RESET",
            "decreasing IRQ counters are UNKNOWN reset, not failure",
        )

    def missing_irq_test(self, nodes: Path) -> None:
        incomplete = {"32e50000.csi": self.before["32e50000.csi"]}
        domain = self.mapping["domains"][0]
        csi, capture = probe.classify_domain(
            domain, incomplete, incomplete, 1000, True, True, 1.6, 2.4
        )
        self.check(
            csi["status"] == "UNKNOWN"
            and csi["code"] == "CSI2_NO_PROGRESS"
            and capture["code"] == "IRQ_SOURCE_MISSING",
            "missing ISI label preserves CSI evidence and marks capture UNKNOWN",
        )

    def no_expectation_test(self, nodes: Path) -> None:
        result = self.snapshot("before.txt", set(), nodes)
        ch01 = by_block(result, "csi1")
        self.check(
            ch01["csi2"]["code"] == "NO_STREAM_EXPECTATION"
            and ch01["csi2"]["status"] == "UNKNOWN",
            "zero activity without expectation is not a failure",
        )

    def cli_test(self, nodes: Path) -> None:
        output = nodes / "pim-probe.json"
        boot_id = nodes / "boot_id"
        boot_id.write_text("boot-cli", encoding="utf-8")
        subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--once",
                "--mapping",
                str(MAPPING_PATH),
                "--interrupts",
                str(FIXTURES / "before.txt"),
                "--interrupts-after",
                str(FIXTURES / "after_good.txt"),
                "--node-root",
                str(nodes),
                "--boot-id-file",
                str(boot_id),
                "--output",
                str(output),
                "--enabled-domains",
                "ch01",
                "--interval-ms",
                "1000",
            ],
            check=True,
        )
        result = load(output)
        schema_errors = list(Draft202012Validator(load(SCHEMA_PATH)).iter_errors(result))
        registry_codes = {item["code"] for item in load(REGISTRY_PATH)["codes"]}
        self.check(result["producer"] == "pim-healthd", "CLI publishes expected producer name")
        self.check(result["boot_id"] == "boot-cli", "CLI propagates current boot ID")
        self.check(not schema_errors, "CLI output validates against health v1 schema")
        self.check(
            all(item["code"] in registry_codes for item in result["observations"]),
            "CLI output uses only registered error codes",
        )
        self.check(oct(output.stat().st_mode & 0o777) == "0o640", "CLI output mode is 0640")
        self.check(not list(nodes.glob(".pim-probe.json.*")), "CLI atomic write leaves no temporary")


if __name__ == "__main__":
    raise SystemExit(Tests().run())
