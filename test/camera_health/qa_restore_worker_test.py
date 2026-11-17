#!/usr/bin/env python3
"""Offline crash/restart and fail-closed Writer evidence tests."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[2] / "tools" / "qa_restore_worker.py"
spec = importlib.util.spec_from_file_location("qa_restore_candidate", MODULE)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


def packed(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def put(folder, name, data):
    path = folder / name
    path.write_bytes(data)
    path.chmod(0o600)
    return path


class OfflineRestoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "restore"
        self.root.mkdir(mode=0o700)
        self.base = self.root / "baseline"
        self.live = self.root / "live"
        self.base.mkdir(mode=0o700)
        self.live.mkdir(mode=0o700)
        put(self.root, ".offline-only", qa.SANDBOX_MAGIC)
        self.contents = {
            "edgeconf.json": b'{"VHL_CAM":{"test":"original"}}\n',
            "ord_vcm.json": b'{"ORD":{"enabled":true},"VCM":{"enabled":true}}\n',
            "merged_runtime.json": b'{"channels":[0],"fps":15}\n',
            "led_state.json": b'{"leds":[false,false,false,false]}\n',
        }
        for k, v in self.contents.items():
            put(self.base, k, v)
            put(self.live, k, v)
        self.record = {
            "schema": 1, "phase": "RESTORE_PENDING",
            "run_id": "qa-example-01", "source_sha": "a" * 40,
            "boot_id": "boot-42", "owner_invocation": "owner-1",
            "lease_generation": 2,
            "baseline": {k: {"sha256": hashlib.sha256(v).hexdigest(), "size": len(v)}
                         for k, v in self.contents.items()},
        }
        self.save_record()

    def save_record(self):
        record = dict(self.record)
        record["digest"] = hashlib.sha256(packed(record)).hexdigest()
        put(self.root, "qa-maintenance.json", packed(record) + b"\n")

    def worker(self):
        return qa.OfflineRestoreWorker(self.root)

    def test_four_file_exact_restore_keeps_final_attestation_pending(self):
        put(self.live, "edgeconf.json", b'{"different":true}\n')
        put(self.live, "led_state.json", b'{"leds":[true,true,true,true]}\n')
        out = self.worker().restore_once()
        self.assertEqual(out["files_repaired"], 2)
        self.assertEqual(out["stage"], "FINAL_ATTESTATION_PENDING")
        self.assertFalse(out["hardware_execution_authorized"])
        for name in qa.FILES:
            self.assertEqual((self.live / name).read_bytes(), self.contents[name])
        self.assertEqual(qa._valid_record((self.root / qa.MARKER).read_bytes())["phase"],
                         "FINAL_ATTESTATION_PENDING")

    def test_repeat_after_success_is_idempotent(self):
        self.worker().restore_once()
        self.assertEqual(self.worker().restore_once()["files_repaired"], 0)

    def test_crash_after_first_fsync_recovers_all_files_next_process(self):
        put(self.live, "edgeconf.json", b'bad config\n')
        put(self.live, "ord_vcm.json", b'broken ord\n')
        with self.assertRaisesRegex(RuntimeError, "injected process"):
            self.worker().restore_once(crash_after=1)
        self.assertEqual(qa._valid_record((self.root / qa.MARKER).read_bytes())["phase"],
                         "RESTORE_PENDING")
        result = self.worker().restore_once()
        self.assertEqual(result["files_repaired"], 1)
        self.assertEqual((self.live / "ord_vcm.json").read_bytes(), self.contents["ord_vcm.json"])

    def test_invalid_marker_fails_closed(self):
        put(self.root, qa.MARKER, b"{not json\n")
        with self.assertRaises(qa.RestoreBlocked):
            self.worker().restore_once()

    def test_baseline_sha_tampering_is_detected(self):
        put(self.base, "edgeconf.json", b'{"tampered":true}\n')
        with self.assertRaisesRegex(qa.RestoreBlocked, "baseline SHA mismatch"):
            self.worker().restore_once()

    def test_symlinked_live_file_is_not_replaced(self):
        (self.live / "edgeconf.json").unlink()
        (self.live / "edgeconf.json").symlink_to(self.root / "outside")
        with self.assertRaises(qa.RestoreBlocked):
            self.worker().restore_once()
        self.assertTrue((self.live / "edgeconf.json").is_symlink())

    def test_missing_live_file_is_not_created(self):
        (self.live / "edgeconf.json").unlink()
        with self.assertRaises(qa.RestoreBlocked):
            self.worker().restore_once()
        self.assertFalse((self.live / "edgeconf.json").exists())

    def test_hardlinked_file_is_not_replaced(self):
        (self.live / "edgeconf.json").unlink()
        os.link(self.base / "edgeconf.json", self.live / "edgeconf.json")
        with self.assertRaisesRegex(qa.RestoreBlocked, "untrusted file"):
            self.worker().restore_once()

    def test_world_readable_file_is_not_accepted(self):
        (self.base / "edgeconf.json").chmod(0o644)
        with self.assertRaisesRegex(qa.RestoreBlocked, "untrusted file"):
            self.worker().restore_once()

    def test_final_attestation_pending_drift_is_not_silently_restored(self):
        self.worker().restore_once()
        put(self.live, "edgeconf.json", b'new drift\n')
        with self.assertRaisesRegex(qa.RestoreBlocked, "final stage drift"):
            self.worker().restore_once()

    def test_bad_led_original_blocks_restoration(self):
        corrupted = b'{"leds":[false,true,false,false]}\n'
        put(self.base, "led_state.json", corrupted)
        self.record["baseline"]["led_state.json"] = {"sha256": qa.sha(corrupted), "size": len(corrupted)}
        self.save_record()
        with self.assertRaisesRegex(qa.RestoreBlocked, "LED-off baseline"):
            self.worker().restore_once()

    def test_root_symlink_is_refused(self):
        alias = Path(self.tmp.name) / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(qa.RestoreBlocked):
            qa.OfflineRestoreWorker(alias)

    def test_concurrent_owner_lock_is_refused(self):
        fd = os.open(self.root / ".restore-worker.lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            with self.assertRaisesRegex(qa.RestoreBlocked, "already active"):
                self.worker().restore_once()
        finally:
            os.close(fd)

    def test_session_not_armed_by_boolean_only_evidence(self):
        good = {
            "lease_holder": "holder-1", "lease_generation": 7,
            "boot_id": "boot-42", "owner_invocation": "owner-1",
            "installed_source_sha": "a" * 40,
            "writer_eos": True, "writer_fsync": True, "finalizer_closed": True,
            "writable_fd_count": 0, "restart_inhibited": True,
            "writer_cannot_reopen": True, "lease_current": True,
        }
        verdict = qa.assess_writer_fence(good)
        self.assertEqual(verdict["decision"], "REVIEW_REQUIRED")
        self.assertIsNone(verdict["writer_fence_session"])
        self.assertFalse(verdict["hardware_execution_authorized"])
        good["writable_fd_count"] = 1
        self.assertIn("WRITER_FD_NOT_CLOSED", qa.assess_writer_fence(good)["reason_codes"])
        good["writable_fd_count"] = 0
        good["lease_current"] = False
        self.assertEqual(qa.assess_writer_fence(good)["decision"], "BLOCK")
        good["lease_current"] = True
        good["lease_generation"] = True
        self.assertEqual(qa.assess_writer_fence(good)["decision"], "BLOCK")

    def test_marker_has_strict_integrity_fields(self):
        self.record["phase"] = "UNFENCED"
        self.save_record()
        with self.assertRaises(qa.RestoreBlocked):
            self.worker().restore_once()


if __name__ == "__main__":
    unittest.main()
