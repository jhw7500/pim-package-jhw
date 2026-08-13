#!/usr/bin/env python3
"""Verify camera-health service entrypoints survive checkout and packaging."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = ROOT / "dist/pim"
ENTRYPOINTS = (
    Path("opt/pim/bin/camera_config_bootstrap.sh"),
    Path("opt/pim/bin/camera_capture_probe.py"),
    Path("opt/pim/bin/camera_config_expectation.py"),
    Path("opt/pim/bin/camera_health_shadow_compare.py"),
    Path("opt/pim/bin/camera_healthd.py"),
)


def tracked_mode(path: Path) -> str:
    relative = (PACKAGE_ROOT / path).relative_to(ROOT)
    result = subprocess.run(
        ["git", "ls-files", "--stage", "--", str(relative)],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    fields = result.stdout.split()
    return fields[0] if fields else "UNTRACKED"


def is_executable(path: Path) -> bool:
    return bool(path.stat().st_mode & stat.S_IXUSR) and os.access(path, os.X_OK)


def main() -> int:
    print("=== camera health package executables ===")
    failures = 0

    for entrypoint in ENTRYPOINTS:
        mode = tracked_mode(entrypoint)
        if mode == "100755":
            print(f"  OK   git mode 100755: {entrypoint.name}")
        else:
            failures += 1
            print(
                f"  FAIL git mode for {entrypoint.name}: {mode} (expected 100755)",
                file=sys.stderr,
            )

    with tempfile.TemporaryDirectory(prefix="pim-camera-package-mode.") as temporary:
        work = Path(temporary)
        package = work / "pim-camera.deb"
        extracted = work / "root"
        subprocess.run(
            ["dpkg-deb", "--build", str(PACKAGE_ROOT), str(package)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            ["dpkg-deb", "--extract", str(package), str(extracted)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        for entrypoint in ENTRYPOINTS:
            installed = extracted / entrypoint
            if is_executable(installed):
                print(f"  OK   packaged executable: {entrypoint.name}")
            else:
                failures += 1
                print(
                    f"  FAIL packaged entrypoint is not executable: {entrypoint}",
                    file=sys.stderr,
                )

    passed = len(ENTRYPOINTS) * 2 - failures
    print()
    print(f"camera health package executables: {passed} passed / {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
