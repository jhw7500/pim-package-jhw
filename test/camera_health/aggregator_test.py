#!/usr/bin/env python3
"""Board-independent tests for the read-only camera health aggregator."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "dist/pim/opt/pim/bin/camera_healthd.py"
REGISTRY_PATH = ROOT / "dist/pim/opt/pim/config/camera_health_error_codes_v1.json"
DOC_REGISTRY_PATH = ROOT / "docs/camera-health/error-codes-v1.json"
FIXTURES = Path(__file__).resolve().parent / "fixtures/valid"

spec = importlib.util.spec_from_file_location("camera_healthd", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load camera_healthd.py")
healthd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(healthd)


BOOT_ID = "f37e65b6-9d83-4bba-a722-79f10825d607"
NOW_MS = 122_000
TTL_MS = 3_000


def load(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write(path: Path, document: Dict[str, Any]) -> None:
    path.write_text(json.dumps(document), encoding="utf-8")


def evidence(name: str, value: object) -> List[Dict[str, Any]]:
    return [{"name": name, "source": "offline-test", "value": value}]


def observation(
    block: str,
    status: str,
    code: str,
    scope_id: str = "ch0",
    scope_kind: str = "channel",
    root: object = None,
    channels: object = None,
) -> Dict[str, Any]:
    scope: Dict[str, Any] = {"kind": scope_kind, "id": scope_id}
    if channels is not None:
        scope["channels"] = channels
    item: Dict[str, Any] = {
        "block": block,
        "scope": scope,
        "status": status,
        "code": code,
        "count": 1 if status == "FAIL" else 0,
        "evidence": evidence("test", True),
    }
    if root is not None:
        item["root_cause"] = root
    if status == "BLOCKED":
        item["blocked_by"] = ["gmsl_link"]
    return item


def snapshot(
    producer: str, observations: Iterable[Dict[str, Any]], sequence: int = 1
) -> Dict[str, Any]:
    items = list(observations)
    return {
        "schema": 1,
        "producer": producer,
        "boot_id": BOOT_ID,
        "pid": 100,
        "sequence": sequence,
        "observed_monotonic_ms": NOW_MS - 500,
        "status": "FAIL" if any(item["status"] == "FAIL" for item in items) else "OK",
        "observations": items,
    }


def roots(document: Dict[str, Any]) -> set[tuple[str, str]]:
    return {(item["block"], item["code"]) for item in document["root_causes"]}


class Tests:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0
        self.registry = healthd.load_registry(REGISTRY_PATH)

    def check(self, condition: bool, label: str) -> None:
        if condition:
            self.passed += 1
            print(f"  OK   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}", file=sys.stderr)

    def aggregate(self, directory: Path, now_ms: int = NOW_MS) -> Dict[str, Any]:
        return healthd.aggregate(directory, BOOT_ID, now_ms, TTL_MS, self.registry)

    def run(self) -> int:
        print("=== camera health shadow aggregator ===")
        self.check(
            REGISTRY_PATH.read_bytes() == DOC_REGISTRY_PATH.read_bytes(),
            "installed error registry matches documentation source",
        )
        with tempfile.TemporaryDirectory(prefix="camera-health-test.") as temporary:
            work = Path(temporary)
            self.fixture_and_dual_test(work)
            self.ser_branch_test(work)
            self.stale_malformed_test(work)
            self.root_cause_test(work)
            self.disabled_and_boot_test(work)
            self_cli_test(work, self)
        print()
        print(f"camera health aggregator: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0

    def clear(self, work: Path) -> None:
        for name in ("max9296.json", "gstApp.json", "pim-probe.json", "aggregate.json"):
            try:
                (work / name).unlink()
            except FileNotFoundError:
                pass

    def fixture_and_dual_test(self, work: Path) -> None:
        self.clear(work)
        max_snapshot = load(FIXTURES / "max9296_link_down.json")
        gst_snapshot = load(FIXTURES / "gstapp_healthy.json")
        write(work / "max9296.json", max_snapshot)
        write(work / "gstApp.json", gst_snapshot)
        result = self.aggregate(work)
        self.check(result["overall_status"] == "FAILED", "link-down makes aggregate FAILED")
        self.check(
            ("gmsl_link", "GMSL_LINK_DOWN") in roots(result),
            "GMSL link is preserved as root cause",
        )
        self.check(
            result["channel_masks"] == {
                "configured_channel_mask": 3,
                "physical_present_mask": 2,
                "stream_domain_active_mask": 0,
            },
            "dual-wide three masks remain distinct",
        )
        self.check(result["stream_mode"] == "dual-wide", "dual-wide mode preserved")
        self.check(
            result["legacy_write"] is False and result["recovery_requested"] is False,
            "shadow output cannot own legacy flag or recovery",
        )

    def ser_branch_test(self, work: Path) -> None:
        self.clear(work)
        write(work / "max9296.json", load(FIXTURES / "ser_management_failure.json"))
        result = self.aggregate(work)
        status_by_block = {
            item["block"]: item["status"] for item in result["observations"]
        }
        self.check(
            roots(result) == {("serializer", "SER_DEVICE_ID_FAIL")},
            "SER management-only failure does not become GMSL failure",
        )
        self.check(status_by_block.get("isp") == "OK", "independent ISP evidence retained")
        self.check(status_by_block.get("sensor") == "OK", "independent Sensor evidence retained")

    def stale_malformed_test(self, work: Path) -> None:
        self.clear(work)
        stale = snapshot("max9296", [observation("deserializer", "OK", "NONE")])
        stale["observed_monotonic_ms"] = NOW_MS - TTL_MS - 1
        write(work / "max9296.json", stale)
        malformed = snapshot(
            "gstApp", [observation("gstreamer", "FAIL", "GSTREAMER_PIPELINE_ERROR")]
        )
        malformed["observations"][0]["code"] = "UNREGISTERED_FAILURE"
        write(work / "gstApp.json", malformed)
        result = self.aggregate(work)
        state = {item["producer"]: item for item in result["producers"]}
        self.check(
            state["max9296"]["code"] == "PRODUCER_STALE",
            "TTL expiry becomes UNKNOWN/PRODUCER_STALE",
        )
        self.check(
            state["gstApp"]["code"] == "PRODUCER_MALFORMED",
            "unregistered code rejects producer snapshot",
        )
        self.check(result["overall_status"] == "DEGRADED", "invalid producers degrade, not fail")
        self.check(not result["root_causes"], "stale/malformed evidence is not a hardware root")

        self.clear(work)
        inconsistent = snapshot(
            "max9296", [observation("gmsl_link", "FAIL", "GMSL_LINK_DOWN")]
        )
        inconsistent["status"] = "OK"
        inconsistent["channel_masks"] = {
            "configured_channel_mask": 3,
            "physical_present_mask": 3,
            "stream_domain_active_mask": 31,
        }
        write(work / "max9296.json", inconsistent)
        result = self.aggregate(work)
        state = {item["producer"]: item for item in result["producers"]}
        self.check(
            state["max9296"]["code"] == "PRODUCER_MALFORMED",
            "invalid masks/top-level status reject producer",
        )

    def root_cause_test(self, work: Path) -> None:
        self.clear(work)
        max_items = [
            observation("gmsl_link", "FAIL", "GMSL_LINK_DOWN", "phy-a", "link", channels=[0]),
            observation("csi2", "FAIL", "CSI2_NO_PROGRESS", "csi0", "csi", channels=[0, 1]),
            observation("capture", "FAIL", "CAPTURE_DQBUF_TIMEOUT", "csi0-dual", "pair", channels=[0, 1]),
        ]
        gst_items = [
            observation("gstreamer", "FAIL", "GSTREAMER_ENCODER_STALL", "ch0", channels=[0]),
            observation("recording", "FAIL", "STORAGE_READ_ONLY"),
        ]
        write(work / "max9296.json", snapshot("max9296", max_items))
        write(work / "gstApp.json", snapshot("gstApp", gst_items))
        result = self.aggregate(work)
        self.check(
            roots(result)
            == {("gmsl_link", "GMSL_LINK_DOWN"), ("recording", "STORAGE_READ_ONLY")},
            "upstream GMSL suppresses cascade while storage remains concurrent root",
        )
        self.check(len(result["observations"]) == 5, "all concurrent evidence remains visible")

        self.clear(work)
        write(
            work / "max9296.json",
            snapshot(
                "max9296",
                [
                    observation("deserializer", "FAIL", "DES_I2C_FAIL", "max9296-0", "global"),
                    observation("csi2", "FAIL", "CSI2_NO_PROGRESS", "csi0", "csi"),
                ],
            ),
        )
        result = self.aggregate(work)
        self.check(
            roots(result)
            == {("deserializer", "DES_I2C_FAIL"), ("csi2", "CSI2_NO_PROGRESS")},
            "DES control failure does not erase independent CSI evidence",
        )

        self.clear(work)
        non_root_failure = observation(
            "capture", "FAIL", "CAPTURE_PATH_STALL", "csi0", "csi", root=False
        )
        write(work / "pim-probe.json", snapshot("pim-healthd", [non_root_failure]))
        result = self.aggregate(work)
        self.check(
            result["overall_status"] == "FAILED" and not result["root_causes"],
            "unresolved non-root failure still makes overall FAILED",
        )

    def disabled_and_boot_test(self, work: Path) -> None:
        self.clear(work)
        disabled = snapshot(
            "max9296", [observation("sensor", "N/A", "DISABLED", "ch3")]
        )
        write(work / "max9296.json", disabled)
        result = self.aggregate(work)
        self.check(result["status"] != "FAIL", "disabled block is excluded from failure")
        self.check(not result["root_causes"], "disabled block is never a root cause")

        wrong_boot = snapshot(
            "gstApp", [observation("gstreamer", "FAIL", "GSTREAMER_PIPELINE_ERROR")]
        )
        wrong_boot["boot_id"] = "previous-boot"
        write(work / "gstApp.json", wrong_boot)
        result = self.aggregate(work)
        state = {item["producer"]: item for item in result["producers"]}
        self.check(
            state["gstApp"]["reason"] == "boot_id_mismatch",
            "previous-boot producer is rejected as stale",
        )
        self.check(
            ("gstreamer", "GSTREAMER_PIPELINE_ERROR") not in roots(result),
            "previous-boot failure cannot become current root",
        )


def self_cli_test(work: Path, tests: Tests) -> None:
    tests.clear(work)
    write(
        work / "gstApp.json",
        snapshot("gstApp", [observation("gstreamer", "OK", "NONE")]),
    )
    boot_file = work / "boot_id"
    output = work / "aggregate.json"
    sentinel = work / "bg_chk_flag.bin"
    boot_file.write_text(BOOT_ID, encoding="utf-8")
    sentinel.write_bytes(b"legacy-owner-sentinel")
    command = [
        sys.executable,
        str(MODULE_PATH),
        "--once",
        "--input-dir",
        str(work),
        "--output",
        str(output),
        "--boot-id-file",
        str(boot_file),
        "--registry",
        str(REGISTRY_PATH),
        "--now-monotonic-ms",
        str(NOW_MS),
    ]
    subprocess.run(command, check=True)
    document = load(output)
    tests.check(document["mode"] == "shadow", "CLI publishes shadow mode atomically")
    tests.check(oct(output.stat().st_mode & 0o777) == "0o640", "aggregate output mode is 0640")
    tests.check(
        sentinel.read_bytes() == b"legacy-owner-sentinel",
        "CLI does not modify legacy error flag",
    )
    tests.check(
        not list(work.glob(".aggregate.json.*")),
        "atomic writer leaves no temporary output",
    )

    # The boot ID is read once at startup. An unreadable or empty file must end
    # the process with a diagnosable message instead of an unhandled
    # SnapshotError, which is what killed the daemon mid-run when the read lived
    # inside the polling loop.
    for label, prepare in (
        ("empty", lambda path: path.write_text("\n", encoding="utf-8")),
        ("missing", lambda path: path.unlink()),
    ):
        boot_file.write_text(BOOT_ID, encoding="utf-8")
        prepare(boot_file)
        failed = subprocess.run(command, check=False, capture_output=True, text=True)
        tests.check(
            failed.returncode != 0,
            f"{label} boot ID file fails at startup",
        )
        tests.check(
            "cannot read boot ID" in failed.stderr and "Traceback" not in failed.stderr,
            f"{label} boot ID file reports a diagnosable startup error",
        )


if __name__ == "__main__":
    raise SystemExit(Tests().run())
