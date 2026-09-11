#!/usr/bin/env python3
"""Build and safely publish the single mutable camera runtime document."""

from __future__ import annotations

import argparse
import json
import math
import os
import stat
import sys
import tempfile
from dataclasses import asdict, dataclass
from functools import lru_cache
from pathlib import Path
from typing import Mapping, Sequence


RUNTIME_NAME = "pim_runtime.json"
ALIAS_NAMES = ("edgeconf_pim.json", "ord_vcm_conf.json")
_REQUIRED_SECTIONS = ("VHL_CAM", "ORD", "VCM")
_SECTION_ORDER = ("VHL_CAM", "ORD", "VCM", "ETC", "SCRIPT")
_CONFIG_DIR = Path(__file__).resolve().parent.parent / "config"
_EDGE_SCHEMA_PATH = _CONFIG_DIR / "edgeconf_pim_base.json"
_ORD_SCHEMA_PATH = _CONFIG_DIR / "ord_vcm_conf.json"
_INT32_MAX = (1 << 31) - 1
_FIELD_RANGES = {
    ("VHL_CAM", "cam_width"): (1, 16384),
    ("VHL_CAM", "cam_height"): (1, 16384),
    ("VHL_CAM", "fps"): (1, 1000),
    ("VHL_CAM", "recording_time"): (1, 255),
    ("VHL_CAM", "event_storage_size"): (0, 100),
    ("VHL_CAM", "capture", "quality"): (0, 100),
    ("ORD", "port_num"): (1, 65535),
    ("ORD", "vhl_max"): (1, 4),
    ("ORD", "disk_limit_per"): (0, 100),
    ("VCM", "port_num"): (1, 65535),
}
_PATH_FIELDS = {
    ("VHL_CAM", "tmp_path"),
    ("VHL_CAM", "sd_tmp_path"),
    ("VHL_CAM", "final_path"),
    ("VHL_CAM", "capture", "path"),
}
_STRING_BYTE_LIMITS = {
    ("VHL_CAM", "vhl_name"): 63,
    ("VHL_CAM", "line"): 63,
    ("VHL_CAM", "floor"): 63,
    ("VHL_CAM", "tmp_path"): 255,
    ("VHL_CAM", "muxer"): 31,
    ("ORD", "ip_static"): 63,
    ("VCM", "ip_static"): 63,
}


class ConfigError(ValueError):
    """Raised when an input cannot safely become a runtime configuration."""


@dataclass(frozen=True)
class SourceRecord:
    path: Path
    mtime_ns: int


@dataclass(frozen=True)
class Candidate:
    document: dict[str, object]
    source: SourceRecord
    ord_path: Path


@dataclass(frozen=True)
class ChangePlan:
    semantic_change: bool
    hardware_change: bool
    changed_sections: Sequence[str]
    steps: Sequence[str]


def _is_regular_file(path: Path) -> bool:
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except FileNotFoundError:
        return False


def _reject_json_constant(constant: str) -> object:
    raise ConfigError(f"non-finite JSON number is not allowed: {constant}")


def _load_object(path: Path) -> dict[str, object]:
    try:
        document = json.loads(
            path.read_text(encoding="utf-8"), parse_constant=_reject_json_constant
        )
    except (OSError, json.JSONDecodeError) as error:
        raise ConfigError(f"invalid JSON: {path}") from error
    if not isinstance(document, dict):
        raise ConfigError(f"JSON document must be an object: {path}")
    return document


def _validate_json_value(value: object, label: str) -> None:
    if value is None or type(value) in (bool, int, str):
        return
    if type(value) is float:
        if not math.isfinite(value):
            raise ConfigError(f"{label} must be a finite JSON number")
        return
    if type(value) is list:
        for index, item in enumerate(value):
            _validate_json_value(item, f"{label}[{index}]")
        return
    if type(value) is dict:
        for key, item in value.items():
            if type(key) is not str:
                raise ConfigError(f"{label} contains a non-string key")
            _validate_json_value(item, f"{label}.{key}")
        return
    raise ConfigError(f"{label} contains a non-JSON value")


