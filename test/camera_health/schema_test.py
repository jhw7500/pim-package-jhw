#!/usr/bin/env python3
"""Offline validation for the camera health v1 contract."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError as exc:  # pragma: no cover - explicit developer dependency error
    raise SystemExit("python3-jsonschema is required for schema_test.py") from exc


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "docs/camera-health/health-v1.schema.json"
REGISTRY_PATH = ROOT / "docs/camera-health/error-codes-v1.json"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
BLOCKS = {
    "sensor",
    "isp",
    "serializer",
    "gmsl_link",
    "deserializer",
    "csi2",
    "capture",
    "gstreamer",
    "recording",
}
CODE_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")


def load(path: Path) -> object:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def validate_registry(registry: dict) -> dict[str, dict]:
    assert registry.get("schema") == 1, "error registry schema must be 1"
    indexed: dict[str, dict] = {}
    for item in registry.get("codes", []):
        code = item["code"]
        assert CODE_RE.fullmatch(code), f"invalid error code syntax: {code}"
        assert code not in indexed, f"duplicate error code: {code}"
        assert item["block"] in BLOCKS | {"any"}, f"unknown registry block: {item['block']}"
        assert isinstance(item["destructive_recovery"], bool), f"invalid recovery flag: {code}"
        indexed[code] = item
    assert "NONE" in indexed and "DISABLED" in indexed
    return indexed


def semantic_errors(snapshot: dict, registry: dict[str, dict]) -> list[str]:
    errors: list[str] = []
    top_time = snapshot.get("observed_monotonic_ms", 0)
    for index, observation in enumerate(snapshot.get("observations", [])):
        prefix = f"observations[{index}]"
        status = observation.get("status")
        code = observation.get("code")
        block = observation.get("block")
        if code not in registry:
            errors.append(f"{prefix}: code is not registered: {code}")
            continue
        if status == "OK" and code != "NONE":
            errors.append(f"{prefix}: OK requires code=NONE")
        if status == "N/A" and code != "DISABLED":
            errors.append(f"{prefix}: N/A requires code=DISABLED")
        if status == "FAIL" and code in {"NONE", "DISABLED"}:
            errors.append(f"{prefix}: FAIL requires a failure code")
        if status == "BLOCKED" and not observation.get("blocked_by"):
            errors.append(f"{prefix}: BLOCKED requires blocked_by")
        registered_block = registry[code]["block"]
        if status == "FAIL" and registered_block not in {"any", block}:
            errors.append(
                f"{prefix}: code {code} belongs to {registered_block}, not {block}"
            )
        first = observation.get("first_seen_monotonic_ms")
        last = observation.get("last_seen_monotonic_ms")
        if first is not None and last is not None and first > last:
            errors.append(f"{prefix}: first_seen is after last_seen")
        if last is not None and last > top_time:
            errors.append(f"{prefix}: last_seen is newer than snapshot")
    return errors


def main() -> int:
    schema = load(SCHEMA_PATH)
    registry = validate_registry(load(REGISTRY_PATH))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)

    failures: list[str] = []
    valid_paths = sorted((FIXTURES / "valid").glob("*.json"))
    invalid_paths = sorted((FIXTURES / "invalid").glob("*.json"))
    assert valid_paths, "no valid fixtures"
    assert invalid_paths, "no invalid fixtures"

    for path in valid_paths:
        snapshot = load(path)
        problems = [error.message for error in validator.iter_errors(snapshot)]
        problems.extend(semantic_errors(snapshot, registry))
        if problems:
            failures.append(f"valid fixture rejected: {path.name}: {'; '.join(problems)}")

    for path in invalid_paths:
        snapshot = load(path)
        problems = [error.message for error in validator.iter_errors(snapshot)]
        if not problems:
            problems.extend(semantic_errors(snapshot, registry))
        if not problems:
            failures.append(f"invalid fixture accepted: {path.name}")

    if failures:
        print("\n".join(f"FAIL: {failure}" for failure in failures), file=sys.stderr)
        return 1

    print(
        f"PASS: schema + {len(registry)} codes + "
        f"{len(valid_paths)} valid/{len(invalid_paths)} invalid fixtures"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
