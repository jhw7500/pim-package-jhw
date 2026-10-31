#!/usr/bin/env python3
"""No-board /proc Writer audit regression suite."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "tools/qa_writer_fd_audit.py"
spec = importlib.util.spec_from_file_location("qa_writer_fd_audit", SOURCE)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class WriterFdAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.proc = self.root / "proc"
        self.proc.mkdir()
        self.sd = self.root / "sd"
        self.sd.mkdir()
        (self.sd / "video.mp4").write_bytes(b"data")

    def process(self, pid=123, comm="other", fd=5, flags="0100001",
                target=None, with_fd=True):
        p = self.proc / str(pid)
        p.mkdir()
        (p / "comm").write_text(comm + "\n")
        # fields after closing ')' begin at field 3, starttime is field 22.
        (p / "stat").write_text("{} ({}) S {} 12345 0\n".format(
            pid, comm, " ".join(["0"] * 18)))
        (p / "fd").mkdir()
        (p / "fdinfo").mkdir()
        if with_fd:
            (p / "fd" / str(fd)).symlink_to(target or (self.sd / "video.mp4"))
            (p / "fdinfo" / str(fd)).write_text("pos:\t0\nflags:\t{}\n".format(flags))
        return p

    def result(self):
        return audit.audit(self.proc, self.sd)

    def test_empty_proc_not_mistaken_for_fence(self):
        r = self.result()
        self.assertEqual(r["decision"], "BLOCK")
        self.assertIsNone(r["writer_fence_session"])
        self.assertFalse(r["eos_verified"])
        self.assertIn("OWNER_NO_REOPEN_FENCE_NOT_ATTESTED", r["reason_codes"])

    def test_running_gstapp_is_blocked(self):
        self.process(comm="gstApp", with_fd=False)
        r = self.result()
        self.assertEqual(r["active_writer_pids"], [123])
        self.assertIn("ACTIVE_WRITER_PROCESS", r["reason_codes"])

    def test_unrelated_process_opening_recording_for_write_is_blocked(self):
        self.process(comm="python3")
        r = self.result()
        self.assertEqual(r["recording_write_fds"], [{"pid": 123, "fd": 5}])
        self.assertIn("RECORDING_WRITABLE_FD_OPEN", r["reason_codes"])

    def test_read_only_recording_fd_not_counted_as_writer(self):
        self.process(comm="cat", flags="0100000")
        r = self.result()
        self.assertEqual(r["recording_write_fds"], [])
        self.assertIn("EOS_FSYNC_NOT_ATTESTED", r["reason_codes"])

    def test_not_confused_by_similar_path_prefix(self):
        different = self.root / "sd-other"
        different.mkdir()
        other = different / "video.mp4"
        other.write_bytes(b"unrelated")
        self.process(target=other)
        self.assertEqual(self.result()["recording_write_fds"], [])

    def test_deleted_recording_fd_is_still_a_writer(self):
        p = self.process()
        (p / "fd" / "5").unlink()
        (p / "fd" / "5").symlink_to(str(self.sd / "video.mp4") + " (deleted)")
        self.assertEqual(len(self.result()["recording_write_fds"]), 1)

    def test_unknown_fdinfo_denies_clean_observation(self):
        p = self.process()
        (p / "fdinfo" / "5").unlink()
        self.assertIn("READ_ONLY_OBSERVATION_INCOMPLETE", self.result()["reason_codes"])

    def test_non_octal_fdinfo_denies(self):
        self.process(flags="NOT_OCTAL")
        self.assertIn("READ_ONLY_OBSERVATION_INCOMPLETE", self.result()["reason_codes"])

    def test_part_recording_denies(self):
        (self.sd / "segment.mp4.part").write_bytes(b"unfinished")
        r = self.result()
        self.assertEqual(r["partial_recording_files"], 1)
        self.assertIn("RECORDING_PARTIAL_FILES_PRESENT", r["reason_codes"])

    def test_symlink_in_recording_tree_denies(self):
        (self.sd / "external").symlink_to(self.root)
        self.assertIn("READ_ONLY_OBSERVATION_INCOMPLETE", self.result()["reason_codes"])

    def test_symlink_proc_root_denies(self):
        alias = self.root / "fake-proc"
        alias.symlink_to(self.proc, target_is_directory=True)
        r = audit.audit(alias, self.sd)
        self.assertIn("READ_ONLY_OBSERVATION_INCOMPLETE", r["reason_codes"])

    def test_proc_stat_pid_reuse_denies(self):
        self.process()
        real = audit._proc_start
        with mock.patch.object(audit, "_proc_start", side_effect=["111", "222"]):
            r = self.result()
        self.assertIn("READ_ONLY_OBSERVATION_INCOMPLETE", r["reason_codes"])

    def test_symlink_pid_directory_denies(self):
        (self.proc / "123").symlink_to(self.root, target_is_directory=True)
        self.assertIn("READ_ONLY_OBSERVATION_INCOMPLETE", self.result()["reason_codes"])

    def test_missing_recording_root_is_blocked(self):
        r = audit.audit(self.proc, self.root / "no-sd")
        self.assertIn("RECORDING_ROOT_UNTRUSTED", r["reason_codes"])

    def test_never_alters_media_or_process_records(self):
        self.process(comm="other")
        before = (self.sd / "video.mp4").read_bytes()
        pid_before = (self.proc / "123/stat").read_bytes()
        self.result()
        self.assertEqual((self.sd / "video.mp4").read_bytes(), before)
        self.assertEqual((self.proc / "123/stat").read_bytes(), pid_before)


if __name__ == "__main__":
    unittest.main()
