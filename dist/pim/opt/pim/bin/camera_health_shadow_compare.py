#!/usr/bin/env python3
"""Compare legacy camera flags with health v1 without owning recovery."""

from __future__ import annotations

import argparse
import json
import os
import signal
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Set, Tuple


PRODUCERS = {"max9296", "gstApp", "pim-healthd"}
AGGREGATE_STATUSES = {"OK", "FAIL", "UNKNOWN", "STARTING"}
LEGACY_COMPARABLE_BLOCKS = {
    "sensor",
    "isp",
    "serializer",
    "gmsl_link",
    "deserializer",
}
CLASSIFICATIONS = {
    "AGREE_HEALTHY",
    "AGREE_FAILED",
    "AGREE_FAILED_UNSCOPED",
    "AGREE_FAILED_SCOPE_DIFF",
    "DISAGREE_SCOPE",
    "LEGACY_ONLY_FAILURE",
    "V1_ONLY_FAILURE",
    "LEGACY_ONLY",
    "EXPECTED_DOWNTIME",
    "INCONCLUSIVE",
}
MAINTENANCE_FLAGS = ("init_cam_flag", "restart_flag", "kill_flag")


class CompareError(ValueError):
    """A comparison input is malformed or unsafe to interpret."""


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def load_json_object(path: Path, label: str) -> Dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CompareError(f"{label} unavailable: {path}: {exc}") from exc
    if not isinstance(document, dict):
        raise CompareError(f"{label} must be an object")
    return document


def load_expectation(path: Path, boot_id: str) -> Tuple[int, Dict[str, Set[int]]]:
    document = load_json_object(path, "expectation")
    if document.get("schema") != 1 or document.get("boot_id") != boot_id:
        raise CompareError("expectation schema/boot mismatch")
    configured_mask = document.get("configured_channel_mask")
    if not _is_int(configured_mask) or configured_mask < 0 or configured_mask > 15:
        raise CompareError("expectation configured mask is invalid")
    domains = document.get("domains")
    if not isinstance(domains, list) or not domains:
        raise CompareError("expectation domains are invalid")
    scopes: Dict[str, Set[int]] = {}
    derived_mask = 0
    for item in domains:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise CompareError("expectation domain is invalid")
        domain_id = item["id"]
        active = item.get("active_channels")
        if (
            domain_id in scopes
            or not isinstance(active, list)
            or any(not _is_int(channel) or channel < 0 or channel > 3 for channel in active)
            or len(set(active)) != len(active)
        ):
            raise CompareError(f"expectation domain {domain_id!r} is invalid")
        scopes[domain_id] = set(active)
        for channel in active:
            derived_mask |= 1 << channel
    if derived_mask != configured_mask:
        raise CompareError("expectation configured mask is inconsistent")
    return configured_mask, scopes


def read_legacy(legacy_dir: Path, configured_mask: int) -> Dict[str, Any]:
    flag_path = legacy_dir / "bg_chk_flag.bin"
    maintenance = [name for name in MAINTENANCE_FLAGS if (legacy_dir / name).is_file()]
    try:
        raw_text = flag_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        return {
            "state": "INVALID",
            "reason": f"bg_flag_unavailable:{exc}",
            "bg_flag_path": str(flag_path),
            "maintenance_flags": maintenance,
        }
    try:
        raw_bits = int(raw_text, 10)
    except ValueError:
        return {
            "state": "INVALID",
            "reason": "bg_flag_not_decimal",
            "bg_flag_path": str(flag_path),
            "raw": raw_text,
            "maintenance_flags": maintenance,
        }
    if raw_bits < 0 or raw_bits > 255:
        return {
            "state": "INVALID",
            "reason": "bg_flag_out_of_range",
            "bg_flag_path": str(flag_path),
            "raw": raw_text,
            "maintenance_flags": maintenance,
        }

    bg_camera_mask = raw_bits & 0x0F
    error_log_mask = sum(
        1 << channel
        for channel in range(4)
        if (legacy_dir / f"err_cam{channel}.log").is_file()
    )
    streak: Optional[int] = None
    try:
        streak_text = (legacy_dir / "cam_state/streak").read_text(encoding="utf-8").strip()
        parsed_streak = int(streak_text, 10)
        if parsed_streak >= 0:
            streak = parsed_streak
    except (OSError, ValueError):
        pass

    return {
        "state": "OK" if bg_camera_mask == error_log_mask else "TRANSIENT",
        "reason": "stable" if bg_camera_mask == error_log_mask else "bg_flag_error_log_race",
        "bg_flag_path": str(flag_path),
        "raw_bits": raw_bits,
        "bg_camera_mask": bg_camera_mask,
        "error_log_mask": error_log_mask,
        "configured_camera_mask": configured_mask,
        "active_camera_mask": bg_camera_mask & configured_mask,
        "inactive_camera_mask": bg_camera_mask & (~configured_mask & 0x0F),
        "maintenance_flags": maintenance,
        "recovery_request": (legacy_dir / "recover_req_init_cam").is_file(),
        "recovery_state": (legacy_dir / "cam_recovery.json").is_file(),
        "streak": streak,
    }


