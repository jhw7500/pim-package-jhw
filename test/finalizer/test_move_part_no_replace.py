"""Exercise actual Finalizer MovePartFile with isolated scratch paths.

Unlike the session-marker tests, this harness extracts the real MovePartFile
function and NEVER replaces it with a mock. File operations are confined to
TemporaryDirectory. No target, recorder, SD, service, or global /tmp marker is
accessed; logger/sync are stubbed and the storage policy is frozen to scratch.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
FINALIZER = ROOT / "dist/pim/opt/pim/bin/chk_cam_operate.sh"


class MovePartNoReplaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = FINALIZER.read_text(encoding="utf-8")
        start = script.index("MovePartFile() {")
        end = script.index("\n}\n\nis_sd_ok() {", start) + 2
        cls.move_function = script[start:end]
        cls.compile_dir = tempfile.TemporaryDirectory(
            prefix="finalizer-test-native-publisher-"
        )
        cls.publisher = Path(cls.compile_dir.name) / "finalizer_noreplace"
        source = ROOT / "tools/finalizer_noreplace.c"
        compile_result = subprocess.run(
            [
                "cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                "-o", str(cls.publisher), str(source),
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if compile_result.returncode:
            raise RuntimeError(
                "failed compiling actual no-replace publisher: "
                + compile_result.stderr
            )
        assert cls.publisher.is_file()

        start = script.index("ProcessCompletedSessions() {")
        end = script.index("\n}\n\n# Stale .part", start) + 2
        original_glob = "for done_file in /tmp/session_*.all_done; do"
        part = script[start:end]
        if part.count(original_glob) != 1:
            raise AssertionError("marker path contract unexpectedly changed")
        cls.marker_function = part.replace(
            original_glob,
            'for done_file in "$TEST_MARKER_DIR"/session_*.all_done; do',
        )

    @classmethod
    def tearDownClass(cls):
        cls.compile_dir.cleanup()

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="finalizer-noreplace-")
        self.root = Path(self.scratch.name)
        for name in ("ramtmp", "sdtmp", "final", "markers", "stageA", "stageB"):
            (self.root / name).mkdir()
        self.ram = self.root / "ramtmp"
        self.sdtmp = self.root / "sdtmp"
        self.final = self.root / "final"
        self.minute = time.strftime("%Y%m%d_%H%M", time.localtime(time.time() - 86400))
        self.basename = f"VD3001_{self.minute}00-ch0.mp4"
        self.source_name = self.basename + ".part"
        self.marker = self.root / "markers" / f"session_{self.minute}.all_done"
        self.refuse_tool = self.root / "publisher-fails"
        self.refuse_tool.write_text("#!/bin/sh\nexit 80\n", encoding="utf-8")
        self.refuse_tool.chmod(0o700)

    def tearDown(self):
        self.scratch.cleanup()

    def env(self, **extra):
        result = os.environ.copy()
        result.update({
            "tmp_path": str(self.ram),
            "sd_tmp_path": str(self.sdtmp),
            "final_path": str(self.final),
            "final_path_cfg": str(self.final),
            "sd_tmp_path_cfg": str(self.sdtmp),
            "FINAL_HEARTBEAT_FILE": str(self.root / "heartbeat"),
            "TEST_MARKER_DIR": str(self.root / "markers"),
            "KEY": "OFFLINE_ONLY",
            "tag": "offline-test",
            "muxer": "mp4",
            "vhl_name": "VD3001",
            "cam_ch0": "true",
            "cam_ch1": "false",
            "cam_ch2": "false",
            "cam_ch3": "false",
            "srt_en": "false",
            "TEST_FAIL_UNLINK": "false",
            "TEST_FORCE_LINK_FAILURE": "false",
            "TEST_FORCE_COPY_FAILURE": "false",
            "TEST_FORCE_UMASK": "false",
            "TEST_SYNC_FAILURE": "",
            "TEST_FINAL_NAME": self.basename,
            "FINALIZER_NOREPLACE_TOOL": str(self.publisher),
        })
        result.update(extra)
        return result

    def shell(self, *, session=False):
        # All file paths are supplied via the tempfile-only environment.
        # No source /tmp glob or hardware configuration can be reached.
        lines = [
            "logger() { :; }",
            'sync() {',
            '  local last="${@: -1}"',
            '  case "${TEST_SYNC_FAILURE:-}" in',
            '    stage1_temp)',
            '      [[ "$last" == "$sd_tmp_path/.finalizer-stage1."*/* ]] && return 91 ;;',
            '    stage1_dir)',
            '      [ "$last" = "$sd_tmp_path" ] && return 91 ;;',
            '    stage2_final)',
            '      [ "$last" = "$final_path/$TEST_FINAL_NAME" ] && return 91 ;;',
            '    stage2_dir)',
            '      [ "$last" = "$final_path" ] && return 91 ;;',
            '  esac',
            '  if [ "$#" -eq 0 ] && [ -n "${TEST_SYNC_FAILURE:-}" ]; then',
            '    return 91',
            '  fi',
            '  return 0',
            '}',
            "apply_storage_mode_overrides() { :; }",
            'if [ "$TEST_FORCE_UMASK" = true ]; then umask 077; fi',
            self.move_function,
            self.marker_function,
            'if [ "$TEST_FORCE_COPY_FAILURE" = true ]; then',
            '  cp() {',
            '    local last',
            '    last="${@: -1}"',
            '    printf "INTERRUPTED-COPY" > "$last"',
            '    return 84',
            '  }',
            "fi",
            'if [ "$TEST_FAIL_UNLINK" = true ]; then',
            '  rm() {',
            '    if [ "$1" = "--" ] && [ "$2" = "$TEST_SOURCE" ]; then return 81; fi',
            '    command rm "$@"',
            "  }",
            "fi",
            'if [ "$TEST_RUN_SESSION" = true ]; then',
            "  ProcessCompletedSessions",
            "else",
            '  MovePartFile "$TEST_SOURCE"',
            "fi",
        ]
        return "\n".join(lines) + "\n"

    def execute(self, path, *, session=False, **extra):
        if extra.pop("TEST_FORCE_LINK_FAILURE", "false") == "true":
            extra["FINALIZER_NOREPLACE_TOOL"] = str(self.refuse_tool)
        return subprocess.run(
            ["bash", "-c", self.shell(session=session)],
            env=self.env(
                TEST_SOURCE=str(path),
                TEST_RUN_SESSION="true" if session else "false",
                **extra,
            ),
            capture_output=True,
            text=True,
            timeout=12,
            check=False,
        )

    def test_failed_stage_one_file_sync_preserves_ram_input(self):
        part = self.ram / self.source_name
        part.write_bytes(b"STAGE1-DATA-NOT-DURABLE")
        result = self.execute(part, TEST_SYNC_FAILURE="stage1_temp")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"STAGE1-DATA-NOT-DURABLE")
        self.assertFalse((self.final / self.basename).exists())
        self.assertFalse((self.sdtmp / self.source_name).exists())
        self.assertFalse((self.root / "heartbeat").exists())

    def test_failed_stage_one_dir_sync_retains_original_for_recovery(self):
        part = self.ram / self.source_name
        part.write_bytes(b"STAGE1-DIRECTORY-NOT-SYNCED")
        result = self.execute(part, TEST_SYNC_FAILURE="stage1_dir")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"STAGE1-DIRECTORY-NOT-SYNCED")
        self.assertFalse((self.final / self.basename).exists())
        self.assertFalse((self.root / "heartbeat").exists())

    def test_failed_stage_two_sync_retains_marker_and_no_heartbeat(self):
        part = self.sdtmp / self.source_name
        part.write_bytes(b"FINAL-RENAME-WITH-FAILED-SYNC")
        self.marker.write_text(self.minute + "\n", encoding="utf-8")
        result = self.execute(
            part, session=True, TEST_SYNC_FAILURE="stage2_final"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertFalse((self.root / "heartbeat").exists())
        self.assertEqual(
            (self.final / self.basename).read_bytes(),
            b"FINAL-RENAME-WITH-FAILED-SYNC",
        )

    def test_missing_publisher_is_a_hard_stop(self):
        part = self.sdtmp / self.source_name
        part.write_bytes(b"NO-INSTALLED-HELPER")
        result = self.execute(
            part, FINALIZER_NOREPLACE_TOOL=str(self.root / "not-installed")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"NO-INSTALLED-HELPER")
        self.assertFalse((self.final / self.basename).exists())

    def test_publisher_symlink_is_not_trusted(self):
        part = self.sdtmp / self.source_name
        part.write_bytes(b"HELPER-SYMLINK-REJECT")
        untrusted = self.root / "fake-helper-link"
        untrusted.symlink_to(self.publisher)
        result = self.execute(part, FINALIZER_NOREPLACE_TOOL=str(untrusted))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"HELPER-SYMLINK-REJECT")
        self.assertFalse((self.final / self.basename).exists())

    def test_native_publisher_rejects_non_absolute_arguments(self):
        part = self.sdtmp / self.source_name
        part.write_bytes(b"INPUT-UNCHANGED")
        result = subprocess.run(
            [str(self.publisher), str(part), "relative-name.mp4"],
            capture_output=True, text=True, timeout=10, check=False,
            cwd=self.root,
        )
        self.assertEqual(result.returncode, 64)
        self.assertEqual(part.read_bytes(), b"INPUT-UNCHANGED")
        self.assertFalse((self.final / self.basename).exists())

    def test_native_publisher_returns_collision_status_for_existing_final(self):
        part = self.sdtmp / self.source_name
        dest = self.final / self.basename
        part.write_bytes(b"NEW-FILE")
        dest.write_bytes(b"OLD-FILE")
        result = subprocess.run(
            [str(self.publisher), str(part), str(dest)],
            capture_output=True, text=True, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 73)
        self.assertEqual(part.read_bytes(), b"NEW-FILE")
        self.assertEqual(dest.read_bytes(), b"OLD-FILE")

    def test_existing_final_video_is_never_overwritten(self):
        part = self.sdtmp / self.source_name
        final = self.final / self.basename
        part.write_bytes(b"NEW-VIDEO-DO-NOT-PUBLISH")
        final.write_bytes(b"IRREPLACEABLE-OLD-VIDEO")
        result = self.execute(part)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(final.read_bytes(), b"IRREPLACEABLE-OLD-VIDEO")
        self.assertEqual(part.read_bytes(), b"NEW-VIDEO-DO-NOT-PUBLISH")

    def test_existing_final_srt_is_never_overwritten(self):
        name = f"VD3001_{self.minute}00-data.srt"
        part = self.sdtmp / (name + ".part")
        final = self.final / name
        part.write_bytes(b"new-srt-cue")
        final.write_bytes(b"important-original-srt")
        result = self.execute(part)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(final.read_bytes(), b"important-original-srt")
        self.assertEqual(part.read_bytes(), b"new-srt-cue")

    def test_existing_stage_one_file_and_ram_source_survive_collision(self):
        part = self.ram / self.source_name
        stage = self.sdtmp / self.source_name
        part.write_bytes(b"NEW-RAM-BYTES")
        stage.write_bytes(b"PRIOR-STAGED-BYTES")
        result = self.execute(part)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(part.read_bytes(), b"NEW-RAM-BYTES")
        self.assertEqual(stage.read_bytes(), b"PRIOR-STAGED-BYTES")
        self.assertFalse((self.final / self.basename).exists())

    def test_new_stage_two_part_finalizes_once_and_removes_source(self):
        part = self.sdtmp / self.source_name
        part.write_bytes(b"RECORDED-FRAGMENT")
        result = self.execute(part)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(part.exists())
        self.assertEqual(
            (self.final / self.basename).read_bytes(), b"RECORDED-FRAGMENT"
        )
        self.assertTrue((self.root / "heartbeat").exists())

    def test_ram_to_sd_stage_preserves_source_read_permissions(self):
        # mktemp -f created an existing 0600 file and lost the original 0644
        # recording permissions on ext4. The private directory + fresh copy
        # must preserve all ordinary source read modes, even under umask 077.
        part = self.ram / self.source_name
        output = self.final / self.basename
        for mode in (0o644, 0o640, 0o600):
            with self.subTest(source_mode=oct(mode)):
                part.write_bytes(b"RECORDER-EXPECTED-READ-MODE")
                part.chmod(mode)
                result = self.execute(part, TEST_FORCE_UMASK="true")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    output.read_bytes(), b"RECORDER-EXPECTED-READ-MODE"
                )
                self.assertEqual(output.stat().st_mode & 0o777, mode)
                output.unlink()  # scratch output only

    def test_ram_to_sd_copy_preserves_recording_mtime_without_unix_owner(self):
        part = self.ram / self.source_name
        part.write_bytes(b"OLD-RECORDING-MTIME")
        recording_epoch = int(time.time()) - 3600
        os.utime(part, (recording_epoch, recording_epoch))
        result = self.execute(part)
        self.assertEqual(result.returncode, 0, result.stderr)
        dest = self.final / self.basename
        self.assertEqual(dest.read_bytes(), b"OLD-RECORDING-MTIME")
        self.assertLessEqual(abs(dest.stat().st_mtime - recording_epoch), 2.0)
        self.assertFalse(part.exists())

    def test_ram_to_sd_two_stage_publish_finishes_without_temp_leak(self):
        part = self.ram / self.source_name
        part.write_bytes(b"RAM-FRAGMENT")
        result = self.execute(part)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(part.exists())
        self.assertFalse((self.sdtmp / self.source_name).exists())
        self.assertEqual((self.final / self.basename).read_bytes(), b"RAM-FRAGMENT")
        self.assertFalse(list(self.sdtmp.glob(".finalizer-stage1.*")))

    def test_actual_session_marker_is_kept_when_final_collision_occurs(self):
        part = self.sdtmp / self.source_name
        final = self.final / self.basename
        part.write_bytes(b"NEW-DIFFERENT-FILE")
        final.write_bytes(b"KEEP-PRIOR-FINAL")
        self.marker.write_text(self.minute + "\n")
        result = self.execute(part, session=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertEqual(final.read_bytes(), b"KEEP-PRIOR-FINAL")
        self.assertEqual(part.read_bytes(), b"NEW-DIFFERENT-FILE")

    def test_link_failure_preserves_source_and_no_final(self):
        part = self.sdtmp / self.source_name
        part.write_bytes(b"PRESERVE-ON-FAILED-PUBLISH")
        result = self.execute(part, TEST_FORCE_LINK_FAILURE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"PRESERVE-ON-FAILED-PUBLISH")
        self.assertFalse((self.final / self.basename).exists())

    def test_interruption_after_stage_rename_before_ram_unlink_is_non_success(self):
        # Stage 1 renames the completed copy into sdtmp atomically; failing
        # RAM unlink must leave BOTH original and stage for manual recovery.
        part = self.ram / self.source_name
        part.write_bytes(b"POST-STAGE-RENAME-FAILURE")
        result = self.execute(part, TEST_FAIL_UNLINK="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"POST-STAGE-RENAME-FAILURE")
        staged = self.sdtmp / self.source_name
        self.assertEqual(staged.read_bytes(), b"POST-STAGE-RENAME-FAILURE")
        self.assertFalse((self.final / self.basename).exists())

    def test_destination_symlink_is_not_followed_or_replaced(self):
        part = self.sdtmp / self.source_name
        part.write_bytes(b"DO-NOT-WRITE-THROUGH-SYMLINK")
        sentinel = self.root / "sentinel"
        sentinel.write_bytes(b"KEEP-SENTINEL")
        final = self.final / self.basename
        final.symlink_to(sentinel)
        result = self.execute(part)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(final.is_symlink())
        self.assertEqual(sentinel.read_bytes(), b"KEEP-SENTINEL")
        self.assertTrue(part.exists())

    def test_source_symlink_is_not_published(self):
        payload = self.root / "outside-source"
        payload.write_bytes(b"NOT-A-RECORDER-PART")
        part = self.sdtmp / self.source_name
        part.symlink_to(payload)
        result = self.execute(part)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(part.is_symlink())
        self.assertFalse((self.final / self.basename).exists())

    def test_concurrent_colliding_publishes_have_exactly_one_winner(self):
        for n in range(8):
            part_a = self.root / "stageA" / self.source_name
            part_b = self.root / "stageB" / self.source_name
            payload_a = f"NEW-A-{n}".encode()
            payload_b = f"NEW-B-{n}".encode()
            part_a.write_bytes(payload_a)
            part_b.write_bytes(payload_b)
            dest = self.final / self.basename
            if dest.exists():
                dest.unlink()  # scratch fixture only, not a recording
            script = self.shell()
            jobs = [
                subprocess.Popen(
                    ["bash", "-c", script],
                    env=self.env(TEST_SOURCE=str(part), TEST_RUN_SESSION="false"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for part in (part_a, part_b)
            ]
            codes = []
            for job in jobs:
                _, stderr = job.communicate(timeout=12)
                codes.append((job.returncode, stderr))
            self.assertEqual(sum(code == 0 for code, _ in codes), 1, codes)
            self.assertIn(dest.read_bytes(), (payload_a, payload_b))
            loser = part_a if codes[0][0] != 0 else part_b
            self.assertTrue(loser.exists(), codes)
            self.assertIn(loser.read_bytes(), (payload_a, payload_b))

    def test_partial_stage_one_copy_does_not_replace_or_leave_a_partial_stage(self):
        part = self.ram / self.source_name
        part.write_bytes(b"COMPLETE-RAM-SOURCE")
        result = self.execute(part, TEST_FORCE_COPY_FAILURE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"COMPLETE-RAM-SOURCE")
        self.assertFalse((self.sdtmp / self.source_name).exists())
        self.assertFalse((self.final / self.basename).exists())
        self.assertFalse(list(self.sdtmp.glob(".finalizer-stage1.*")))

    def test_failed_stage_one_hardlink_keeps_ram_source(self):
        part = self.ram / self.source_name
        part.write_bytes(b"RAM-FRAGMENT-BEFORE-CLAIM")
        result = self.execute(part, TEST_FORCE_LINK_FAILURE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(part.read_bytes(), b"RAM-FRAGMENT-BEFORE-CLAIM")
        self.assertFalse((self.sdtmp / self.source_name).exists())
        self.assertFalse((self.final / self.basename).exists())
        self.assertFalse(list(self.sdtmp.glob(".finalizer-stage1.*")))

    def test_post_rename_pre_marker_crash_keeps_final_and_marker_pending(self):
        # A successful atomic rename may complete before marker cleanup.
        # On restart there is no .part to move: retain marker for review.
        part = self.sdtmp / self.source_name
        final = self.final / self.basename
        part.write_bytes(b"POST-RENAME-FINAL-BYTES")
        os.rename(part, final)  # isolated fixture recreating crash boundary
        self.assertFalse(part.exists())
        self.marker.write_text(self.minute + "\n", encoding="utf-8")
        result = self.execute(part, session=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertEqual(final.read_bytes(), b"POST-RENAME-FINAL-BYTES")
        self.assertFalse((self.root / "heartbeat").exists())

    def test_cross_filesystem_publish_is_fail_closed(self):
        shared = Path("/dev/shm")
        if not shared.is_dir() or not os.access(shared, os.W_OK):
            self.skipTest("No isolated shared-memory filesystem")
        if shared.stat().st_dev == self.final.stat().st_dev:
            self.skipTest("No differing mounted filesystems")
        with tempfile.TemporaryDirectory(prefix="finalizer-crossfs-", dir=shared) as tmp:
            part = Path(tmp) / self.source_name
            part.write_bytes(b"CROSS-FS-SOURCE")
            result = self.execute(part)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(part.read_bytes(), b"CROSS-FS-SOURCE")
            self.assertFalse((self.final / self.basename).exists())


if __name__ == "__main__":
    unittest.main()
