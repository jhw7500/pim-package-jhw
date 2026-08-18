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
    scope: Dict[str, Any] = {
        "kind": "csi",
        "id": domain["scope_id"],
    }
    scope_channels = domain.get("_scope_channels")
    if isinstance(scope_channels, list) and scope_channels:
        scope["channels"] = list(scope_channels)
    item: Dict[str, Any] = {
        "block": block,
        "scope": scope,
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
    # 여기까지 왔으면 CSI 도 ISI 도 진행 중이다. capture 경로는 프레임을 나르고
    # 있고, 비율은 그 활동을 프레임률로 환산해도 되는지만 정한다. 그건 매핑
    # 확신도지 카메라 건강이 아니다.
    #
    # 이전 구현은 비율이 게이트 밖이면 UNKNOWN/ISI_ACTIVITY_UNRELIABLE 을 냈다.
    # aggregator 는 관측 하나라도 UNKNOWN 이면 전체를 DEGRADED 로 내리므로, 그
    # 판정은 자기 확신도를 시스템 건강으로 번역하는 셈이었다. 보드 실측에서
    # 대가가 드러났다(2026-08-18, pim-camera-v016):
    #
    #   - 1Hz 유저스페이스 프로세스가 하나만 붙어도 ISI 인터럽트가 프레임당
    #     1.03 -> 1.10~1.20 회로 늘어 비율 중심이 1.94 -> 1.63 으로 이동한다.
    #     게이트 하한이 1.6 이라 정상 운용의 40% 가 DEGRADED 로 찍혔다. 어느
    #     producer 인지는 무관하고 셋 중 하나만 돌려도 효과가 같았다.
    #   - 같은 구간에서 CSI 는 14.98~14.99 fps 로 불변이고, 인코더 큐에 도달한
    #     프레임도 채널당 14.94/s 로 동일했다(P1 대비 +0.03%). 프레임 손실은 없다.
    #
    # 즉 비율 이탈은 부하 신호지 열화가 아니다. 창을 늘려도 분산이 아니라 중심이
    # 이동한 것이라 해결되지 않는다(10초 창에서도 72~90%).
    #
    # 확신도는 evidence(isi_frame_semantics_reliable)로 그대로 나가므로 정보는
    # 잃지 않는다. 진짜 정지는 위쪽 분기가 이미 잡는다 - video node 없음은
    # CAPTURE_NODE_MISSING, csi_delta == 0 은 CSI2_NO_PROGRESS, isi_delta == 0 은
    # CAPTURE_PATH_STALL 이다.
    #
    # ISI_ACTIVITY_UNRELIABLE 은 레지스트리에 남겨 둔다. 세 저장소를 동시에 교체할
    # 수 없으므로, 아직 그 코드를 내는 probe 버전의 snapshot 이 레지스트리 미등록
    # 으로 통째로 거부되면 안 된다.
    return (
        observation("csi2", domain, "OK", "NONE", common),
        observation("capture", domain, "OK", "NONE", common),
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
    expectation_domains: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> Dict[str, Any]:
    ratio = mapping["isi_reliable_csi_irq_per_isi_irq"]
    expectations = expectation_domains or {}
    observations = []
    for domain in mapping["domains"]:
        domain_id = str(domain["id"])
        context = dict(domain)
        expectation = expectations.get(domain_id)
        if expectation is not None:
            context["_scope_channels"] = list(expectation["active_channels"])
        elif domain_id in enabled_domains:
            context["_scope_channels"] = list(domain["channels"])
        video_path = node_root / str(context["video_node"]).lstrip("/")
        csi, capture = classify_domain(
            context,
            before,
            after,
            elapsed_ms,
            domain_id in enabled_domains,
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


def load_expectation(
    path: Path,
    boot_id: str,
    available_domains: Mapping[str, Set[int]],
) -> Tuple[Set[str], Dict[str, Any], str, str]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProbeError(f"expectation unavailable: {path}: {exc}") from exc
    if not isinstance(document, dict) or document.get("schema") != 1:
        raise ProbeError("expectation schema must be 1")
    if document.get("boot_id") != boot_id:
        raise ProbeError("expectation belongs to another boot")
    domains = document.get("domains")
    if not isinstance(domains, list):
        raise ProbeError("expectation domains must be an array")
    indexed: Dict[str, Any] = {}
    enabled: Set[str] = set()
    for item in domains:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise ProbeError("invalid expectation domain")
        domain_id = item["id"]
        if domain_id in indexed:
            raise ProbeError(f"duplicate expectation domain: {domain_id}")
        active_channels = item.get("active_channels")
        if (
            not isinstance(active_channels, list)
            or any(not isinstance(channel, int) or isinstance(channel, bool) or channel < 0 or channel > 3 for channel in active_channels)
            or len(set(active_channels)) != len(active_channels)
        ):
            raise ProbeError(f"invalid active channels for {domain_id}")
        if domain_id not in available_domains:
            raise ProbeError(f"unknown expectation domain: {domain_id}")
        if not set(active_channels) <= available_domains[domain_id]:
            raise ProbeError(f"active channels do not belong to {domain_id}")
        possible_channels = item.get("possible_channels")
        if (
            not isinstance(possible_channels, list)
            or possible_channels != sorted(available_domains[domain_id])
        ):
            raise ProbeError(f"possible channels do not match mapping for {domain_id}")
        enabled_flag = item.get("enabled")
        if not isinstance(enabled_flag, bool) or enabled_flag != bool(active_channels):
            raise ProbeError(f"invalid enabled flag for {domain_id}")
        expected_mode = {0: "disabled", 1: "single", 2: "dual-wide"}.get(len(active_channels))
        if item.get("mode") != expected_mode:
            raise ProbeError(f"invalid mode for {domain_id}")
        expected_mask = sum(1 << channel for channel in active_channels)
        if item.get("configured_channel_mask") != expected_mask:
            raise ProbeError(f"invalid configured channel mask for {domain_id}")
        indexed[domain_id] = dict(item)
        if enabled_flag:
            enabled.add(domain_id)
    if set(indexed) != set(available_domains):
        missing = set(available_domains) - set(indexed)
        raise ProbeError(f"expectation missing domain(s): {','.join(sorted(missing))}")
    configured_mask = sum(
        1 << channel
        for item in indexed.values()
        for channel in item["active_channels"]
    )
    if document.get("configured_channel_mask") != configured_mask:
        raise ProbeError("expectation configured channel mask is inconsistent")
    config_hash = document.get("config_sha256")
    if not isinstance(config_hash, str) or re.fullmatch(r"[0-9a-f]{64}", config_hash) is None:
        raise ProbeError("expectation config hash is invalid")
    enabled_modes = [indexed[domain_id]["mode"] for domain_id in sorted(enabled)]
    if not enabled_modes:
        expected_stream_mode = "unknown"
    elif all(mode == "dual-wide" for mode in enabled_modes):
        expected_stream_mode = "dual-wide"
    elif all(mode == "single" for mode in enabled_modes):
        expected_stream_mode = "single"
    else:
        expected_stream_mode = "independent"
    stream_mode = document.get("stream_mode")
    if stream_mode != expected_stream_mode:
        raise ProbeError("expectation stream mode is inconsistent")
    return enabled, indexed, config_hash, stream_mode


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
    parser.add_argument("--expectation", type=Path)
    parser.add_argument("--enabled-domains", default="")
    parser.add_argument("--interval-ms", type=int, default=1000)
    parser.add_argument("--once", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.interval_ms < 1:
        raise SystemExit("interval must be positive")
    mapping = load_mapping(args.mapping)
    available_domains = {
        str(domain["id"]): set(domain["channels"])
        for domain in mapping["domains"]
    }
    available = set(available_domains)
    boot_id = args.boot_id_file.read_text(encoding="utf-8").strip()
    if not boot_id:
        raise SystemExit("boot ID is empty")
    explicit_enabled = parse_domains(args.enabled_domains, available)
    expectation_domains: Dict[str, Any] = {}
    config_hash: Optional[str] = None
    stream_mode: Optional[str] = None
    if args.expectation is not None:
        expected_enabled, expectation_domains, config_hash, stream_mode = load_expectation(
            args.expectation, boot_id, available_domains
        )
        if explicit_enabled and explicit_enabled != expected_enabled:
            raise ProbeError("explicit enabled domains conflict with expectation")
        enabled = expected_enabled
    else:
        enabled = explicit_enabled
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
            mapping,
            before,
            after,
            elapsed_ms,
            enabled,
            args.node_root,
            boot_id,
            sequence,
            now_ms,
            expectation_domains,
        )
        if config_hash is not None:
            document["producer_data"]["config_sha256"] = config_hash
        if stream_mode is not None:
            document["stream_mode"] = stream_mode
        atomic_write(args.output, document)
        if args.once or args.interrupts_after is not None:
            break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
