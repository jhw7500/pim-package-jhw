"""Scratch-only regression for the exact RAM-to-SD finalizer backlog function.

No PIM board, installed SD, live recorder, or global /tmp is accessed.
The runtime MovePartFile fixes must also cover BackfillRamRecordingsToSd.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
PRODUCT = ROOT / "dist/pim/opt/pim/bin/chk_cam_operate.sh"


class RamBackfillNoReplaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = PRODUCT.read_text(encoding="utf-8")
        a = text.index("BackfillRamRecordingsToSd() {")
        b = text.index("\n}\n\n# Final-path telemetry", a) + 2
        cls.function = text[a:b]
        cls.build = tempfile.TemporaryDirectory(prefix="backfill-native-helper-")
        cls.publisher = Path(cls.build.name) / "finalizer_noreplace"
        cc = subprocess.run(
            ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-o", str(cls.publisher),
             str(ROOT / "tools/finalizer_noreplace.c")],
            capture_output=True, text=True, check=False, timeout=30,
        )
        if cc.returncode:
            raise AssertionError("native publisher compilation: " + cc.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="backfill-isolated-")
        self.root = Path(self.tmp.name)
        self.ram = self.root / "ram"
        self.sd = self.root / "sd"
        self.ram.mkdir()
        self.sd.mkdir()
        self.basename = "VD3001_20261029_205000-ch0.mp4"
        self.heartbeat = self.root / "heartbeat"
        self.now = int(time.time())

    def tearDown(self):
        self.tmp.cleanup()

    def source(self, payload=b"RAMPAYLOAD"):
        part = self.ram / self.basename
        part.write_bytes(payload)
        os.utime(part, (self.now - 3600, self.now - 3600))
        return part

    def execute(self, **extras):
        env = os.environ.copy()
        env.update({
            "RAM_ONLY_FINAL_PATH": str(self.ram),
            "final_path_cfg": str(self.sd),
            "FINAL_HEARTBEAT_FILE": str(self.heartbeat),
            "FINALIZER_NOREPLACE_TOOL": str(self.publisher),
            "KEY": "OFFLINE",
            "tag": "backfill-test",
            "TEST_TIMESTAMP": str(self.now),
            "TEST_SYNC_FAILURE": "",
        })
        env.update(extras)
        script = (
            'logger() { :; }\n'
            'sync() {\n'
            '  local last="${@: -1}"\n'
            '  if [ "${TEST_SYNC_FAILURE:-}" = stage_temp ] &&\n'
            '     [[ "$last" == "$final_path_cfg/.finalizer-backfill."*/* ]]; then\n'
            '    return 93\n'
            '  fi\n'
            '  if [ "${TEST_SYNC_FAILURE:-}" = final_dir ] &&\n'
            '     [ "$last" = "$final_path_cfg" ]; then\n'
            '    return 93\n'
            '  fi\n'
            '  return 0\n'
            '}\n'
            'date() { if [ "$1" = "+%s" ]; then '
            'printf "%s\\n" "$TEST_TIMESTAMP"; else command date "$@"; fi; }\n'
            + self.function + "\nBackfillRamRecordingsToSd\n"
        )
        return subprocess.run(
            ["bash", "-c", script], env=env, capture_output=True,
            text=True, timeout=12, check=False,
        )

    def test_equal_size_different_bytes_must_never_delete_ram_original(self):
        src = self.source(b"RAM-KEEP")
        final = self.sd / self.basename
        final.write_bytes(b"SD--KEEP")
        result = self.execute()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(src.read_bytes(), b"RAM-KEEP")
        self.assertEqual(final.read_bytes(), b"SD--KEEP")
        self.assertFalse(self.heartbeat.exists())

    def test_identical_dest_must_not_implicitly_prove_closed_writer_fd(self):
        src = self.source(b"SAME-UNTIL-WRITER-APPENDS")
        final = self.sd / self.basename
        final.write_bytes(src.read_bytes())
        result = self.execute()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertTrue(src.exists())
        self.assertEqual(src.read_bytes(), final.read_bytes())
        self.assertFalse(self.heartbeat.exists())

    def test_existing_ramdup_and_original_final_never_clobbered(self):
        src = self.source(b"DIFFERENT-RAM-SOURCE")
        final = self.sd / self.basename
        final.write_bytes(b"OLD-FINAL")
        old_dup = self.sd / f"{self.basename}.ramdup.{self.now}"
        old_dup.write_bytes(b"PRIOR-RAMDUP")
        result = self.execute()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(src.read_bytes(), b"DIFFERENT-RAM-SOURCE")
        self.assertEqual(final.read_bytes(), b"OLD-FINAL")
        self.assertEqual(old_dup.read_bytes(), b"PRIOR-RAMDUP")

    def test_no_collision_backfills_exact_bytes_and_cleans_ram(self):
        src = self.source(b"NEW-RAM-RECORDING")
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(src.exists())
        self.assertEqual((self.sd / self.basename).read_bytes(),
                         b"NEW-RAM-RECORDING")
        self.assertTrue(self.heartbeat.exists())

    def test_ram_tmpfs_to_sd_filesystem_uses_copy_before_noreplace(self):
        shared = Path("/dev/shm")
        if not shared.is_dir() or not os.access(shared, os.W_OK):
            self.skipTest("isolated tmpfs fixture not available")
        if shared.stat().st_dev == self.sd.stat().st_dev:
            self.skipTest("no distinct RAM and target filesystem")
        with tempfile.TemporaryDirectory(
            prefix="backfill-crossdev-", dir=shared
        ) as dirname:
            old_ram = self.ram
            self.ram = Path(dirname)
            try:
                src = self.source(b"CROSS-DEVICE-RAM-FRAGMENT")
                self.assertNotEqual(src.stat().st_dev, self.sd.stat().st_dev)
                result = self.execute()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(src.exists())
                self.assertEqual(
                    (self.sd / self.basename).read_bytes(),
                    b"CROSS-DEVICE-RAM-FRAGMENT",
                )
            finally:
                self.ram = old_ram

    def test_backfill_stage_file_sync_failure_keeps_ram_source(self):
        src = self.source(b"RAM-UNSYNCED-COPY")
        result = self.execute(TEST_SYNC_FAILURE="stage_temp")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(src.read_bytes(), b"RAM-UNSYNCED-COPY")
        self.assertFalse((self.sd / self.basename).exists())
        self.assertFalse(self.heartbeat.exists())

    def test_backfill_final_directory_sync_failure_keeps_ram_source(self):
        src = self.source(b"SD-DIRECTORY-NOT-SYNCED")
        result = self.execute(TEST_SYNC_FAILURE="final_dir")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(src.read_bytes(), b"SD-DIRECTORY-NOT-SYNCED")
        self.assertEqual(
            (self.sd / self.basename).read_bytes(),
            b"SD-DIRECTORY-NOT-SYNCED",
        )
        self.assertFalse(self.heartbeat.exists())

    def test_destination_symlink_is_not_followed_or_replaced(self):
        src = self.source(b"DO-NOT-REPLACE")
        target = self.root / "external-sentinel"
        target.write_bytes(b"KEEP-EXTERNAL")
        link = self.sd / self.basename
        link.symlink_to(target)
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(src.read_bytes(), b"DO-NOT-REPLACE")
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_bytes(), b"KEEP-EXTERNAL")


if __name__ == "__main__":
    unittest.main()