def load_aggregate(
    path: Path, boot_id: str, now_ms: int, max_age_ms: int
) -> Tuple[Optional[Dict[str, Any]], Dict[str, Any]]:
    try:
        document = load_json_object(path, "aggregate")
        if document.get("schema") != 1 or document.get("mode") != "shadow":
            raise CompareError("aggregate is not shadow schema 1")
        if document.get("boot_id") != boot_id:
            raise CompareError("aggregate belongs to another boot")
        if document.get("legacy_write") is not False or document.get("recovery_requested") is not False:
            raise CompareError("aggregate violates read-only shadow contract")
        observed = document.get("observed_monotonic_ms")
        if not _is_int(observed) or observed < 0:
            raise CompareError("aggregate monotonic timestamp is invalid")
        age_ms = now_ms - observed
        if age_ms < 0 or age_ms > max_age_ms:
            raise CompareError(f"aggregate age is invalid:{age_ms}")
        status = document.get("status")
        if status not in AGGREGATE_STATUSES:
            raise CompareError("aggregate status is invalid")
        observations = document.get("observations")
        producers = document.get("producers")
        if not isinstance(observations, list) or not isinstance(producers, list):
            raise CompareError("aggregate observations/producers are invalid")
        producer_states: Dict[str, str] = {}
        for item in producers:
            if not isinstance(item, dict):
                raise CompareError("aggregate producer state is invalid")
            producer = item.get("producer")
            state = item.get("state")
            if producer not in PRODUCERS or producer in producer_states or not isinstance(state, str):
                raise CompareError("aggregate producer state is invalid")
            producer_states[producer] = state
        if set(producer_states) != PRODUCERS:
            raise CompareError("aggregate producer set is incomplete")
        return document, {
            "state": "OK",
            "reason": "fresh",
            "age_ms": age_ms,
            "producer_states": producer_states,
            "complete": all(state == "OK" for state in producer_states.values()),
        }
    except CompareError as exc:
        return None, {"state": "INVALID", "reason": str(exc), "complete": False}


def resolve_scope_channels(
    scope: Mapping[str, Any],
    configured_mask: int,
    domain_scopes: Mapping[str, Set[int]],
) -> Optional[Set[int]]:
    configured = {channel for channel in range(4) if configured_mask & (1 << channel)}
    channels = scope.get("channels")
    if isinstance(channels, list) and all(_is_int(channel) for channel in channels):
        return {int(channel) for channel in channels if 0 <= int(channel) <= 3} & configured
    if scope.get("kind") in {"camera-domain", "global"}:
        return configured
    if isinstance(scope.get("id"), str) and scope["id"] in domain_scopes:
        return set(domain_scopes[scope["id"]]) & configured
    return None


def failure_scope(
    aggregate: Mapping[str, Any],
    configured_mask: int,
    domain_scopes: Mapping[str, Set[int]],
) -> Tuple[int, bool]:
    failure_mask = 0
    unscoped = False
    for item in aggregate["observations"]:
        if (
            not isinstance(item, dict)
            or item.get("status") != "FAIL"
            or item.get("block") not in LEGACY_COMPARABLE_BLOCKS
        ):
            continue
        scope = item.get("scope")
        if not isinstance(scope, dict):
            unscoped = True
            continue
        resolved = resolve_scope_channels(scope, configured_mask, domain_scopes)
        if resolved is None:
            unscoped = True
            continue
        for channel in resolved:
            failure_mask |= 1 << channel
    return failure_mask & configured_mask, unscoped