@lru_cache(maxsize=1)
def _consumed_schema() -> dict[str, object]:
    edge_document = _load_object(_EDGE_SCHEMA_PATH)
    ord_document = _load_object(_ORD_SCHEMA_PATH)
    sections = {
        "VHL_CAM": edge_document.get("VHL_CAM"),
        "ORD": ord_document.get("ORD"),
        "VCM": ord_document.get("VCM"),
    }
    for name, section in sections.items():
        if type(section) is not dict:
            raise ConfigError(f"packaged schema {name} must be an object")
    return sections


def _validate_integer(value: int, path: tuple[object, ...], label: str) -> None:
    minimum, maximum = _FIELD_RANGES.get(path, (0, _INT32_MAX))
    if len(path) >= 2 and path[-2] == "quant":
        minimum = -1
    if value < minimum or value > maximum:
        raise ConfigError(f"{label} must be between {minimum} and {maximum}")


def _validate_string(value: str, path: tuple[object, ...], label: str) -> None:
    if "\x00" in value:
        raise ConfigError(f"{label} must not contain NUL")
    byte_limit = _STRING_BYTE_LIMITS.get(path, 4095)
    if len(value.encode("utf-8")) > byte_limit:
        raise ConfigError(f"{label} exceeds {byte_limit} UTF-8 bytes")
    if path in _PATH_FIELDS and not value.startswith("/"):
        raise ConfigError(f"{label} must be an absolute path")


def _validate_consumed_value(
    value: object, template: object, path: tuple[object, ...], label: str
) -> None:
    if type(template) is dict:
        if type(value) is not dict:
            raise ConfigError(f"{label} must be an object")
        for key, child_template in template.items():
            if key not in value:
                raise ConfigError(f"{label}.{key} is required")
            _validate_consumed_value(
                value[key], child_template, path + (key,), f"{label}.{key}"
            )
        return
    if type(template) is list:
        if type(value) is not list:
            raise ConfigError(f"{label} must be an array")
        if len(value) != len(template):
            raise ConfigError(f"{label} must contain exactly {len(template)} items")
        for index, (item, child_template) in enumerate(zip(value, template)):
            _validate_consumed_value(
                item, child_template, path + (index,), f"{label}[{index}]"
            )
        return
    if type(value) is not type(template):
        raise ConfigError(f"{label} must be {type(template).__name__}")
    if type(value) is int:
        _validate_integer(value, path, label)
    elif type(value) is str:
        _validate_string(value, path, label)


def select_latest_edgeconf(source_root: Path) -> SourceRecord:
    try:
        entries = list(source_root.iterdir())
    except OSError as error:
        raise ConfigError(f"cannot read source root: {source_root}") from error
    candidates = [path for path in entries if path.match("edgeconf_*.json") and _is_regular_file(path)]
    if not candidates:
        raise ConfigError(f"no regular edgeconf_*.json source in {source_root}")
    selected = min(candidates, key=lambda path: (-path.stat().st_mtime_ns, os.fsencode(path)))
    return SourceRecord(path=selected, mtime_ns=selected.stat().st_mtime_ns)


