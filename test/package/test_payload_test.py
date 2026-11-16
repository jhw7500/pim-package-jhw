#!/usr/bin/env python3
"""Exercise build.sh's packaging section without compiling or touching a board."""

import io
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
REFERENCE = "test/test_final_stall_scenarios.md"
INSTALLED_REFERENCE = "opt/pim/bin/" + REFERENCE


class TestPayloadTest(unittest.TestCase):
    def fixture(self, root, variant, include_reference=True):
        # The repositories deliberately have different developer tests.
        files = {
            "test/" + variant + "-only.sh": "echo " + variant + "\n",
            "test/camera_health/developer.sh": variant + " health\n",
            "test/cam_link/developer.sh": variant + " link\n",
            "test/sync_pim_scope_test.sh": variant + " sync\n",
        }
        if include_reference:
            files[REFERENCE] = (ROOT / REFERENCE).read_text()
        for name in ("max9296/V4L2_CTRL_GUIDE.md", "pim-guardian-runbook.md",
                     "camera-startup-timing.md"):
            files["docs/" + name] = (ROOT / "docs" / name).read_text()
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        package = root / "dist/pim"
        (package / "opt/pim/bin").mkdir(parents=True)
        existing_tests = ROOT / "dist/pim/opt/pim/bin/test"
        if existing_tests.exists():
            shutil.copytree(existing_tests, package / "opt/pim/bin/test", symlinks=True)
        (package / "DEBIAN").mkdir()
        (package / "DEBIAN/control").write_text(
            "Package: pim-payload-fixture\nVersion: 1.0\nArchitecture: all\n"
            "Maintainer: Fixture <fixture@example.invalid>\nDescription: Fixture\n"
        )
        return root / "release/pim"

    def stage(self, root):
        source = (ROOT / "build.sh").read_text()
        start = source.index("    cp -R ${BASEDIR}/dist ${BASEDIR}/release\n")
        block = source[start:]
        block = block.split("    # build pim_gate\n", 1)[0]
        # Native binary copying is outside this test's payload contract.
        return subprocess.run(
            ["bash", "-c", "copy_built() { :; }\n" + block],
            env=dict(os.environ, BASEDIR=str(root)),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def deb_test_files(self, package, output):
        subprocess.run(
            ["dpkg-deb", "--build", "--root-owner-group", str(package), str(output)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        payload = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(output)])
        with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
            files = {}
            for entry in archive.getmembers():
                name = entry.name[2:] if entry.name.startswith("./") else entry.name
                if entry.isfile() and name.startswith("opt/pim/bin/test/"):
                    files[name] = archive.extractfile(entry).read()
            return files

    def test_repository_local_tests_do_not_change_deb_payload(self):
        with tempfile.TemporaryDirectory(prefix="pim-payload.") as tmp:
            outputs = []
            for variant in ("github", "gitlab"):
                root = Path(tmp) / variant
                package = self.fixture(root, variant)
                staged = self.stage(root)
                self.assertEqual(staged.returncode, 0, staged.stderr)
                outputs.append(self.deb_test_files(package, Path(tmp) / (variant + ".deb")))
            expected = {INSTALLED_REFERENCE: (ROOT / REFERENCE).read_bytes()}
            self.assertEqual(outputs[0], expected)
            self.assertEqual(outputs[1], expected)
            self.assertEqual(outputs[0], outputs[1])

    def test_missing_packaged_reference_stops_packaging(self):
        with tempfile.TemporaryDirectory(prefix="pim-payload-missing.") as tmp:
            root = Path(tmp)
            self.fixture(root, "github", include_reference=False)
            staged = self.stage(root)
            self.assertNotEqual(staged.returncode, 0)
            self.assertIn("test_final_stall_scenarios.md", staged.stderr)

    def test_packaged_reference_is_synced_in_both_directions(self):
        for name in ("sync-to-gitlab.sh", "sync-from-gitlab.sh"):
            with self.subTest(script=name):
                match = re.search(r"^PIM_FILES=\((.*?)^\)", (ROOT / name).read_text(),
                                  flags=re.MULTILINE | re.DOTALL)
                self.assertIsNotNone(match)
                self.assertIn(REFERENCE, shlex.split(match.group(1), comments=True))


if __name__ == "__main__":
    unittest.main()
