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
from itertools import chain
from pathlib import Path
from typing import Dict, Tuple


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "dist/pim"
DEFAULT_OUTPUT = ROOT / "handover/pim-package-jhw-camera-vpu-20260831"
DEFAULT_SOURCE_DATE_EPOCH = 1788134400  # 2026-08-31 00:00:00 UTC
BANNED_NAMES = {".omc", ".bkit", ".serena", ".vscode", "__pycache__"}
REQUIRED_LOCAL_RUNTIME_ARTIFACTS = (
    Path("usr/local/bin/ord"),
    Path("usr/local/bin/vcm"),
    Path("usr/local/bin/vsd"),
)
REQUIRED_RUNTIME_MARKERS = {
    Path("usr/local/bin/ord"): (b"ord-ready", b"INVOCATION_ID"),
}
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


def normalize_permissions(root: Path) -> None:
    for path in chain((root,), root.rglob("*")):
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            continue
        mode = stat.S_IMODE(metadata.st_mode)
        normalized = mode & ~0o022
        if normalized != mode:
            path.chmod(normalized)


def normalize_timestamps(root: Path, source_date_epoch: int) -> None:
    if source_date_epoch < 0:
        raise ValueError("source date epoch must be non-negative")
    paths = sorted(
        chain((root,), root.rglob("*")),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for path in paths:
        os.utime(
            path,
            (source_date_epoch, source_date_epoch),
            follow_symlinks=False,
        )


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


def validate_local_runtime_artifacts(source: Path) -> None:
    for relative in REQUIRED_LOCAL_RUNTIME_ARTIFACTS:
        artifact = source / relative
        if artifact.is_symlink() or not artifact.is_file():
            raise FileNotFoundError(
                f"required local runtime artifact missing: {relative}"
            )
        metadata = artifact.stat()
        if metadata.st_size == 0:
            raise ValueError(f"required local runtime artifact is empty: {relative}")
        if stat.S_IMODE(metadata.st_mode) & 0o111 == 0:
            raise ValueError(
                f"required local runtime artifact is not executable: {relative}"
            )
        payload = artifact.read_bytes()
        missing_markers = [
            marker.decode("ascii")
            for marker in REQUIRED_RUNTIME_MARKERS.get(relative, ())
            if marker not in payload
        ]
        if missing_markers:
            raise ValueError(
                f"required local runtime artifact is stale: {relative}; "
                f"missing markers: {', '.join(missing_markers)}"
            )


    # A direct external handoff DEB bypasses build.sh. If this source tree
    # includes the helper-dependent finalizer, the target executable MUST
    # already have been built and staged, not silently omitted.
    finalizer = source / "opt/pim/bin/chk_cam_operate.sh"
    if finalizer.is_file():
        body = finalizer.read_text(encoding="utf-8")
        if "FINALIZER_NOREPLACE_TOOL" in body:
            helper_relative = Path("opt/pim/bin/finalizer_noreplace")
            helper = source / helper_relative
            if helper.is_symlink() or not helper.is_file():
                raise FileNotFoundError(
                    f"required finalizer helper missing: ${helper_relative}"
                )
            metadata = helper.stat()
            if metadata.st_size < 20 or stat.S_IMODE(metadata.st_mode) & 0o111 == 0:
                raise ValueError(
                    f"finalizer helper is not an executable ELF: ${helper_relative}"
                )
            header = helper.read_bytes()[:20]
            # Target package is arm64: ELF64 little-endian EM_AARCH64=183.
            if not (header[:4] == b"\x7fELF" and header[4] == 2
                    and header[5] == 1 and int.from_bytes(header[18:20], "little") == 183):
                raise ValueError(
                    f"finalizer helper is not AArch64 ELF: ${helper_relative}"
                )
            # A forged/truncated ELF header must not be shipped as a runtime.
            # Fail closed if readelf is unavailable or reports a malformed ELF.
            try:
                check = subprocess.run(
                    ["readelf", "-h", str(helper)],
                    capture_output=True, text=True, timeout=15, check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise ValueError("cannot inspect finalizer ELF") from exc
            if (check.returncode or "Error:" in check.stderr
                    or "Machine:" not in check.stdout
                    or "AArch64" not in check.stdout):
                raise ValueError(
                    f"finalizer helper ELF malformed or wrong machine: ${helper_relative}"
                )
            # Same strict GLIBC gate as normal PIM release builds.
            try:
                strict_glibc_env = {
                    **os.environ,
                    "PIM_GLIBC_GATE": "strict",
                    "PIM_VERIFY_BINARIES": "on",
                    "PIM_MAX_GLIBC": "2.31",
                }
                glibc_check = subprocess.run(
                    ["bash", str(ROOT / "tools/check_glibc.sh"), str(helper)],
                    capture_output=True, text=True, timeout=30, check=False,
                    env=strict_glibc_env,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise ValueError("finalizer GLIBC gate unavailable") from exc
            if glibc_check.returncode:
                raise ValueError(
                    f"finalizer helper fails GLIBC target gate: ${helper_relative}"
                )



def build_package(
    source: Path,
    output_dir: Path,
    version: str | None = None,
    source_date_epoch: int = DEFAULT_SOURCE_DATE_EPOCH,
) -> Path:
    source = source.resolve()
    control = source / "DEBIAN/control"
    if not control.is_file():
        raise FileNotFoundError(control)
    validate_local_runtime_artifacts(source)

    package = control_field(control, "Package")
    architecture = control_field(control, "Architecture")
    # Package 와 Architecture 가 control 에서 오는데 Version 만 호출자 기본값에서
    # 오면, dist/pim 이 올라갈 때마다 라벨이 조용히 뒤처진다. 세 필드를 같은
    # source 에서 읽는다. --version 은 의도적 override 로만 남긴다.
    if version is None:
        version = control_field(control, "Version")
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
            normalize_permissions(stage)
            normalize_timestamps(stage, source_date_epoch)
            expected = payload_manifest(stage)

            build_environment = os.environ.copy()
            build_environment["SOURCE_DATE_EPOCH"] = str(source_date_epoch)

            subprocess.run(
                [
                    "dpkg-deb",
                    "--root-owner-group",
                    "--build",
                    str(stage),
                    str(output),
                ],
                check=True,
                env=build_environment,
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
    parser.add_argument(
        "--version",
        default=None,
        help="override the package version; defaults to the Version field of "
        "<source>/DEBIAN/control",
    )
    parser.add_argument(
        "--source-date-epoch",
        type=int,
        default=DEFAULT_SOURCE_DATE_EPOCH,
        help="fixed UTC timestamp used for reproducible package metadata",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        build_package(
            args.source,
            args.output_dir,
            args.version,
            args.source_date_epoch,
        )
    except (FileNotFoundError, FileExistsError, ValueError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"ERROR: command failed with exit {error.returncode}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
