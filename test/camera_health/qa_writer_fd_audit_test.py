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

    def result(self, *, owner_observation=None):
        return audit.audit(self.proc, self.sd,
                           owner_observation=owner_observation)

    def owner_status(self, *, pid=123, start="12345"):
        # Exact deny-only shape returned by cam-recoveryctl owner-observe.
        return {
            "schema": 1, "decision": "BLOCK",
            "reason_code": "OWNER_PROCESS_OBSERVED_NO_WRITER_FENCE",
            "owner_process_observed": True,
            "owner": {
                "boot_id": "boot-a", "invocation_id": "inv-42",
                "pid": pid, "proc_start_time": start, "lifecycle": "ACTIVE"
            },
            "official_lease_verified": False, "eos_verified": False,
            "fsync_verified": False, "writer_fd_closed_verified": False,
            "writer_cannot_reopen": False, "writer_fence_session": None,
            "hardware_execution_authorized": False,
        }

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
        self.assertEqual(r["active_writer_generations"], [
            {"pid": 123, "comm": "gstApp", "proc_start_time": "12345"}
        ])
        self.assertIn("ACTIVE_WRITER_PROCESS", r["reason_codes"])

    def test_unrelated_process_opening_recording_for_write_is_blocked(self):
        self.process(comm="python3")
        r = self.result()
        self.assertEqual(r["recording_write_fds"], [{"pid": 123, "fd": 5}])
        self.assertEqual(r["recording_write_fd_generations"], [
            {"pid": 123, "fd": 5, "proc_start_time": "12345"}
        ])
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

    def test_owner_pid_starttime_matches_same_proc_scan_but_not_a_fence(self):
        self.process(comm="chk_cam_operate", with_fd=False)
        r = self.result(owner_observation=self.owner_status())
        self.assertTrue(r["owner_observation_supplied"])
        self.assertTrue(r["owner_pid_starttime_observed"])
        self.assertFalse(r["owner_observation_trusted"])
        self.assertIn("OWNER_PID_STARTTIME_OBSERVED_NO_FENCE", r["reason_codes"])
        self.assertEqual(r["decision"], "BLOCK")
        self.assertFalse(r["official_lease_verified"])
        self.assertFalse(r["writer_cannot_reopen"])
        self.assertIsNone(r["writer_fence_session"])

    def test_matching_pid_but_changed_starttime_denies_owner_observation(self):
        self.process(comm="chk_cam_operate", with_fd=False)
        r = self.result(owner_observation=self.owner_status(start="99999"))
        self.assertFalse(r["owner_pid_starttime_observed"])
        self.assertIn("OWNER_PID_STARTTIME_CHANGED_OR_ABSENT", r["reason_codes"])

    def test_older_missing_owner_process_is_not_assumed_dead_and_safe(self):
        r = self.result(owner_observation=self.owner_status())
        self.assertFalse(r["owner_pid_starttime_observed"])
        self.assertEqual(r["decision"], "BLOCK")
        self.assertIn("OWNER_PID_STARTTIME_CHANGED_OR_ABSENT", r["reason_codes"])

    def test_owner_observation_with_spoofed_token_is_rejected(self):
        self.process(comm="chk_cam_operate", with_fd=False)
        forged = self.owner_status()
        forged["owner"]["token"] = "SECRET"
        r = self.result(owner_observation=forged)
        self.assertFalse(r["owner_pid_starttime_observed"])
        self.assertIn("OWNER_OBSERVATION_UNTRUSTED", r["reason_codes"])
        self.assertNotIn("SECRET", str(r))

    def test_owner_observation_claiming_lease_or_execution_is_rejected(self):
        self.process(comm="chk_cam_operate", with_fd=False)
        for field, value in (
            ("official_lease_verified", True),
            ("hardware_execution_authorized", True),
            ("writer_fence_session", "claimed-lease"),
            ("writer_cannot_reopen", True),
            ("decision", "ALLOW"),
            ("schema", True),
        ):
            observation = self.owner_status()
            observation[field] = value
            with self.subTest(field=field):
                r = self.result(owner_observation=observation)
                self.assertIn("OWNER_OBSERVATION_UNTRUSTED",
                              r["reason_codes"])
                self.assertFalse(r["owner_pid_starttime_observed"])

    def test_owner_observation_bool_pid_and_malformed_start_refused(self):
        self.process(comm="chk_cam_operate", with_fd=False)
        for owner_field, value in (("pid", True), ("pid", 0),
                                   ("proc_start_time", 12345),
                                   ("proc_start_time", "12abc"),
                                   ("boot_id", "boot-a\\nforged"),
                                   ("lifecycle", "QUIESCED")):
            observation = self.owner_status()
            observation["owner"][owner_field] = value
            with self.subTest(field=owner_field, value=value):
                r = self.result(owner_observation=observation)
                self.assertIn("OWNER_OBSERVATION_UNTRUSTED",
                              r["reason_codes"])
                self.assertFalse(r["owner_pid_starttime_observed"])

    def test_matching_owner_cannot_hide_active_writer_and_open_file(self):
        self.process(comm="gstApp", with_fd=True)
        r = self.result(owner_observation=self.owner_status())
        self.assertTrue(r["owner_pid_starttime_observed"])
        self.assertIn("ACTIVE_WRITER_PROCESS", r["reason_codes"])
        self.assertIn("RECORDING_WRITABLE_FD_OPEN", r["reason_codes"])
        self.assertEqual(r["decision"], "BLOCK")

    def test_failed_pid_scan_does_not_retain_owner_match(self):
        self.process(comm="chk_cam_operate", with_fd=False)
        with mock.patch.object(audit, "_pid_snapshot",
                               side_effect=audit.AuditBlocked("scan failed")):
            r = self.result(owner_observation=self.owner_status())
        self.assertIsNone(r["owner_pid_starttime_observed"])
        self.assertIn("READ_ONLY_OBSERVATION_INCOMPLETE",
                      r["reason_codes"])

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
