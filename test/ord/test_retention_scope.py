"""Native ORD retention scope regression on temporary files only; never runs on a board."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ord" / "recording_retention.cpp"
RUNNER = r'''
#include "recording_retention.h"
#include <cstdio>
#include <string>
int main(int argc, char **argv) {
    if (argc != 6) return 80;
    const std::string mode = argv[1];
    int n = -1;
    if (mode == "rotate") n = ord_retention::rotate_oldest(argv[2], argv[3], argv[4], argv[5]);
    if (mode == "recycle") n = ord_retention::prune_recycle(argv[3], argv[4], argv[5]);
    if (mode == "root") n = ord_retention::prune_recording(argv[2], argv[4], argv[5]);
    if (mode == "event") n = ord_retention::prune_event(argv[3], argv[4], argv[5]);
    printf("%d\n", n);
    return n >= 0 ? 0 : 1;
}
'''


class RecordingRetentionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("g++"):
            raise unittest.SkipTest("g++ unavailable")
        cls.program_dir = tempfile.TemporaryDirectory(prefix="ord-retention-bin-")
        main = Path(cls.program_dir.name) / "main.cpp"
        main.write_text(RUNNER)
        cls.executable = Path(cls.program_dir.name) / "scope-test"
        subprocess.run([
            "g++", "-std=c++11", "-Wall", "-Wextra", "-Werror", "-I",
            str(SOURCE.parent), str(SOURCE), str(main), "-o",
            str(cls.executable)
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.program_dir.cleanup()

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="ord-retention-data-")
        self.rec = Path(self.work.name) / "recordings"
        self.recycle = Path(self.work.name) / "recycle"
        self.event = Path(self.work.name) / "event"
        for d in (self.rec, self.recycle, self.event):
            d.mkdir()
        self.old = time.time() - 1200

    def tearDown(self):
        self.work.cleanup()

    def make_file(self, directory, name, old=True):
        path = directory / name
        path.write_bytes(name.encode())
        if old:
            os.utime(path, (self.old, self.old))
        return path

    def execute(self, action, root=None, target=None, vhl="VD3001", muxer="mp4"):
        result = subprocess.run([
            str(self.executable), action,
            str(root or self.rec), str(target or self.recycle), vhl, muxer
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return int(result.stdout.strip())

    def test_old_recording_moves_but_config_recent_partial_and_links_remain(self):
        old = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        sub = self.make_file(self.rec, "VD3001_20261020_130000-data.srt")
        misc = self.make_file(self.rec, "important.config")
        other = self.make_file(self.rec, "OTHER1_20261020_130001-ch1.mp4")
        part = self.make_file(self.rec, "VD3001_20261020_130001-ch1.mp4.part")
        fresh = self.make_file(self.rec, "VD3001_20261029_123000-ch1.mp4", old=False)
        external = self.make_file(Path(self.work.name), "secret.cfg")
        link = self.rec / "VD3001_20261020_130001-ch3.mp4"
        link.symlink_to(external)
        self.assertEqual(self.execute("rotate"), 2)
        self.assertFalse(old.exists())
        self.assertTrue((self.recycle / "20261020_13" / old.name).exists())
        self.assertTrue((self.recycle / "20261020_13" / sub.name).exists())
        for path in (misc, other, part, fresh, external):
            self.assertTrue(path.exists())
        self.assertTrue(link.is_symlink())

    def test_recycle_cleanup_preserves_unrecognized_file_and_external_symlink(self):
        directory = self.recycle / "20261020_13"
        directory.mkdir()
        video = self.make_file(directory, "VD3001_20261020_130001-ch0.mp4")
        config = self.make_file(directory, "readme.config")
        external = self.make_file(Path(self.work.name), "external.db")
        (directory / "VD3001_20261020_130001-ch1.mp4").symlink_to(external)
        self.assertEqual(self.execute("recycle"), 1)
        self.assertFalse(video.exists())
        self.assertTrue(config.exists())
        self.assertTrue(external.exists())
        self.assertTrue(directory.exists())

    def test_recording_root_fallback_never_removes_other_files(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        srt = self.make_file(self.rec, "VD3001_20261020_130000-data.srt")
        newer = self.make_file(self.rec, "VD3001_20261020_131001-ch1.mp4")
        config = self.make_file(self.rec, "machine.settings")
        self.assertEqual(self.execute("root"), 2)
        self.assertFalse(video.exists())
        self.assertFalse(srt.exists())
        self.assertTrue(config.exists())
        self.assertTrue(newer.exists())

    def test_event_cleanup_skips_unknown_content_and_partial_files(self):
        video = self.make_file(self.event, "evt_VD3001_20261020_130001-ch0.mp4")
        srt = self.make_file(self.event, "evt_VD3001_20261020_130000-data.srt")
        other = self.make_file(self.event, "deploy.conf")
        partial = self.make_file(self.event, "evt_VD3001_20261020_130001-ch2.mp4.part")
        foreign = self.make_file(self.event, "evt_OTHER1_20261020_130001-ch2.mp4")
        self.assertEqual(self.execute("event", target=self.event), 2)
        for path in (other, partial, foreign):
            self.assertTrue(path.exists())
        self.assertFalse(video.exists())
        self.assertFalse(srt.exists())

    def test_invalid_device_or_muxer_never_approved(self):
        self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        for device, muxer in [
            ("../escape", "mp4"), ("VD3001", "../mp4"),
            ("VD3001", "bad"), ("VD3001;rm", "mp4")
        ]:
            result = subprocess.run([
                str(self.executable), "root", str(self.rec), str(self.recycle),
                device, muxer
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(list(self.rec.iterdir())), 1)


if __name__ == "__main__":
    unittest.main()