def v1_camera_status(
    aggregate: Mapping[str, Any],
    configured_mask: int,
    domain_scopes: Mapping[str, Set[int]],
) -> str:
    if configured_mask == 0:
        return "N/A"
    statuses = []
    for item in aggregate["observations"]:
        if not isinstance(item, dict) or item.get("block") not in LEGACY_COMPARABLE_BLOCKS:
            continue
        scope = item.get("scope")
        if not isinstance(scope, dict):
            statuses.append("UNKNOWN")
            continue
        resolved = resolve_scope_channels(scope, configured_mask, domain_scopes)
        if resolved == set():
            continue
        statuses.append(item.get("status"))
    if not statuses:
        return "UNKNOWN"
    if "FAIL" in statuses:
        return "FAIL"
    if any(status in {"UNKNOWN", "STARTING", "BLOCKED"} for status in statuses):
        return "UNKNOWN"
    return "OK" if all(status in {"OK", "N/A"} for status in statuses) else "UNKNOWN"


def classify(
    legacy: Mapping[str, Any],
    aggregate: Optional[Mapping[str, Any]],
    aggregate_state: Mapping[str, Any],
    camera_status: str,
    v1_failure_mask: int,
    v1_unscoped_failure: bool,
) -> Tuple[str, str]:
    if legacy.get("maintenance_flags"):
        return "EXPECTED_DOWNTIME", "legacy maintenance flag is active"
    if legacy.get("state") != "OK":
        return "INCONCLUSIVE", str(legacy.get("reason", "legacy input invalid"))
    if aggregate is None or aggregate_state.get("state") != "OK":
        return "LEGACY_ONLY", str(aggregate_state.get("reason", "aggregate unavailable"))
    if aggregate_state.get("complete") is not True:
        return "LEGACY_ONLY", "one or more v1 producers are unavailable/stale"
    if camera_status not in {"OK", "FAIL"}:
        return "INCONCLUSIVE", f"v1 comparable camera status is {camera_status}"

    legacy_mask = int(legacy["active_camera_mask"])
    legacy_failed = legacy_mask != 0
    v1_failed = camera_status == "FAIL"
    if not legacy_failed and not v1_failed:
        return "AGREE_HEALTHY", "legacy and v1 report no active camera failure"
    if legacy_failed and not v1_failed:
        return "LEGACY_ONLY_FAILURE", "legacy reports a camera failure; v1 reports OK"
    if v1_failed and not legacy_failed:
        return "V1_ONLY_FAILURE", "v1 reports a failure; legacy camera mask is clear"
    if v1_failure_mask == legacy_mask:
        return "AGREE_FAILED", "legacy and v1 failure channel masks match"
    if v1_failure_mask == 0 and v1_unscoped_failure:
        return "AGREE_FAILED_UNSCOPED", "both report failure; v1 cannot attribute a channel"
    if v1_failure_mask & legacy_mask:
        return "AGREE_FAILED_SCOPE_DIFF", "both report failure with partially different channel scope"
    return "DISAGREE_SCOPE", "both report failure on non-overlapping channel scope"


def update_statistics(
    previous_path: Path, boot_id: str, classification: str, now_ms: int
) -> Dict[str, Any]:
    samples = 0
    sequence = 0
    counts = {name: 0 for name in sorted(CLASSIFICATIONS)}
    previous_classification: Optional[str] = None
    current_run_length = 0
    last_transition_ms = now_ms
    try:
        previous = load_json_object(previous_path, "previous comparison")
        statistics = previous.get("statistics")
        if previous.get("schema") == 1 and previous.get("boot_id") == boot_id and isinstance(statistics, dict):
            old_counts = statistics.get("class_counts")
            if isinstance(old_counts, dict):
                for name in counts:
                    value = old_counts.get(name)
                    if _is_int(value) and value >= 0:
                        counts[name] = value
            old_samples = statistics.get("samples")
            old_sequence = statistics.get("comparison_sequence")
            old_run = statistics.get("current_run_length")
            old_transition = statistics.get("last_transition_monotonic_ms")
            if _is_int(old_samples) and old_samples >= 0:
                samples = old_samples
            if _is_int(old_sequence) and old_sequence >= 0:
                sequence = old_sequence
            if _is_int(old_run) and old_run >= 0:
                current_run_length = old_run
            if _is_int(old_transition) and 0 <= old_transition <= now_ms:
                last_transition_ms = old_transition
            old_classification = previous.get("classification")
            if old_classification in CLASSIFICATIONS:
                previous_classification = old_classification
    except CompareError:
        pass

    counts[classification] += 1
    if previous_classification == classification:
        current_run_length += 1
    else:
        current_run_length = 1
        last_transition_ms = now_ms
    return {
        "comparison_sequence": sequence + 1,
        "samples": samples + 1,
        "class_counts": counts,
        "current_run_length": current_run_length,
        "last_transition_monotonic_ms": last_transition_ms,
    }


