#!/usr/bin/env python3
"""Resolve /tmp/config into read-only camera stream-domain expectations."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple


DOMAIN_CHANNELS: Tuple[Tuple[str, Tuple[int, int]], ...] = (
    ("ch01", (0, 1)),
    ("ch23", (2, 3)),
)
CHANNEL_PATHS = {
    0: ("i2c2", "ch0"),
    1: ("i2c2", "ch1"),
    2: ("i2c1", "ch2"),
    3: ("i2c1", "ch3"),
}


class ConfigError(ValueError):
    """The boot snapshot or camera configuration is invalid."""


def load_object(path: Path, label: str) -> Dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"{label} unavailable: {path}: {exc}") from exc
    if not isinstance(document, dict):
        raise ConfigError(f"{label} must be an object")
    return document


def load_hashed_object(path: Path, label: str) -> Tuple[Dict[str, Any], str]:
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ConfigError(f"{label} unavailable: {path}: {exc}") from exc
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConfigError(f"{label} unavailable: {path}: {exc}") from exc
    if not isinstance(document, dict):
        raise ConfigError(f"{label} must be an object")
    return document, hashlib.sha256(payload).hexdigest()


def positive_int(value: object, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ConfigError(f"{name} must be a positive integer")
    return value


def channel_enabled(vhl: Mapping[str, Any], channel: int) -> bool:
    bus_name, channel_name = CHANNEL_PATHS[channel]
    bus = vhl.get(bus_name, {})
    if not isinstance(bus, dict):
        raise ConfigError(f"VHL_CAM.{bus_name} must be an object")
    config = bus.get(channel_name, {})
    if not isinstance(config, dict):
        raise ConfigError(f"VHL_CAM.{bus_name}.{channel_name} must be an object")
    enabled = config.get("enable", False)
    if not isinstance(enabled, bool):
        raise ConfigError(f"VHL_CAM.{bus_name}.{channel_name}.enable must be boolean")
    return enabled


def resolve_expectation(
    edgeconf: Mapping[str, Any],
    boot_id: str,
    current_hash: str,
    import_hash: str,
    source_path: Path,
    observed_monotonic_ms: int,
) -> Dict[str, Any]:
    vhl = edgeconf.get("VHL_CAM")
    if not isinstance(vhl, dict):
        raise ConfigError("edgeconf requires object VHL_CAM")
    width = positive_int(vhl.get("cam_width"), "VHL_CAM.cam_width")
    height = positive_int(vhl.get("cam_height"), "VHL_CAM.cam_height")
    fps = positive_int(vhl.get("fps"), "VHL_CAM.fps")
    enabled = {channel: channel_enabled(vhl, channel) for channel in range(4)}
    configured_mask = sum(1 << channel for channel, value in enabled.items() if value)

    domains = []
    modes = []
    for domain_id, possible_channels in DOMAIN_CHANNELS:
        active_channels = [channel for channel in possible_channels if enabled[channel]]
        if len(active_channels) == 2:
            mode = "dual-wide"
            input_width = width * 2
        elif len(active_channels) == 1:
            mode = "single"
            input_width = width
        else:
            mode = "disabled"
            input_width = 0
        if active_channels:
            modes.append(mode)
        domains.append(
            {
                "id": domain_id,
                "enabled": bool(active_channels),
                "mode": mode,
                "possible_channels": list(possible_channels),
                "active_channels": active_channels,
                "configured_channel_mask": sum(1 << channel for channel in active_channels),
                "expected_format": {
                    "width": input_width,
                    "height": height if active_channels else 0,
                    "fps": fps if active_channels else 0,
                },
            }
        )

    if not modes:
        stream_mode = "unknown"
    elif all(mode == "dual-wide" for mode in modes):
        stream_mode = "dual-wide"
    elif all(mode == "single" for mode in modes):
        stream_mode = "single"
    else:
        stream_mode = "independent"

    return {
        "schema": 1,
        "boot_id": boot_id,
        "observed_monotonic_ms": observed_monotonic_ms,
        "source": str(source_path),
        "config_sha256": current_hash,
        "boot_import_sha256": import_hash,
        "runtime_override": current_hash != import_hash,
        "configured_channel_mask": configured_mask,
        "stream_mode": stream_mode,
        "sensor_format": {"width": width, "height": height, "fps": fps},
        "domains": domains,
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


def resolve_from_files(
    config_dir: Path, boot_id_file: Path, observed_monotonic_ms: int
) -> Dict[str, Any]:
    boot_id = boot_id_file.read_text(encoding="utf-8").strip()
    if not boot_id:
        raise ConfigError("boot ID is empty")
    ready_path = config_dir / "READY"
    edge_path = config_dir / "edgeconf_pim.json"
    ready = load_object(ready_path, "READY")
    if ready.get("schema") != 1 or ready.get("boot_id") != boot_id:
        raise ConfigError("READY is missing or belongs to another boot")
    files = ready.get("files")
    if not isinstance(files, dict):
        raise ConfigError("READY.files must be an object")
    edge_record = files.get("edgeconf_pim")
    if not isinstance(edge_record, dict):
        raise ConfigError("READY edgeconf record is missing")
    import_hash = edge_record.get("sha256")
    if (
        not isinstance(import_hash, str)
        or len(import_hash) != 64
        or any(char not in "0123456789abcdef" for char in import_hash)
    ):
        raise ConfigError("READY edgeconf hash is invalid")
    # Parse and hash one byte snapshot. An engineer may atomically replace the
    # runtime JSON while this resolver is running; never label one generation
    # with another generation's digest.
    edgeconf, current_hash = load_hashed_object(edge_path, "edgeconf")
    return resolve_expectation(
        edgeconf,
        boot_id,
        current_hash,
        import_hash,
        edge_path,
        observed_monotonic_ms,
    )


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-dir", type=Path, default=Path("/tmp/config"))
    parser.add_argument("--boot-id-file", type=Path, default=Path("/proc/sys/kernel/random/boot_id"))
    parser.add_argument("--output", type=Path, default=Path("/run/pim-camera/config-expectation.json"))
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    document = resolve_from_files(
        args.config_dir,
        args.boot_id_file,
        time.monotonic_ns() // 1_000_000,
    )
    atomic_write(args.output, document)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
