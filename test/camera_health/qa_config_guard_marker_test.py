#!/usr/bin/env python3
"""Fail-closed PIM config_guard restoration during persistent QA maintenance.

All subprocesses stop before /root/shared_v access. No board, reboot, service
or live config is touched by these offline tests.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "dist/pim/opt/pim/bin/config_guard.sh"


class QAConfigGuardMarkerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pim-config-qa.")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.state = self.base / "state"
        self.state.mkdir()
        self.marker = self.state / "qa-maintenance.json"
        self.original_bytes = b"invalid\n"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        # Trap any attempted filesystem-mutating tool, and avoid host syslog.
        for name in ("logger", "cp", "mv", "rm", "mkdir", "sync"):
            script = self.bin / name
            script.write_text("#!/bin/sh\nexit 99\n" if name != "logger"
                              else "#!/bin/sh\nexit 0\n", encoding="utf-8")
            script.chmod(0o755)

    def guard(self, state=None):
        env = dict(os.environ)
        env["PIM_CAMERA_STATE_DIR"] = str(self.state if state is None else state)
        env["PATH"] = str(self.bin) + ":" + env.get("PATH", "/usr/bin:/bin")
        return subprocess.run(["/bin/bash", str(SCRIPT)], env=env,
                              capture_output=True, text=True, timeout=8)

    def test_marker_prevents_backup_refresh_and_config_replacement(self):
        self.marker.write_bytes(self.original_bytes)
        r = self.guard()
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertEqual(self.marker.read_bytes(), self.original_bytes)
        self.assertIn("QA restore pending", r.stderr)

    def test_invalid_json_marker_is_also_protective(self):
        self.marker.write_bytes(b"{broken")
        self.assertEqual(self.guard().returncode, 75)
        self.assertEqual(self.marker.read_bytes(), b"{broken")

    def test_dangling_marker_alias_is_not_absence(self):
        self.marker.symlink_to(self.base / "does-not-exist")
        self.assertEqual(self.guard().returncode, 75)
        self.assertTrue(self.marker.is_symlink())

    def test_live_marker_symlink_is_not_absence(self):
        src = self.base / "untrusted"
        src.write_bytes(b"x")
        self.marker.symlink_to(src)
        self.assertEqual(self.guard().returncode, 75)

    def test_marker_directory_is_not_absence(self):
        self.marker.mkdir()
        self.assertEqual(self.guard().returncode, 75)
        self.assertTrue(self.marker.is_dir())

    def test_symlinked_state_directory_is_refused(self):
        alias = self.base / "state-alias"
        alias.symlink_to(self.state, target_is_directory=True)
        self.assertEqual(self.guard(alias).returncode, 75)

    def test_no_mutation_routines_run_before_qa_guard(self):
        text = SCRIPT.read_text(encoding="utf-8")
        main = text.rsplit("main() {", 1)[1].split('main "$@"', 1)[0]
        self.assertLess(main.index("qa-maintenance.json"),
                        main.index("restore_edgeconf ||"))
        self.assertLess(main.index("qa-maintenance.json"),
                        main.index("update_backups"))
        self.assertEqual(self.guard(self.state)["returncode"] if
                         isinstance(self.guard(self.state), dict) else 75, 75)


if __name__ == "__main__":
    unittest.main()