def compare_once(
    aggregate_path: Path,
    expectation_path: Path,
    legacy_dir: Path,
    output_path: Path,
    boot_id: str,
    now_ms: int,
    max_age_ms: int,
) -> Dict[str, Any]:
    try:
        configured_mask, domain_scopes = load_expectation(expectation_path, boot_id)
        expectation_state: Dict[str, Any] = {
            "state": "OK",
            "path": str(expectation_path),
            "configured_channel_mask": configured_mask,
        }
    except CompareError as exc:
        configured_mask, domain_scopes = 0, {}
        expectation_state = {"state": "INVALID", "path": str(expectation_path), "reason": str(exc)}

    legacy = read_legacy(legacy_dir, configured_mask)
    aggregate, aggregate_state = load_aggregate(aggregate_path, boot_id, now_ms, max_age_ms)
    if expectation_state["state"] != "OK":
        classification, reason = "INCONCLUSIVE", "configuration expectation is invalid"
        v1_failure_mask, v1_unscoped, camera_status = 0, False, "UNKNOWN"
    else:
        v1_failure_mask, v1_unscoped = (
            failure_scope(aggregate, configured_mask, domain_scopes)
            if aggregate is not None
            else (0, False)
        )
        camera_status = (
            v1_camera_status(aggregate, configured_mask, domain_scopes)
            if aggregate is not None
            else "UNKNOWN"
        )
        classification, reason = classify(
            legacy,
            aggregate,
            aggregate_state,
            camera_status,
            v1_failure_mask,
            v1_unscoped,
        )

    statistics = update_statistics(output_path, boot_id, classification, now_ms)
    return {
        "schema": 1,
        "mode": "shadow-compare",
        "boot_id": boot_id,
        "observed_monotonic_ms": now_ms,
        "classification": classification,
        "reason": reason,
        "legacy_owner": True,
        "decision_authority": "legacy",
        "recovery_requested": False,
        "expectation": expectation_state,
        "legacy": legacy,
        "v1": {
            **aggregate_state,
            "path": str(aggregate_path),
            "status": aggregate.get("status") if aggregate is not None else None,
            "comparable_camera_status": camera_status,
            "failure_channel_mask": v1_failure_mask,
            "unscoped_failure": v1_unscoped,
        },
        "statistics": statistics,
    }


def atomic_write(path: Path, document: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(document, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o640)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aggregate", type=Path, default=Path("/run/pim-camera/aggregate-shadow.json"))
    parser.add_argument("--expectation", type=Path, default=Path("/run/pim-camera/config-expectation.json"))
    parser.add_argument("--legacy-dir", type=Path, default=Path("/tmp"))
    parser.add_argument("--output", type=Path, default=Path("/run/pim-camera/shadow-comparison.json"))
    parser.add_argument("--boot-id-file", type=Path, default=Path("/proc/sys/kernel/random/boot_id"))
    parser.add_argument("--max-age-ms", type=int, default=3000)
    parser.add_argument("--interval-ms", type=int, default=1000)
    parser.add_argument("--now-monotonic-ms", type=int)
    parser.add_argument("--once", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.max_age_ms < 1 or args.interval_ms < 1:
        raise SystemExit("max age and interval must be positive")
    boot_id = args.boot_id_file.read_text(encoding="utf-8").strip()
    if not boot_id:
        raise SystemExit("boot ID is empty")
    stopped = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not stopped:
        now_ms = (
            args.now_monotonic_ms
            if args.now_monotonic_ms is not None
            else time.monotonic_ns() // 1_000_000
        )
        document = compare_once(
            args.aggregate,
            args.expectation,
            args.legacy_dir,
            args.output,
            boot_id,
            now_ms,
            args.max_age_ms,
        )
        atomic_write(args.output, document)
        if args.once:
            break
        time.sleep(args.interval_ms / 1000.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
