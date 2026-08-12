#!/usr/bin/env python3
"""Offline tests for legacy versus health-v1 shadow comparison."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "dist/pim/opt/pim/bin/camera_health_shadow_compare.py"

spec = importlib.util.spec_from_file_location("camera_health_shadow_compare", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load camera_health_shadow_compare.py")
comparator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparator)


def expectation(mask: int, boot_id: str = "boot-a") -> Dict[str, Any]:
    return {
        "schema": 1,
        "boot_id": boot_id,
        "configured_channel_mask": mask,
        "domains": [
            {
                "id": "ch01",
                "active_channels": [channel for channel in (0, 1) if mask & (1 << channel)],
            },
            {
                "id": "ch23",
                "active_channels": [channel for channel in (2, 3) if mask & (1 << channel)],
            },
        ],
    }


def observation(
    block: str,
    status: str,
    channels: Optional[List[int]] = None,
    scope_id: str = "link-a",
    scope_kind: str = "link",
) -> Dict[str, Any]:
    scope: Dict[str, Any] = {"kind": scope_kind, "id": scope_id}
    if channels is not None:
        scope["channels"] = channels
    return {"block": block, "status": status, "scope": scope}


def aggregate(
    observations: List[Dict[str, Any]],
    status: str,
    observed_ms: int = 1000,
    producer_states: Optional[Dict[str, str]] = None,
    boot_id: str = "boot-a",
) -> Dict[str, Any]:
    states = producer_states or {
        "max9296": "OK",
        "gstApp": "OK",
        "pim-healthd": "OK",
    }
    return {
        "schema": 1,
        "mode": "shadow",
        "boot_id": boot_id,
        "observed_monotonic_ms": observed_ms,
        "status": status,
        "legacy_write": False,
        "recovery_requested": False,
        "observations": observations,
        "producers": [
            {"producer": producer, "state": states[producer]}
            for producer in ("max9296", "gstApp", "pim-healthd")
        ],
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

    def write_legacy(self, root: Path, mask: int, error_mask: Optional[int] = None) -> None:
        (root / "bg_chk_flag.bin").write_text(str(mask), encoding="utf-8")
        effective_error_mask = mask if error_mask is None else error_mask
        for channel in range(4):
            path = root / f"err_cam{channel}.log"
            if effective_error_mask & (1 << channel):
                path.write_text("legacy error\n", encoding="utf-8")
            elif path.exists():
                path.unlink()

    def compare(
        self,
        root: Path,
        legacy_mask: int,
        observations: List[Dict[str, Any]],
        aggregate_status: str,
        configured_mask: int = 3,
        error_mask: Optional[int] = None,
        producer_states: Optional[Dict[str, str]] = None,
        observed_ms: int = 1000,
        max_age_ms: int = 3000,
    ) -> Dict[str, Any]:
        self.write_legacy(root, legacy_mask, error_mask)
        expectation_path = root / "expectation.json"
        aggregate_path = root / "aggregate.json"
        output = root / "comparison.json"
        expectation_path.write_text(json.dumps(expectation(configured_mask)), encoding="utf-8")
        aggregate_path.write_text(
            json.dumps(
                aggregate(
                    observations,
                    aggregate_status,
                    observed_ms=observed_ms,
                    producer_states=producer_states,
                )
            ),
            encoding="utf-8",
        )
        return comparator.compare_once(
            aggregate_path,
            expectation_path,
            root,
            output,
            "boot-a",
            1100,
            max_age_ms,
        )

    def run(self) -> int:
        print("=== camera legacy/v1 shadow comparator ===")
        with tempfile.TemporaryDirectory(prefix="camera-shadow-compare.") as temporary:
            root = Path(temporary)
            self.classification_tests(root)
            self.input_state_tests(root)
            self.statistics_test(root)
            self.cli_test(root)
        print()
        print(f"camera shadow comparator: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0

    def classification_tests(self, root: Path) -> None:
        healthy = [observation("gmsl_link", "OK", [0, 1])]
        result = self.compare(root, 0, healthy, "OK")
        self.check(result["classification"] == "AGREE_HEALTHY", "stable healthy inputs agree")

        failed = [observation("gmsl_link", "FAIL", [0])]
        result = self.compare(root, 1, failed, "FAIL")
        self.check(
            result["classification"] == "AGREE_FAILED"
            and result["v1"]["failure_channel_mask"] == 1,
            "matching physical-link channel failures agree",
        )

        result = self.compare(root, 3, failed, "FAIL")
        self.check(
            result["classification"] == "AGREE_FAILED_SCOPE_DIFF",
            "dual-wide legacy pair expansion is retained as a scope difference",
        )

        ch1_failed = [observation("serializer", "FAIL", [1])]
        result = self.compare(root, 1, ch1_failed, "FAIL")
        self.check(result["classification"] == "DISAGREE_SCOPE", "non-overlapping failure scopes disagree")

        result = self.compare(root, 1, healthy, "OK")
        self.check(result["classification"] == "LEGACY_ONLY_FAILURE", "legacy-only failure is counted")

        result = self.compare(root, 0, failed, "FAIL")
        self.check(result["classification"] == "V1_ONLY_FAILURE", "v1-only physical failure is counted")

        unscoped = [observation("deserializer", "FAIL", None, "des-unknown", "pair")]
        result = self.compare(root, 1, unscoped, "FAIL")
        self.check(
            result["classification"] == "AGREE_FAILED_UNSCOPED"
            and result["v1"]["unscoped_failure"] is True,
            "unattributable v1 physical failure does not invent a channel",
        )

        storage_only = [
            observation("gmsl_link", "OK", [0, 1]),
            observation("recording", "FAIL", [0], "recording", "channel"),
        ]
        result = self.compare(root, 0, storage_only, "FAIL")
        self.check(
            result["classification"] == "AGREE_HEALTHY"
            and result["v1"]["status"] == "FAIL"
            and result["v1"]["comparable_camera_status"] == "OK",
            "recording/storage failure is not compared to legacy physical-link flags",
        )

        disabled_channel_failure = [
            observation("gmsl_link", "OK", [0]),
            observation("sensor", "FAIL", [1]),
        ]
        result = self.compare(
            root,
            0,
            disabled_channel_failure,
            "FAIL",
            configured_mask=1,
        )
        self.check(
            result["classification"] == "AGREE_HEALTHY",
            "failure evidence scoped only to a disabled channel is excluded",
        )

    def input_state_tests(self, root: Path) -> None:
        healthy = [observation("gmsl_link", "OK", [0, 1])]
        incomplete = {"max9296": "OK", "gstApp": "UNKNOWN", "pim-healthd": "OK"}
        result = self.compare(root, 0, healthy, "UNKNOWN", producer_states=incomplete)
        self.check(result["classification"] == "LEGACY_ONLY", "incomplete v1 producer set leaves legacy authoritative")

        result = self.compare(root, 0, healthy, "OK", observed_ms=0, max_age_ms=500)
        self.check(result["classification"] == "LEGACY_ONLY", "stale aggregate is not treated as healthy evidence")

        result = self.compare(root, 1, healthy, "OK", error_mask=0)
        self.check(result["classification"] == "INCONCLUSIVE", "legacy flag/error-log write race is inconclusive")

        flag = root / "bg_chk_flag.bin"
        if flag.exists():
            flag.unlink()
        (root / "init_cam_flag").touch()
        expectation_path = root / "expectation.json"
        aggregate_path = root / "aggregate.json"
        result = comparator.compare_once(
            aggregate_path,
            expectation_path,
            root,
            root / "comparison.json",
            "boot-a",
            1100,
            3000,
        )
        self.check(
            result["classification"] == "EXPECTED_DOWNTIME",
            "maintenance flag suppresses mismatch even while legacy flag is absent",
        )
        (root / "init_cam_flag").unlink()

        bad_expectation = expectation(3, boot_id="older-boot")
        expectation_path.write_text(json.dumps(bad_expectation), encoding="utf-8")
        self.write_legacy(root, 0)
        result = comparator.compare_once(
            aggregate_path,
            expectation_path,
            root,
            root / "comparison.json",
            "boot-a",
            1100,
            3000,
        )
        self.check(result["classification"] == "INCONCLUSIVE", "stale config expectation fails closed")

    def statistics_test(self, root: Path) -> None:
        output = root / "statistics.json"
        expectation_path = root / "expectation.json"
        aggregate_path = root / "aggregate.json"
        expectation_path.write_text(json.dumps(expectation(3)), encoding="utf-8")
        aggregate_path.write_text(
            json.dumps(aggregate([observation("gmsl_link", "OK", [0, 1])], "OK")),
            encoding="utf-8",
        )
        self.write_legacy(root, 0)
        first = comparator.compare_once(
            aggregate_path, expectation_path, root, output, "boot-a", 1100, 3000
        )
        comparator.atomic_write(output, first)
        second = comparator.compare_once(
            aggregate_path, expectation_path, root, output, "boot-a", 1200, 3000
        )
        self.check(
            second["statistics"]["samples"] == 2
            and second["statistics"]["class_counts"]["AGREE_HEALTHY"] == 2
            and second["statistics"]["current_run_length"] == 2,
            "boot-scoped soak counters survive comparator iterations",
        )

    def cli_test(self, root: Path) -> None:
        expectation_path = root / "expectation-cli.json"
        aggregate_path = root / "aggregate-cli.json"
        output = root / "comparison-cli.json"
        boot_id = root / "boot_id"
        boot_id.write_text("boot-a\n", encoding="utf-8")
        expectation_path.write_text(json.dumps(expectation(3)), encoding="utf-8")
        aggregate_path.write_text(
            json.dumps(aggregate([observation("gmsl_link", "OK", [0, 1])], "OK")),
            encoding="utf-8",
        )
        self.write_legacy(root, 0)
        subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--once",
                "--aggregate",
                str(aggregate_path),
                "--expectation",
                str(expectation_path),
                "--legacy-dir",
                str(root),
                "--output",
                str(output),
                "--boot-id-file",
                str(boot_id),
                "--now-monotonic-ms",
                "1100",
            ],
            check=True,
        )
        document = json.loads(output.read_text(encoding="utf-8"))
        self.check(
            document["legacy_owner"] is True
            and document["decision_authority"] == "legacy"
            and document["recovery_requested"] is False,
            "CLI output cannot claim recovery ownership",
        )
        self.check(oct(output.stat().st_mode & 0o777) == "0o640", "CLI output mode is 0640")
        self.check(not list(root.glob(".comparison-cli.json.*")), "CLI atomic write leaves no temporary")
        self.check(
            (root / "bg_chk_flag.bin").read_text(encoding="utf-8") == "0",
            "CLI leaves legacy flag content unchanged",
        )


if __name__ == "__main__":
    raise SystemExit(Tests().run())