def validate_runtime(document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise ConfigError("runtime document must be an object")
    _validate_json_value(document, "runtime")
    for name in _REQUIRED_SECTIONS:
        if not isinstance(document.get(name), dict):
            raise ConfigError(f"runtime {name} must be an object")
    for name, template in _consumed_schema().items():
        _validate_consumed_value(document[name], template, (name,), f"runtime.{name}")
    return document


def merge_source_documents(source_root: Path) -> Candidate:
    source = select_latest_edgeconf(source_root)
    ord_path = source_root / "ord_vcm_conf.json"
    if not _is_regular_file(ord_path):
        raise ConfigError(f"ord_vcm_conf.json must be a regular file: {ord_path}")
    ord_document = _load_object(ord_path)
    edge_document = _load_object(source.path)
    vhl = edge_document.get("VHL_CAM")
    if not isinstance(vhl, dict):
        raise ConfigError(f"edgeconf VHL_CAM must be an object: {source.path}")
    merged = dict(ord_document)
    merged["VHL_CAM"] = vhl
    return Candidate(document=validate_runtime(merged), source=source, ord_path=ord_path)


def _nested(mapping: object, *keys: str) -> object:
    value = mapping
    for key in keys:
        if not isinstance(value, Mapping):
            return None
        value = value.get(key)
    return value


def hardware_projection(document: Mapping[str, object]) -> dict[str, object]:
    vhl = document.get("VHL_CAM")
    if not isinstance(vhl, Mapping):
        raise ConfigError("runtime VHL_CAM must be an object")
    return {
        "cam_width": vhl.get("cam_width"),
        "cam_height": vhl.get("cam_height"),
        "fps": vhl.get("fps"),
        "i2c2": {
            "ch0": {"enable": _nested(vhl, "i2c2", "ch0", "enable")},
            "ch1": {"enable": _nested(vhl, "i2c2", "ch1", "enable")},
            "crop_enable": _nested(vhl, "i2c2", "crop_enable"),
            "dz": _nested(vhl, "i2c2", "dz"),
        },
        "i2c1": {
            "ch2": {"enable": _nested(vhl, "i2c1", "ch2", "enable")},
            "ch3": {"enable": _nested(vhl, "i2c1", "ch3", "enable")},
            "crop_enable": _nested(vhl, "i2c1", "crop_enable"),
            "dz": _nested(vhl, "i2c1", "dz"),
        },
        "v4l_map": vhl.get("v4l_map"),
        "device_map": vhl.get("device_map"),
        "camera_mode": vhl.get("camera_mode"),
        "stream_mode": vhl.get("stream_mode"),
        "topology": vhl.get("topology"),
    }


def _json_equal(current: object, candidate: object) -> bool:
    if type(current) is not type(candidate):
        return False
    if isinstance(current, dict):
        return current.keys() == candidate.keys() and all(
            _json_equal(value, candidate[key]) for key, value in current.items()
        )
    if isinstance(current, list):
        return len(current) == len(candidate) and all(
            _json_equal(value, candidate[index]) for index, value in enumerate(current)
        )
    return current == candidate


def classify_change(current: Mapping[str, object], candidate: Mapping[str, object]) -> ChangePlan:
    current_document = validate_runtime(dict(current))
    candidate_document = validate_runtime(dict(candidate))
    if _json_equal(current_document, candidate_document):
        return ChangePlan(False, False, (), ())
    changed: list[str] = []
    for section in _SECTION_ORDER[:-1]:
        if not _json_equal(current_document.get(section), candidate_document.get(section)):
            changed.append(section)
    known = set(_SECTION_ORDER[:-1])
    if any(
        not _json_equal(current_document.get(key), candidate_document.get(key))
        for key in (set(current_document) | set(candidate_document)) - known
    ):
        changed.append("SCRIPT")
    hardware_changed = not _json_equal(
        hardware_projection(current_document), hardware_projection(candidate_document)
    )
    steps: list[str] = []
    if hardware_changed:
        steps.append("camera_hard_reset")
    else:
        if "VHL_CAM" in changed:
            steps.extend(("gstapp_restart", "ord_restart", "vcm_restart"))
        if "ORD" in changed:
            steps.append("ord_restart")
        if "VCM" in changed:
            steps.append("vcm_restart")
    if "ETC" in changed:
        steps.append("policy_reload")
    return ChangePlan(True, hardware_changed, tuple(changed), tuple(dict.fromkeys(steps)))


def _fsync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_json_atomic(path: Path, document: object) -> Path:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o640)
            json.dump(
                document,
                output,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            )
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise
    return path


