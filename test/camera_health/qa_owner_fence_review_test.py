#!/usr/bin/env python3
"""Offline Owner fencing phases, stale holder, and restore-before-release.

No systemd interaction, hardware, SSH, process signalling or recording IO.
"""
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SRC = Path(__file__).resolve().parents[2] / "tools" / "qa_owner_fence_review.py"
spec = importlib.util.spec_from_file_location("qa_owner_fence_review", SRC)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class ReviewContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "review"
        self.root.mkdir(mode=0o700)
        sentinel = self.root / ".offline-only"
        sentinel.write_bytes(qa.MAGIC)
        sentinel.chmod(0o600)
        self.owner = dict(boot_id="boot-1", invocation_id="owner-42",
                          pid=4242, proc_start_time="555", source_sha="a" * 40)
        self.lease = dict(board_id="pim", holder_id="hld-1", session="qa-2",
                          generation=12, mode="exclusive",
                          live=True, expired=False)
        self.baseline = "b" * 64
        self.writer = dict(boot_id="boot-1", owner_invocation="owner-42",
                           lease_generation=12, eos=True, file_fsync=True,
                           finalizer_closed=True, writable_fd_count=0,
                           restart_inhibited=True, writer_cannot_reopen=True)
        self.restored = dict(baseline_sha256=self.baseline,
                             channel_zero_only=True, fps=15, all_leds_off=True,
                             camera_ready=True, ord_ready=True, vcm_ready=True)

    def obj(self):
        return qa.OwnerFenceReview(self.root)

    def begin(self):
        return self.obj().begin(self.owner, self.lease, self.baseline)

    def quiesce(self):
        self.begin()
        return self.obj().confirm_quiesced(self.owner, self.lease, self.writer, 0)

    def assert_no_grant(self, result):
        self.assertEqual(result["decision"], "BLOCK")
        self.assertIsNone(result["writer_fence_session"])
        self.assertFalse(result["hardware_execution_authorized"])
        self.assertFalse(result["writer_cannot_reopen"])
        self.assertFalse(result["writer_closed"])

    def test_begin_persists_quiescing_but_cannot_grant(self):
        result = self.begin()
        self.assertEqual(result["phase"], "QUIESCING")
        self.assertEqual(result["revision"], 0)
        self.assert_no_grant(result)
        self.assertEqual(self.obj().status(), result)
        self.assertEqual((self.root / qa.NAME).stat().st_mode & 0o777, 0o600)

    def test_complete_synthetic_proof_never_grants_real_fence(self):
        result = self.quiesce()
        self.assertEqual(result["phase"], "QUIESCED_REVIEW")
        self.assertEqual(result["revision"], 1)
        self.assert_no_grant(result)

    def test_transition_digest_matches_unsigned_journal_at_every_step(self):
        self.begin()
        self.obj().confirm_quiesced(self.owner, self.lease, self.writer, 0)
        changed = dict(self.lease, generation=13)
        self.obj().reconcile(self.owner, changed)
        self.obj().restore_review(self.restored, 2)
        # Every read must verify the persisted, canonical, digest-free body.
        record = json.loads((self.root / qa.NAME).read_text())
        unsigned = {key: value for key, value in record.items()
                    if key != "digest"}
        self.assertEqual(record["digest"], qa._digest(unsigned))
        self.assertEqual(self.obj().status()["phase"],
                         "FINAL_ATTESTATION_PENDING")

    def test_lost_writer_fsync_refuses_quiesce(self):
        self.begin()
        bad = dict(self.writer, file_fsync=False)
        with self.assertRaises(qa.FenceDenied):
            self.obj().confirm_quiesced(self.owner, self.lease, bad, 0)
        self.assertEqual(self.obj().status()["phase"], "QUIESCING")

    def test_open_write_fd_refuses(self):
        self.begin()
        bad = dict(self.writer, writable_fd_count=1)
        with self.assertRaises(qa.FenceDenied):
            self.obj().confirm_quiesced(self.owner, self.lease, bad, 0)

    def test_false_no_reopen_refuses(self):
        self.begin()
        bad = dict(self.writer, writer_cannot_reopen=False)
        with self.assertRaises(qa.FenceDenied):
            self.obj().confirm_quiesced(self.owner, self.lease, bad, 0)

    def test_owner_mismatch_refuses(self):
        self.begin()
        changed = dict(self.owner, invocation_id="new-owner")
        with self.assertRaises(qa.FenceDenied):
            self.obj().confirm_quiesced(changed, self.lease, self.writer, 0)

    def test_lease_generation_changes_then_restore_pending(self):
        self.quiesce()
        changed = dict(self.lease, generation=13)
        result = self.obj().reconcile(self.owner, changed)
        self.assertEqual(result["phase"], "RESTORE_PENDING")
        self.assertEqual(result["revision"], 2)
        self.assert_no_grant(result)
        self.assertEqual(self.obj().status(), result)

    def test_owner_reboot_invalidates_old_review(self):
        self.quiesce()
        changed = dict(self.owner, boot_id="boot-2")
        self.assertEqual(self.obj().reconcile(changed, self.lease)["phase"],
                         "RESTORE_PENDING")

    def test_expired_lease_invalidates_old_review(self):
        self.quiesce()
        changed = dict(self.lease, expired=True, live=False)
        self.assertEqual(self.obj().reconcile(self.owner, changed)["phase"],
                         "RESTORE_PENDING")

    def test_same_owner_is_read_only_and_idempotent(self):
        self.quiesce()
        before = (self.root / qa.NAME).read_bytes()
        report = self.obj().reconcile(self.owner, self.lease)
        self.assertEqual(report["revision"], 1)
        self.assertEqual((self.root / qa.NAME).read_bytes(), before)

    def test_recovery_is_idempotent_on_lost_owner(self):
        self.quiesce()
        changed = dict(self.owner, boot_id="boot-2")
        a = self.obj().reconcile(changed, self.lease)
        b = self.obj().reconcile(changed, self.lease)
        self.assertEqual(a, b)
        self.assertEqual(a["revision"], 2)

    def test_restore_proof_still_requires_external_attestation(self):
        self.quiesce()
        self.obj().reconcile(dict(self.owner, boot_id="boot-2"), self.lease)
        final = self.obj().restore_review(self.restored, 2)
        self.assertEqual(final["phase"], "FINAL_ATTESTATION_PENDING")
        self.assert_no_grant(final)

    def test_wrong_baseline_refuses_restore(self):
        self.quiesce()
        self.obj().reconcile(dict(self.owner, boot_id="boot-2"), self.lease)
        with self.assertRaises(qa.FenceDenied):
            self.obj().restore_review(dict(self.restored,
                                           baseline_sha256="c" * 64), 2)

    def test_led_on_refuses_restore(self):
        self.quiesce()
        self.obj().reconcile(dict(self.owner, boot_id="boot-2"), self.lease)
        with self.assertRaises(qa.FenceDenied):
            self.obj().restore_review(dict(self.restored, all_leds_off=False), 2)

    def test_bad_original_channel_fps_refuses_restore(self):
        self.quiesce()
        self.obj().reconcile(dict(self.owner, boot_id="boot-2"), self.lease)
        with self.assertRaises(qa.FenceDenied):
            self.obj().restore_review(dict(self.restored, fps=30), 2)

    def test_no_restore_before_pending(self):
        self.quiesce()
        with self.assertRaises(qa.FenceDenied):
            self.obj().restore_review(self.restored, 1)

    def test_stale_revision_is_denied(self):
        self.begin()
        with self.assertRaises(qa.FenceDenied):
            self.obj().confirm_quiesced(self.owner, self.lease, self.writer, 99)

    def test_corrupted_journal_fails_closed(self):
        self.begin()
        (self.root / qa.NAME).write_text("{bad", encoding="utf-8")
        with self.assertRaises(qa.FenceDenied):
            self.obj().status()

    def test_content_mutation_digest_mismatch(self):
        self.begin()
        file = self.root / qa.NAME
        obj = json.loads(file.read_text())
        obj["phase"] = "QUIESCED_REVIEW"
        file.write_text(json.dumps(obj))
        with self.assertRaises(qa.FenceDenied):
            self.obj().status()

    def test_duplicate_begin_rejected(self):
        self.begin()
        with self.assertRaises(qa.FenceDenied):
            self.begin()

    def test_invalid_lease_and_generation_bool_denied(self):
        for lease in (dict(self.lease, generation=True),
                      dict(self.lease, mode="shared"),
                      dict(self.lease, expired=True)):
            with self.subTest(lease=lease), self.assertRaises(qa.FenceDenied):
                self.obj().begin(self.owner, lease, self.baseline)

    def test_dangling_symlink_journal_not_overwritten(self):
        (self.root / qa.NAME).symlink_to(self.root / "missing")
        with self.assertRaises(qa.FenceDenied):
            self.begin()
        self.assertTrue((self.root / qa.NAME).is_symlink())

    def test_hardlinked_journal_denied(self):
        self.begin()
        target = self.root / "another.json"
        os.link(self.root / qa.NAME, target)
        with self.assertRaises(qa.FenceDenied):
            self.obj().status()

    def test_lock_contention_denies_concurrent_owner(self):
        lock = self.root / ".owner-review.lock"
        fd = os.open(str(lock), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(qa.FenceDenied):
                self.begin()
        finally:
            os.close(fd)

    def test_offline_sentinel_required(self):
        (self.root / ".offline-only").unlink()
        with self.assertRaises(qa.FenceDenied):
            self.obj()

    def test_sandbox_symlink_rejected(self):
        alias = Path(self.tmp.name) / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(qa.FenceDenied):
            qa.OwnerFenceReview(alias)

    def test_reject_boolean_pid_and_bad_process_starttime(self):
        for owner in (dict(self.owner, pid=True),
                      dict(self.owner, pid=0),
                      dict(self.owner, proc_start_time="not-a-number")):
            with self.subTest(owner=owner), self.assertRaises(qa.FenceDenied):
                self.obj().begin(owner, self.lease, self.baseline)

    def test_boolean_schema_version_is_not_valid_journal(self):
        self.begin()
        file = self.root / qa.NAME
        body = json.loads(file.read_text())
        body["schema"] = True
        unsigned = {k: v for k, v in body.items() if k != "digest"}
        body["digest"] = qa._digest(unsigned)
        file.write_text(json.dumps(body))
        with self.assertRaises(qa.FenceDenied):
            self.obj().status()

    def test_no_script_exports_hardware_action(self):
        import importlib
        mod = qa
        for action in ("start_recording", "systemctl", "ssh", "release_fence",
                       "reboot", "delete_recordings", "issue_hardware_token"):
            self.assertFalse(hasattr(mod, action))
        self.assert_no_grant(self.begin())


if __name__ == "__main__":
    unittest.main()
