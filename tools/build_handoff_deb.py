#!/usr/bin/env python3
"""Build an externally shareable PIM DEB without modifying ``dist/pim``."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, Tuple


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_VERSION = "0.6.3+jhw.camera1"
DEFAULT_SOURCE = ROOT / "dist/pim"
DEFAULT_OUTPUT = ROOT / "handover/pim-package-jhw-camera-vpu-20260831"
BANNED_NAMES = {".omc", ".bkit", ".serena", ".vscode", "__pycache__"}
VERSION_PATTERN = re.compile(r"^[0-9A-Za-z.+:~_-]+$")

ManifestEntry = Tuple[str, int, str]
PayloadManifest = Dict[str, ManifestEntry]


def control_field(control: Path, name: str) -> str:
    prefix = f"{name}:"
    values = [
        line[len(prefix):].strip()
        for line in control.read_text(encoding="utf-8").splitlines()
        if line.startswith(prefix)
    ]
    if len(values) != 1 or not values[0]:
        raise ValueError(f"expected one non-empty {name} field, found {len(values)}")
    return values[0]


def rewrite_version(control: Path, version: str) -> None:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"invalid Debian version: {version!r}")
    lines = control.read_text(encoding="utf-8").splitlines()
    matches = [
        index for index, line in enumerate(lines) if line.startswith("Version:")
    ]
    if len(matches) != 1:
        raise ValueError(f"expected one Version field, found {len(matches)}")
    lines[matches[0]] = f"Version: {version}"
    control.write_text("\n".join(lines) + "\n", encoding="utf-8")


def remove_banned(root: Path) -> None:
    candidates = sorted(root.rglob("*"), key=lambda path: len(path.parts), reverse=True)
    for path in candidates:
        if path.name not in BANNED_NAMES or path.is_symlink():
            continue
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def payload_manifest(root: Path) -> PayloadManifest:
    manifest: PayloadManifest = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if relative.parts[0] == "DEBIAN" or any(
            part in BANNED_NAMES for part in relative.parts
        ):
            continue

        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        key = relative.as_posix()
        if stat.S_ISLNK(metadata.st_mode):
            manifest[key] = ("link", mode, os.readlink(path))
        elif stat.S_ISDIR(metadata.st_mode):
            manifest[key] = ("dir", mode, "")
        elif stat.S_ISREG(metadata.st_mode):
            manifest[key] = ("file", mode, sha256_file(path))
        else:
            raise ValueError(f"unsupported payload entry: {relative}")
    return manifest


def describe_manifest_difference(
    expected: PayloadManifest, actual: PayloadManifest
) -> str:
    expected_keys = set(expected)
    actual_keys = set(actual)
    missing = sorted(expected_keys - actual_keys)
    extra = sorted(actual_keys - expected_keys)
    changed = sorted(
        key for key in expected_keys & actual_keys if expected[key] != actual[key]
    )
    details = []
    if missing:
        details.append("missing=" + ",".join(missing[:10]))
    if extra:
        details.append("extra=" + ",".join(extra[:10]))
    if changed:
        details.append("changed=" + ",".join(changed[:10]))
    return "DEB payload mismatch: " + "; ".join(details)


def validate_deb_fields(
    output: Path, package: str, version: str, architecture: str
) -> None:
    fields = [
        subprocess.check_output(
            ["dpkg-deb", "-f", str(output), field], text=True
        ).strip()
        for field in ("Package", "Version", "Architecture")
    ]
    expected = [package, version, architecture]
    if fields != expected:
        raise RuntimeError(f"DEB metadata mismatch: expected {expected}, got {fields}")


def build_package(source: Path, output_dir: Path, version: str) -> Path:
    source = source.resolve()
    control = source / "DEBIAN/control"
    if not control.is_file():
        raise FileNotFoundError(control)

    package = control_field(control, "Package")
    architecture = control_field(control, "Architecture")
    if "/" in package or "/" in architecture:
        raise ValueError("package metadata must not contain path separators")

    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"{package}_{version}_{architecture}.deb"
    if output.exists():
        raise FileExistsError(output)

    try:
        with tempfile.TemporaryDirectory(prefix="pim-handoff-stage.") as temporary:
            stage = Path(temporary) / "pim"
            shutil.copytree(source, stage, symlinks=True)
            remove_banned(stage)
            rewrite_version(stage / "DEBIAN/control", version)
            expected = payload_manifest(stage)

            subprocess.run(
                [
                    "dpkg-deb",
                    "--root-owner-group",
                    "--build",
                    str(stage),
                    str(output),
                ],
                check=True,
            )

            extracted = Path(temporary) / "extracted"
            subprocess.run(
                ["dpkg-deb", "-x", str(output), str(extracted)], check=True
            )
            actual = payload_manifest(extracted)
            if actual != expected:
                raise RuntimeError(describe_manifest_difference(expected, actual))
            validate_deb_fields(output, package, version, architecture)
    except Exception:
        if output.exists():
            output.unlink()
        raise

    print(f"DEB={output}")
    print(f"SHA256={sha256_file(output)}")
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and audit the camera/VPU external handoff DEB."
    )
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        build_package(args.source, args.output_dir, args.version)
    except (FileNotFoundError, FileExistsError, ValueError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"ERROR: command failed with exit {error.returncode}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
