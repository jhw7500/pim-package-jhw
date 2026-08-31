#!/usr/bin/env python3
"""Contract tests for the staging-only external handoff DEB builder."""

from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/build_handoff_deb.py"


def load_module():
    if not SCRIPT.is_file():
        raise AssertionError(f"missing handoff DEB builder: {SCRIPT}")
    spec = importlib.util.spec_from_file_location("build_handoff_deb", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HandoffDebTest(unittest.TestCase):
    def make_package(self, root: Path) -> Path:
        source = root / "pim"
        (source / "DEBIAN").mkdir(parents=True)
        (source / "opt/pim/bin").mkdir(parents=True)
        (source / "DEBIAN/control").write_text(
            "Package: pim-mp\nVersion: 0.6.3\nArchitecture: arm64\n"
            "Maintainer: PIM\nDescription: test\n",
            encoding="utf-8",
        )
        tool = source / "opt/pim/bin/probe.sh"
        tool.write_text("#!/bin/sh\necho ok\n", encoding="utf-8")
        tool.chmod(0o755)
        (source / "opt/pim/current").symlink_to("bin/probe.sh")
        return source

    def test_build_changes_only_staged_version_and_preserves_payload(self):
        module = load_module()
        with tempfile.TemporaryDirectory(prefix="handoff-deb-test.") as tmp:
            work = Path(tmp)
            source = self.make_package(work)
            original = (source / "DEBIAN/control").read_bytes()
            output = module.build_package(
                source, work / "out", "0.6.3+jhw.camera1"
            )
            self.assertEqual(original, (source / "DEBIAN/control").read_bytes())
            fields = [
                subprocess.check_output(
                    ["dpkg-deb", "-f", str(output), field], text=True
                ).strip()
                for field in ("Package", "Version", "Architecture")
            ]
            self.assertEqual(fields, ["pim-mp", "0.6.3+jhw.camera1", "arm64"])
            with tempfile.TemporaryDirectory(
                prefix="handoff-deb-extract."
            ) as extracted:
                subprocess.run(
                    ["dpkg-deb", "-x", str(output), extracted], check=True
                )
                target = Path(extracted) / "opt/pim/bin/probe.sh"
                self.assertEqual(target.read_bytes(), b"#!/bin/sh\necho ok\n")
                self.assertEqual(target.stat().st_mode & 0o777, 0o755)
                self.assertEqual(
                    (Path(extracted) / "opt/pim/current").readlink(),
                    Path("bin/probe.sh"),
                )

    def test_existing_output_is_refused(self):
        module = load_module()
        with tempfile.TemporaryDirectory(prefix="handoff-deb-test.") as tmp:
            work = Path(tmp)
            source = self.make_package(work)
            output_dir = work / "out"
            output_dir.mkdir()
            expected = output_dir / "pim-mp_0.6.3+jhw.camera1_arm64.deb"
            expected.write_bytes(b"do not overwrite")
            with self.assertRaises(FileExistsError):
                module.build_package(source, output_dir, "0.6.3+jhw.camera1")
            self.assertEqual(expected.read_bytes(), b"do not overwrite")


if __name__ == "__main__":
    unittest.main()