def atomic_publish(candidate_path: Path, runtime_dir: Path) -> Path:
    document = validate_runtime(_load_object(candidate_path))
    try:
        directory_stat = runtime_dir.lstat()
    except FileNotFoundError:
        runtime_dir.mkdir(mode=0o750, parents=True)
    else:
        if stat.S_ISLNK(directory_stat.st_mode) or not stat.S_ISDIR(directory_stat.st_mode):
            raise ConfigError(f"runtime directory is not a real directory: {runtime_dir}")
    final_path = runtime_dir / RUNTIME_NAME
    try:
        final_stat = final_path.lstat()
    except FileNotFoundError:
        pass
    else:
        if stat.S_ISLNK(final_stat.st_mode) or not stat.S_ISREG(final_stat.st_mode):
            raise ConfigError(f"runtime path is not a real regular file: {final_path}")
    write_json_atomic(final_path, document)
    for alias_name in ALIAS_NAMES:
        alias_path = runtime_dir / alias_name
        try:
            alias_stat = alias_path.lstat()
        except FileNotFoundError:
            pass
        else:
            if stat.S_ISDIR(alias_stat.st_mode) and not stat.S_ISLNK(alias_stat.st_mode):
                raise ConfigError(f"runtime alias is a directory: {alias_path}")
            alias_path.unlink()
        alias_path.symlink_to(RUNTIME_NAME)
    _fsync_directory(runtime_dir)
    return final_path


def _read_runtime(path: Path) -> dict[str, object]:
    return validate_runtime(_load_object(path))


def _write_output(path: Path, document: object) -> None:
    write_json_atomic(path, document)


def _paths_alias(first: Path, second: Path) -> bool:
    try:
        return first.samefile(second)
    except FileNotFoundError:
        return first.resolve(strict=False) == second.resolve(strict=False)


def _reject_output_aliases(outputs: Sequence[Path], inputs: Sequence[Path]) -> None:
    for output in outputs:
        for input_path in inputs:
            if _paths_alias(output, input_path):
                raise ConfigError(f"output must not replace input: {output}")
    for index, output in enumerate(outputs):
        for other in outputs[index + 1 :]:
            if _paths_alias(output, other):
                raise ConfigError(f"outputs must be distinct: {output}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("stage")
    stage.add_argument("--source-root", type=Path, required=True)
    stage.add_argument("--candidate", type=Path, required=True)
    stage.add_argument("--result", type=Path, required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--file", type=Path, required=True)
    plan = commands.add_parser("plan")
    plan.add_argument("--current", type=Path, required=True)
    plan.add_argument("--candidate", type=Path, required=True)
    plan.add_argument("--output", type=Path, required=True)
    projection = commands.add_parser("projection")
    projection.add_argument("--file", type=Path, required=True)
    projection.add_argument("--output", type=Path, required=True)
    publish = commands.add_parser("publish")
    publish.add_argument("--candidate", type=Path, required=True)
    publish.add_argument("--runtime-dir", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "stage":
            candidate = merge_source_documents(arguments.source_root)
            _reject_output_aliases(
                (arguments.candidate, arguments.result),
                (candidate.source.path, candidate.ord_path),
            )
            _write_output(arguments.candidate, candidate.document)
            stage_result = asdict(candidate.source)
            stage_result["path"] = str(candidate.source.path)
            _write_output(arguments.result, stage_result)
        elif arguments.command == "validate":
            _read_runtime(arguments.file)
        elif arguments.command == "plan":
            current = _read_runtime(arguments.current)
            candidate = _read_runtime(arguments.candidate)
            _reject_output_aliases((arguments.output,), (arguments.current, arguments.candidate))
            _write_output(arguments.output, asdict(classify_change(current, candidate)))
        elif arguments.command == "projection":
            _write_output(arguments.output, hardware_projection(_read_runtime(arguments.file)))
        elif arguments.command == "publish":
            atomic_publish(arguments.candidate, arguments.runtime_dir)
    except ConfigError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
