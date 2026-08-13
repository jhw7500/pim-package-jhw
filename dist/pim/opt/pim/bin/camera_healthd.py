#!/usr/bin/env python3
"""Read-only camera health v1 shadow aggregator.

The shadow path never writes legacy flags and never requests recovery. It only
reads producer snapshots and atomically publishes a diagnostic aggregate.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple


BLOCKS: Tuple[str, ...] = (
    "sensor",
    "isp",
    "serializer",
    "gmsl_link",
    "deserializer",
    "csi2",
    "capture",
    "gstreamer",
    "recording",
)
BLOCK_SET = set(BLOCKS)
STATUSES = {"OK", "FAIL", "UNKNOWN", "STARTING", "BLOCKED", "N/A"}
SCOPE_KINDS = {"channel", "link", "pair", "csi", "camera-domain", "global"}
PRODUCERS = ("max9296", "gstApp", "pim-healthd")
STREAM_MODES = {"single", "independent", "dual-wide", "unknown"}
ACTION_SCOPES = {
    "none",
    "process",
    "pipeline",
    "link",
    "pair",
    "capture-domain",
    "camera-domain",
    "reboot",
}
PRODUCER_FILES = {
    "max9296": "max9296.json",
    "gstApp": "gstApp.json",
    "pim-healthd": "pim-probe.json",
}
CODE_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")

STORAGE_CODES = {"STORAGE_READ_ONLY", "STORAGE_FULL", "RECORDING_COMMIT_FAIL"}
NON_ROOT_CODES = {
    "NONE",
    "DISABLED",
    "PRODUCER_STALE",
    "PRODUCER_MALFORMED",
    "REMOTE_PATH_UNAVAILABLE",
    "BLOCKED_BY_PAIR",
    "CONFIG_DIVERGED",
    "BOOT_CONFIG_INVALID",
    "LEASE_STALE_OWNER_ALIVE",
    "STALE_LAUNCH_ABORTED",
}

# A confirmed failure in the key may explain these later data-path blocks.
# Probe ambiguity and DES control-plane failure are intentionally not listed.
EXPLAINS: Mapping[str, Set[str]] = {
    "sensor": {"isp", "csi2", "capture", "gstreamer"},
    "isp": {"csi2", "capture", "gstreamer"},
    "serializer": {"gmsl_link", "csi2", "capture", "gstreamer"},
    "gmsl_link": {"csi2", "capture", "gstreamer"},
    "csi2": {"capture", "gstreamer"},
    "capture": {"gstreamer"},
    "gstreamer": set(),
    "recording": set(),
}


class SnapshotError(ValueError):
    """A producer snapshot is malformed or incompatible."""


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def load_registry(path: Path) -> Dict[str, Dict[str, Any]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SnapshotError(f"error registry unavailable: {path}: {exc}") from exc
    if not isinstance(document, dict) or document.get("schema") != 1:
        raise SnapshotError("error registry schema must be 1")
    result: Dict[str, Dict[str, Any]] = {}
    codes = document.get("codes")
    if not isinstance(codes, list):
        raise SnapshotError("error registry codes must be an array")
    for item in codes:
        if not isinstance(item, dict):
            raise SnapshotError("error registry entry must be an object")
        code = item.get("code")
        block = item.get("block")
        if not isinstance(code, str) or not CODE_RE.fullmatch(code):
            raise SnapshotError(f"invalid error code: {code!r}")
        if code in result:
            raise SnapshotError(f"duplicate error code: {code}")
        if block not in BLOCK_SET | {"any"}:
            raise SnapshotError(f"invalid block for {code}: {block!r}")
        result[code] = dict(item)
    return result


def validate_observation(
    observation: object, registry: Mapping[str, Mapping[str, Any]], index: int
) -> Dict[str, Any]:
    if not isinstance(observation, dict):
        raise SnapshotError(f"observations[{index}] is not an object")
    block = observation.get("block")
    status = observation.get("status")
    code = observation.get("code")
    scope = observation.get("scope")
    count = observation.get("count")
    evidence = observation.get("evidence")
    if block not in BLOCK_SET:
        raise SnapshotError(f"observations[{index}] unknown block: {block!r}")
    if status not in STATUSES:
        raise SnapshotError(f"observations[{index}] invalid status: {status!r}")
    if not isinstance(code, str) or code not in registry:
        raise SnapshotError(f"observations[{index}] unregistered code: {code!r}")
    if (
        not isinstance(scope, dict)
        or scope.get("kind") not in SCOPE_KINDS
        or not isinstance(scope.get("id"), str)
        or not scope.get("id")
    ):
        raise SnapshotError(f"observations[{index}] invalid scope")
    channels = scope.get("channels")
    if channels is not None and (
        not isinstance(channels, list)
        or not channels
        or any(not _is_int(channel) or channel < 0 or channel > 3 for channel in channels)
        or len(set(channels)) != len(channels)
    ):
        raise SnapshotError(f"observations[{index}] invalid scope channels")
    if not _is_int(count) or count < 0:
        raise SnapshotError(f"observations[{index}] invalid count")
    if not isinstance(evidence, list):
        raise SnapshotError(f"observations[{index}] evidence must be an array")
    for evidence_index, item in enumerate(evidence):
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("name"), str)
            or not item.get("name")
            or not isinstance(item.get("source"), str)
            or not item.get("source")
            or "value" not in item
        ):
            raise SnapshotError(
                f"observations[{index}] invalid evidence[{evidence_index}]"
            )
    if status == "OK" and code != "NONE":
        raise SnapshotError(f"observations[{index}] OK requires NONE")
    if status == "N/A" and code != "DISABLED":
        raise SnapshotError(f"observations[{index}] N/A requires DISABLED")
    if status == "FAIL" and code in {"NONE", "DISABLED"}:
        raise SnapshotError(f"observations[{index}] FAIL requires a failure code")
    if status == "BLOCKED" and not observation.get("blocked_by"):
        raise SnapshotError(f"observations[{index}] BLOCKED requires blocked_by")
    blocked_by = observation.get("blocked_by")
    if blocked_by is not None and (
        not isinstance(blocked_by, list)
        or any(block not in BLOCK_SET for block in blocked_by)
        or len(set(blocked_by)) != len(blocked_by)
    ):
        raise SnapshotError(f"observations[{index}] invalid blocked_by")
    root_cause = observation.get("root_cause")
    if root_cause is not None and not isinstance(root_cause, bool):
        raise SnapshotError(f"observations[{index}] invalid root_cause")
    action_scope = observation.get("action_scope")
    if action_scope is not None and action_scope not in ACTION_SCOPES:
        raise SnapshotError(f"observations[{index}] invalid action_scope")
    registered_block = registry[code].get("block")
    if status == "FAIL" and registered_block not in {"any", block}:
        raise SnapshotError(
            f"observations[{index}] code {code} belongs to {registered_block}"
        )
    return dict(observation)


def load_snapshot(
    path: Path,
    expected_producer: str,
    boot_id: str,
    now_ms: int,
    ttl_ms: int,
    registry: Mapping[str, Mapping[str, Any]],
) -> Tuple[Optional[Dict[str, Any]], Dict[str, Any]]:
    producer_state: Dict[str, Any] = {
        "producer": expected_producer,
        "path": str(path),
        "state": "UNKNOWN",
        "code": "PRODUCER_STALE",
        "age_ms": None,
    }
    if not path.is_file():
        producer_state["reason"] = "missing"
        return None, producer_state
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise SnapshotError("top level is not an object")
        if document.get("schema") != 1:
            raise SnapshotError("unsupported schema")
        if document.get("producer") != expected_producer:
            raise SnapshotError("producer/file mismatch")
        if document.get("boot_id") != boot_id:
            producer_state.update(code="PRODUCER_STALE", reason="boot_id_mismatch")
            return None, producer_state
        sequence = document.get("sequence")
        observed = document.get("observed_monotonic_ms")
        pid = document.get("pid")
        status = document.get("status")
        observations = document.get("observations")
        if not _is_int(sequence) or sequence < 0:
            raise SnapshotError("invalid sequence")
        if not _is_int(observed) or observed < 0:
            raise SnapshotError("invalid observed_monotonic_ms")
        if not _is_int(pid) or pid < 0:
            raise SnapshotError("invalid pid")
        if status not in STATUSES:
            raise SnapshotError("invalid top-level status")
        if not isinstance(observations, list):
            raise SnapshotError("observations must be an array")
        stream_mode = document.get("stream_mode")
        if stream_mode is not None and stream_mode not in STREAM_MODES:
            raise SnapshotError("invalid stream_mode")
        masks = document.get("channel_masks")
        if masks is not None:
            mask_keys = {
                "configured_channel_mask",
                "physical_present_mask",
                "stream_domain_active_mask",
            }
            if (
                not isinstance(masks, dict)
                or set(masks) != mask_keys
                or any(not _is_int(masks[key]) or masks[key] < 0 or masks[key] > 15 for key in mask_keys)
            ):
                raise SnapshotError("invalid channel_masks")
        age_ms = now_ms - observed
        producer_state["age_ms"] = age_ms
        producer_state["sequence"] = sequence
        if age_ms < 0:
            producer_state.update(code="PRODUCER_MALFORMED", reason="future_monotonic_time")
            return None, producer_state
        if age_ms > ttl_ms:
            producer_state.update(code="PRODUCER_STALE", reason="ttl_expired")
            return None, producer_state
        validated = [
            validate_observation(item, registry, index)
            for index, item in enumerate(observations)
        ]
        if status == "OK" and any(item["status"] not in {"OK", "N/A"} for item in validated):
            raise SnapshotError("top-level OK conflicts with observations")
        if status == "FAIL" and not any(item["status"] == "FAIL" for item in validated):
            raise SnapshotError("top-level FAIL has no failing observation")
        document["observations"] = validated
        producer_state.update(state="OK", code="NONE", reason="fresh")
        return document, producer_state
    except (OSError, json.JSONDecodeError, SnapshotError) as exc:
        producer_state.update(code="PRODUCER_MALFORMED", reason=str(exc))
        return None, producer_state


def scope_overlaps(left: Mapping[str, Any], right: Mapping[str, Any]) -> bool:
    left_kind, right_kind = left.get("kind"), right.get("kind")
    left_id, right_id = left.get("id"), right.get("id")
    if left_kind in {"global", "camera-domain"} or right_kind in {"global", "camera-domain"}:
        return True
    left_channels, right_channels = left.get("channels"), right.get("channels")
    if isinstance(left_channels, list) and isinstance(right_channels, list):
        return bool(set(left_channels) & set(right_channels))
    return left_kind == right_kind and left_id == right_id


def can_explain(upstream: Mapping[str, Any], downstream: Mapping[str, Any]) -> bool:
    upstream_block = str(upstream.get("block"))
    downstream_block = str(downstream.get("block"))
    upstream_code = str(upstream.get("code"))
    downstream_code = str(downstream.get("code"))
    if upstream_code.startswith("AMBIGUOUS_") or upstream_code in NON_ROOT_CODES:
        return False
    if upstream_block == "deserializer":
        # Local control failure does not erase independently observed CSI data.
        if upstream_code != "DES_MIPI_CONFIG_FAIL":
            return False
        return downstream_block in {"csi2", "capture", "gstreamer"}
    if downstream_block == "recording":
        # Storage faults remain independent. No-growth may be explained by a
        # failed video path and should not become the primary camera root.
        return downstream_code == "RECORDING_NO_GROWTH" and upstream_block != "recording"
    return downstream_block in EXPLAINS.get(upstream_block, set())


def root_causes(observations: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    failures = [
        item
        for item in observations
        if item.get("status") == "FAIL" and item.get("code") not in NON_ROOT_CODES
    ]
    explicit = [item for item in failures if item.get("root_cause") is True]
    roots: List[Mapping[str, Any]] = list(explicit)
    for candidate in failures:
        if candidate in roots or candidate.get("root_cause") is False:
            continue
        explained = any(
            other is not candidate
            and scope_overlaps(other.get("scope", {}), candidate.get("scope", {}))
            and can_explain(other, candidate)
            for other in failures
        )
        if not explained:
            roots.append(candidate)

    result: List[Dict[str, Any]] = []
    seen: Set[Tuple[str, str, str, str]] = set()
    for item in roots:
        scope = item.get("scope", {})
        key = (
            str(item.get("block")),
            str(scope.get("kind")),
            str(scope.get("id")),
            str(item.get("code")),
        )
        if key in seen:
            continue
        seen.add(key)
        result.append(
            {
                "block": item.get("block"),
                "scope": dict(scope),
                "code": item.get("code"),
                "action_scope": item.get("action_scope", "none"),
            }
        )
    return result


def aggregate(
    input_dir: Path,
    boot_id: str,
    now_ms: int,
    ttl_ms: int,
    registry: Mapping[str, Mapping[str, Any]],
) -> Dict[str, Any]:
    producer_states: List[Dict[str, Any]] = []
    observations: List[Dict[str, Any]] = []
    source_sequences: Dict[str, int] = {}
    masks: Optional[Dict[str, Any]] = None
    stream_mode = "unknown"

    for producer in PRODUCERS:
        snapshot, state = load_snapshot(
            input_dir / PRODUCER_FILES[producer],
            producer,
            boot_id,
            now_ms,
            ttl_ms,
            registry,
        )
        producer_states.append(state)
        if snapshot is None:
            continue
        source_sequences[producer] = int(snapshot["sequence"])
        observations.extend(snapshot["observations"])
        if producer == "max9296" and isinstance(snapshot.get("channel_masks"), dict):
            masks = dict(snapshot["channel_masks"])
        if producer == "max9296" and isinstance(snapshot.get("stream_mode"), str):
            stream_mode = snapshot["stream_mode"]

    roots = root_causes(observations)
    producer_unknown = any(item["state"] != "OK" for item in producer_states)
    has_failure = any(item.get("status") == "FAIL" for item in observations)
    has_starting = any(item.get("status") == "STARTING" for item in observations)
    has_unknown = any(item.get("status") in {"UNKNOWN", "BLOCKED"} for item in observations)
    if has_failure:
        overall_status, status = "FAILED", "FAIL"
    elif has_starting:
        overall_status, status = "RECOVERING", "STARTING"
    elif producer_unknown or has_unknown:
        overall_status, status = "DEGRADED", "UNKNOWN"
    else:
        overall_status, status = "HEALTHY", "OK"

    output: Dict[str, Any] = {
        "schema": 1,
        "mode": "shadow",
        "boot_id": boot_id,
        "observed_monotonic_ms": now_ms,
        "status": status,
        "overall_status": overall_status,
        "stream_mode": stream_mode,
        "source_sequences": source_sequences,
        "producers": producer_states,
        "root_causes": roots,
        "observations": observations,
        "legacy_write": False,
        "recovery_requested": False,
    }
    if masks is not None:
        output["channel_masks"] = masks
    return output


def atomic_write_json(path: Path, document: Mapping[str, Any]) -> None:
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
    script_config = Path(__file__).resolve().parent.parent / "config"
    default_registry = script_config / "camera_health_error_codes_v1.json"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, default=Path("/run/pim-camera"))
    parser.add_argument(
        "--output", type=Path, default=Path("/run/pim-camera/aggregate-shadow.json")
    )
    parser.add_argument(
        "--boot-id-file", type=Path, default=Path("/proc/sys/kernel/random/boot_id")
    )
    parser.add_argument("--registry", type=Path, default=default_registry)
    parser.add_argument("--ttl-ms", type=int, default=3000)
    parser.add_argument("--interval-ms", type=int, default=1000)
    parser.add_argument("--now-monotonic-ms", type=int)
    parser.add_argument("--once", action="store_true")
    return parser.parse_args(argv)


def read_boot_id(path: Path) -> str:
    boot_id = path.read_text(encoding="utf-8").strip()
    if not boot_id:
        raise SnapshotError(f"empty boot ID: {path}")
    return boot_id


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.ttl_ms < 1 or args.interval_ms < 1:
        raise SystemExit("ttl and interval must be positive")
    registry = load_registry(args.registry)
    stopped = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not stopped:
        boot_id = read_boot_id(args.boot_id_file)
        now_ms = (
            args.now_monotonic_ms
            if args.now_monotonic_ms is not None
            else time.monotonic_ns() // 1_000_000
        )
        document = aggregate(args.input_dir, boot_id, now_ms, args.ttl_ms, registry)
        atomic_write_json(args.output, document)
        if args.once:
            break
        time.sleep(args.interval_ms / 1000.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
