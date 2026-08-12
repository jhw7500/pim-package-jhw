#!/usr/bin/env python3
"""Read-only i.MX8MP CSI2/ISI activity producer for camera health v1."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Set, Tuple


IRQ_LINE = re.compile(r"^\s*([^:]+):\s*(.*)$")
VALID_DOMAIN_ID = re.compile(r"^[A-Za-z0-9._-]+$")


class ProbeError(ValueError):
    """Capture probe configuration or input is invalid."""


def parse_interrupts(text: str) -> Dict[str, int]:
    """Return device-label -> sum(per-CPU IRQ counters)."""
    result: Dict[str, int] = {}
    for raw_line in text.splitlines():
        match = IRQ_LINE.match(raw_line)
        if not match:
            continue
        tokens = match.group(2).split()
        counts = []
        index = 0
        while index < len(tokens) and tokens[index].isdigit():
            counts.append(int(tokens[index]))
            index += 1
        if not counts or index >= len(tokens):
            continue
        # Kernel/controller columns may precede the stable device label. The
        # max9296 reference tool matches the last token exactly.
        label = tokens[-1]
        result[label] = sum(counts)
    return result


def load_mapping(path: Path) -> Dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProbeError(f"capture mapping unavailable: {path}: {exc}") from exc
    if not isinstance(document, dict) or document.get("schema") != 1:
        raise ProbeError("capture mapping schema must be 1")
    domains = document.get("domains")
    ratio = document.get("isi_reliable_csi_irq_per_isi_irq")
    if not isinstance(domains, list) or not domains:
        raise ProbeError("capture mapping domains must be a non-empty array")
    if not isinstance(ratio, dict):
        raise ProbeError("capture mapping ISI ratio is missing")
    minimum, maximum = ratio.get("minimum"), ratio.get("maximum")
    if not isinstance(minimum, (int, float)) or not isinstance(maximum, (int, float)):
        raise ProbeError("capture mapping ISI ratio must be numeric")
    if minimum <= 0 or maximum <= minimum:
        raise ProbeError("capture mapping ISI ratio range is invalid")

    seen: Set[str] = set()
    for index, domain in enumerate(domains):
        if not isinstance(domain, dict):
            raise ProbeError(f"domains[{index}] must be an object")
        domain_id = domain.get("id")
        channels = domain.get("channels")
        required_strings = ("scope_id", "csi_irq", "isi_irq", "video_node")
        if not isinstance(domain_id, str) or not VALID_DOMAIN_ID.fullmatch(domain_id):
            raise ProbeError(f"domains[{index}] invalid id")
        if domain_id in seen:
            raise ProbeError(f"duplicate capture domain: {domain_id}")
        seen.add(domain_id)
        if any(not isinstance(domain.get(key), str) or not domain.get(key) for key in required_strings):
            raise ProbeError(f"domains[{index}] missing string field")
        if (
            not isinstance(channels, list)
            or not channels
            or any(not isinstance(channel, int) or isinstance(channel, bool) or channel < 0 or channel > 3 for channel in channels)
            or len(set(channels)) != len(channels)
        ):
            raise ProbeError(f"domains[{index}] invalid channels")
        divisor = domain.get("csi_irqs_per_frame")
        if not isinstance(divisor, int) or isinstance(divisor, bool) or divisor < 1:
            raise ProbeError(f"domains[{index}] invalid csi_irqs_per_frame")
    return document


def evidence(name: str, source: str, value: object, unit: Optional[str] = None) -> Dict[str, Any]:
    item: Dict[str, Any] = {"name": name, "source": source, "value": value}
    if unit:
        item["unit"] = unit
    return item


def observation(
    block: str,
    domain: Mapping[str, Any],
    status: str,
    code: str,
    items: Sequence[Mapping[str, Any]],
    root_cause: Optional[bool] = None,
) -> Dict[str, Any]:
    item: Dict[str, Any] = {
        "block": block,
        "scope": {
            "kind": "csi",
            "id": domain["scope_id"],
            "channels": list(domain["channels"]),
        },
        "status": status,
        "code": code,
        "count": 1 if status == "FAIL" else 0,
        "evidence": [dict(value) for value in items],
    }
    if root_cause is not None:
        item["root_cause"] = root_cause
    return item


def classify_domain(
    domain: Mapping[str, Any],
    before: Mapping[str, int],
    after: Mapping[str, int],
    elapsed_ms: int,
    expected: bool,
    video_node_exists: bool,
    ratio_minimum: float,
    ratio_maximum: float,
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    csi_name = str(domain["csi_irq"])
    isi_name = str(domain["isi_irq"])
    source = "/proc/interrupts"
    base = [
        evidence("expected_stream", "capture-map/runtime-expectation", expected),
        evidence("video_node_exists", str(domain["video_node"]), video_node_exists),
    ]
    if csi_name not in before or csi_name not in after:
        missing = f"csi:{csi_name}"
        common = base + [evidence("missing_irq_source", source, missing)]
        return (
            observation("csi2", domain, "UNKNOWN", "IRQ_SOURCE_MISSING", common),
            observation("capture", domain, "UNKNOWN", "IRQ_SOURCE_MISSING", common),
        )
    if isi_name not in before or isi_name not in after:
        missing = f"isi:{isi_name}"
        csi_delta = after[csi_name] - before[csi_name]
        common = base + [
            evidence("csi_irq_delta", source, csi_delta, "interrupts"),
            evidence("missing_irq_source", source, missing),
        ]
        csi_status = "OK" if csi_delta > 0 else "UNKNOWN"
        csi_code = "NONE" if csi_delta > 0 else ("CSI2_NO_PROGRESS" if expected else "NO_STREAM_EXPECTATION")
        return (
            observation("csi2", domain, csi_status, csi_code, common),
            observation("capture", domain, "UNKNOWN", "IRQ_SOURCE_MISSING", common),
        )

    csi_delta = after[csi_name] - before[csi_name]
    isi_delta = after[isi_name] - before[isi_name]
    if csi_delta < 0 or isi_delta < 0:
        common = base + [
            evidence("csi_irq_delta", source, csi_delta, "interrupts"),
            evidence("isi_irq_delta", source, isi_delta, "interrupts"),
        ]
        return (
            observation("csi2", domain, "UNKNOWN", "IRQ_COUNTER_RESET", common),
            observation("capture", domain, "UNKNOWN", "IRQ_COUNTER_RESET", common),
        )

    elapsed_seconds = elapsed_ms / 1000.0
    divisor = int(domain["csi_irqs_per_frame"])
    csi_fps = csi_delta / divisor / elapsed_seconds
    isi_activity_hz = isi_delta / elapsed_seconds
    ratio = csi_delta / isi_delta if isi_delta > 0 else None
    ratio_reliable = ratio is not None and ratio_minimum <= ratio <= ratio_maximum
    common = base + [
        evidence("sample_elapsed_ms", "monotonic", elapsed_ms, "ms"),
        evidence("csi_irq_delta", source, csi_delta, "interrupts"),
        evidence("isi_irq_delta", source, isi_delta, "interrupts"),
        evidence("csi_frame_rate", csi_name, round(csi_fps, 3), "frames/s"),
        evidence("isi_activity_rate", isi_name, round(isi_activity_hz, 3), "interrupts/s"),
        evidence("csi_irq_per_isi_irq", source, None if ratio is None else round(ratio, 3)),
        evidence("isi_frame_semantics_reliable", "cam_fps_stack-ratio", ratio_reliable),
    ]

    if not expected:
        csi_status = "OK" if csi_delta > 0 else "UNKNOWN"
        capture_status = "OK" if isi_delta > 0 and video_node_exists else "UNKNOWN"
        return (
            observation("csi2", domain, csi_status, "NONE" if csi_status == "OK" else "NO_STREAM_EXPECTATION", common),
            observation("capture", domain, capture_status, "NONE" if capture_status == "OK" else "NO_STREAM_EXPECTATION", common),
        )

    if not video_node_exists:
        csi_status = "OK" if csi_delta > 0 else "UNKNOWN"
        return (
            observation("csi2", domain, csi_status, "NONE" if csi_status == "OK" else "CSI2_NO_PROGRESS", common),
            observation("capture", domain, "FAIL", "CAPTURE_NODE_MISSING", common, True),
        )
    if csi_delta == 0:
        return (
            observation("csi2", domain, "UNKNOWN", "CSI2_NO_PROGRESS", common, False),
            observation("capture", domain, "UNKNOWN", "CAPTURE_PATH_STALL", common, False),
        )
    if isi_delta == 0:
        return (
            observation("csi2", domain, "OK", "NONE", common),
            observation("capture", domain, "UNKNOWN", "CAPTURE_PATH_STALL", common, False),
        )
    capture_code = "NONE" if ratio_reliable else "ISI_ACTIVITY_UNRELIABLE"
    capture_status = "OK" if ratio_reliable else "UNKNOWN"
    return (
        observation("csi2", domain, "OK", "NONE", common),
        observation("capture", domain, capture_status, capture_code, common),
    )


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


def read_interrupts(path: Path) -> Tuple[str, Dict[str, int]]:
    text = path.read_text(encoding="utf-8")
    return text, parse_interrupts(text)


def build_snapshot(
    mapping: Mapping[str, Any],
    before: Mapping[str, int],
    after: Mapping[str, int],
    elapsed_ms: int,
    enabled_domains: Set[str],
    node_root: Path,
    boot_id: str,
    sequence: int,
    now_ms: int,
) -> Dict[str, Any]:
    ratio = mapping["isi_reliable_csi_irq_per_isi_irq"]
    observations = []
    for domain in mapping["domains"]:
        video_path = node_root / str(domain["video_node"]).lstrip("/")
        csi, capture = classify_domain(
            domain,
            before,
            after,
            elapsed_ms,
            str(domain["id"]) in enabled_domains,
            video_path.exists(),
            float(ratio["minimum"]),
            float(ratio["maximum"]),
        )
        observations.extend((csi, capture))
    if any(item["status"] == "FAIL" for item in observations):
        status = "FAIL"
    elif any(item["status"] in {"UNKNOWN", "BLOCKED"} for item in observations):
        status = "UNKNOWN"
    else:
        status = "OK"
    return {
        "schema": 1,
        "producer": "pim-healthd",
        "boot_id": boot_id,
        "pid": os.getpid(),
        "sequence": sequence,
        "observed_monotonic_ms": now_ms,
        "status": status,
        "observations": observations,
        "producer_data": {
            "probe": "imx8mp-csi-isi-irq-v1",
            "enabled_domains": sorted(enabled_domains),
            "sample_elapsed_ms": elapsed_ms,
        },
    }


def parse_domains(value: str, available: Set[str]) -> Set[str]:
    requested = {item for item in value.split(",") if item}
    unknown = requested - available
    if unknown:
        raise ProbeError(f"unknown enabled domain(s): {','.join(sorted(unknown))}")
    return requested


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    config_dir = Path(__file__).resolve().parent.parent / "config"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mapping", type=Path, default=config_dir / "camera_capture_map_v1.json")
    parser.add_argument("--interrupts", type=Path, default=Path("/proc/interrupts"))
    parser.add_argument("--interrupts-after", type=Path)
    parser.add_argument("--node-root", type=Path, default=Path("/"))
    parser.add_argument("--boot-id-file", type=Path, default=Path("/proc/sys/kernel/random/boot_id"))
    parser.add_argument("--output", type=Path, default=Path("/run/pim-camera/pim-probe.json"))
    parser.add_argument("--enabled-domains", default="")
    parser.add_argument("--interval-ms", type=int, default=1000)
    parser.add_argument("--once", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.interval_ms < 1:
        raise SystemExit("interval must be positive")
    mapping = load_mapping(args.mapping)
    available = {str(domain["id"]) for domain in mapping["domains"]}
    enabled = parse_domains(args.enabled_domains, available)
    boot_id = args.boot_id_file.read_text(encoding="utf-8").strip()
    if not boot_id:
        raise SystemExit("boot ID is empty")
    stopped = False
    sequence = 0

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not stopped:
        _before_text, before = read_interrupts(args.interrupts)
        start_ns = time.monotonic_ns()
        if args.interrupts_after is None:
            time.sleep(args.interval_ms / 1000.0)
            _after_text, after = read_interrupts(args.interrupts)
            elapsed_ms = max(1, (time.monotonic_ns() - start_ns) // 1_000_000)
        else:
            _after_text, after = read_interrupts(args.interrupts_after)
            elapsed_ms = args.interval_ms
        sequence += 1
        now_ms = time.monotonic_ns() // 1_000_000
        document = build_snapshot(
            mapping, before, after, elapsed_ms, enabled, args.node_root, boot_id, sequence, now_ms
        )
        atomic_write(args.output, document)
        if args.once or args.interrupts_after is not None:
            break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
