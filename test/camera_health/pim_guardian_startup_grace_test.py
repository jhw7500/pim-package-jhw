#!/usr/bin/env python3
"""Offline contract tests for PIM guardian cold-start grace."""

from __future__ import annotations

import argparse
import importlib.util
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "dist/pim/opt/pim/bin/pim_guardian.py"

spec = importlib.util.spec_from_file_location("pim_guardian", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load pim_guardian.py")
guardian_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guardian_module)


class Tests:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def check(self, condition: bool, label: str) -> None:
        if condition:
            self.passed += 1
            print(f"  OK   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}")

    def run(self) -> int:
        print("=== pim guardian startup grace ===")
        with tempfile.TemporaryDirectory(prefix="guardian-startup-grace.") as temporary:
            root = Path(temporary)
            start_ts = root / "last_start_ts"
            start_delay = root / "pim_cam_start_delay"
            guardian_module.TMP_START_TS = str(start_ts)
            guardian_module.TMP_START_DELAY = str(start_delay)

            obj = object.__new__(guardian_module.PIMHealthGuardian)
            obj.args = argparse.Namespace()
            obj.conf = {"ord": {"ETC": {"camera_startup_grace_sec": 25}}}
            obj.start_time = 1000.0

            start_ts.write_text("1000\n", encoding="utf-8")
            start_delay.write_text("1\n", encoding="utf-8")
            original_time = guardian_module.time.time
            try:
                guardian_module.time.time = lambda: 1024.0
                self.check(
                    obj._in_startup_grace(),
                    "elapsed 24s is protected even when gstApp -d is 1s",
                )

                start_delay.write_text("22\n", encoding="utf-8")
                guardian_module.time.time = lambda: 1025.0
                self.check(
                    not obj._in_startup_grace(),
                    "elapsed 25s exits grace even when prior -d value is 22s",
                )

                obj.conf = {"ord": {"ETC": {"camera_startup_grace_sec": 30}}}
                guardian_module.time.time = lambda: 1029.0
                self.check(obj._in_startup_grace(), "configured 30s grace is honored")
                guardian_module.time.time = lambda: 1030.0
                self.check(not obj._in_startup_grace(), "configured 30s boundary is exact")

                obj.conf = {"ord": {"ETC": {}}}
                guardian_module.time.time = lambda: 1024.0
                self.check(obj._in_startup_grace(), "missing setting defaults to 25s")

                for malformed in ("30", True, -1, 25.5):
                    obj.conf = {
                        "ord": {"ETC": {"camera_startup_grace_sec": malformed}}
                    }
                    guardian_module.time.time = lambda: 1024.0
                    self.check(
                        obj._in_startup_grace(),
                        f"malformed setting {malformed!r} defaults to 25s",
                    )
                    guardian_module.time.time = lambda: 1025.0
                    self.check(
                        not obj._in_startup_grace(),
                        f"malformed setting {malformed!r} expires at 25s",
                    )
            finally:
                guardian_module.time.time = original_time

        print()
        print(f"guardian startup grace: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0


if __name__ == "__main__":
    raise SystemExit(Tests().run())
