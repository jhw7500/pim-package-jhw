#!/usr/bin/env python3
"""Offline checks for the systemd side of the persisted QA restart barrier.

These cases use only temporary files; they never start services or access a PIM.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SH = ROOT / "dist/pim/opt/pim/bin/qa_maintenance_exec_condition.sh"
UNITS = ROOT / "dist/pim/etc/systemd/system"
EXEC = "ExecCondition=/bin/sh /opt/pim/bin/qa_maintenance_exec_condition.sh"


class SystemdStartBarrierTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.state = self.base / "state"
        self.state.mkdir()

    def run_gate(self, path=None):
        env = dict(os.environ, PIM_CAMERA_STATE_DIR=str(path or self.state))
        return subprocess.run(["/bin/sh", str(SH)], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=5).returncode

    def test_empty_state_can_start(self):
        self.assertEqual(self.run_gate(), 0)

    def test_restore_pending_marker_refuses_start(self):
        (self.state / "qa-maintenance.json").write_text('{"phase":"RESTORE_PENDING"}')
        self.assertEqual(self.run_gate(), 1)

    def test_invalid_json_still_refuses_start(self):
        (self.state / "qa-maintenance.json").write_text("{invalid")
        self.assertEqual(self.run_gate(), 1)

    def test_dangling_marker_symlink_still_refuses_start(self):
        (self.state / "qa-maintenance.json").symlink_to(self.base / "missing")
        self.assertEqual(self.run_gate(), 1)

    def test_live_marker_symlink_still_refuses_start(self):
        target = self.base / "target"
        target.write_text("x")
        (self.state / "qa-maintenance.json").symlink_to(target)
        self.assertEqual(self.run_gate(), 1)

    def test_marker_directory_still_refuses_start(self):
        (self.state / "qa-maintenance.json").mkdir()
        self.assertEqual(self.run_gate(), 1)

    def test_missing_state_directory_is_fail_closed(self):
        self.assertEqual(self.run_gate(self.base / "missing"), 1)

    def test_symlinked_state_directory_is_fail_closed(self):
        other = self.base / "alias"
        other.symlink_to(self.state, target_is_directory=True)
        self.assertEqual(self.run_gate(other), 1)

    def test_gate_does_not_delete_or_modify_marker(self):
        marker = self.state / "qa-maintenance.json"
        marker.write_bytes(b"BAD\n")
        self.assertEqual(self.run_gate(), 1)
        self.assertEqual(marker.read_bytes(), b"BAD\n")

    def test_both_writer_services_have_fail_closed_exec_condition(self):
        for name in ("cam-operate.service", "ord-operate.service"):
            with self.subTest(name=name):
                text = (UNITS / name).read_text(encoding="utf-8")
                self.assertEqual(text.count(EXEC), 1)
                self.assertLess(text.index(EXEC), text.index("ExecStart="))
        # No implicit service enable/install of a QA restorer in this patch.
        self.assertNotIn("pim-qa-restore.service",
                         (UNITS / "cam-operate.service").read_text())


if __name__ == "__main__":
    unittest.main()
