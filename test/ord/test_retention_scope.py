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
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cstdarg>
#include <sys/syscall.h>
// Test-only deterministic concurrent writer, injected at the second
// fstatat of the chosen recording to exercise the pre-delete recheck.
extern "C" int __real_fstatat(int, const char *, struct stat *, int);
extern "C" int __wrap_fstatat(int fd, const char *name, struct stat *st, int flags) {
    const char *target = std::getenv("ORD_TEST_MUTATE_NAME");
    static int seen = 0;
    if (target && std::strcmp(target, name) == 0 && ++seen == 2) {
        int out = openat(fd, name, O_WRONLY | O_APPEND | O_NOFOLLOW);
        if (out >= 0) {
            (void)write(out, "-changed-after-scan", 19);
            const time_t old = std::time(NULL) - 720;
            struct timespec dates[2] = {{old, 0}, {old, 0}};
            (void)futimens(out, dates);
            (void)close(out);
        }
    }
    return __real_fstatat(fd, name, st, flags);
}
extern "C" long __real_syscall(long, ...);
extern "C" long __wrap_syscall(long number, ...) {
    va_list ap;
    va_start(ap, number);
    const int src_fd = va_arg(ap, int);
    const char *src = va_arg(ap, const char *);
    const int dst_fd = va_arg(ap, int);
    const char *dst = va_arg(ap, const char *);
    const int flags = va_arg(ap, int);
    va_end(ap);
    const char *target = std::getenv("ORD_TEST_SWAP_BEFORE_MOVE");
    static bool swapped = false;
    if (number == SYS_renameat2 && target && !swapped
        && std::strcmp(target, src) == 0) {
        swapped = true;
        if (renameat(src_fd, src, src_fd, "held-original.mp4") != 0) return -1;
        int fd = openat(src_fd, src, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) return -1;
        const char wrong[] = "IMPORTANT_NOT_RECORDING";
        (void)write(fd, wrong, sizeof(wrong)-1);
        (void)close(fd);
    }
    return __real_syscall(number, src_fd, src, dst_fd, dst, flags);
}
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
            str(SOURCE.parent), str(SOURCE), str(main), "-Wl,--wrap=fstatat", "-Wl,--wrap=syscall", "-o",
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

    def test_rotation_collision_preserves_source_and_existing_destination(self):
        old = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        hour = self.recycle / "20261020_13"
        hour.mkdir()
        collision = self.make_file(hour, old.name)
        collision.write_bytes(b"existing separate recording")
        result = subprocess.run([
            str(self.executable), "rotate", str(self.rec),
            str(self.recycle), "VD3001", "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(old.exists())
        self.assertEqual(collision.read_bytes(), b"existing separate recording")

    def test_invalid_calendar_days_are_not_recordings(self):
        names = [
            "VD3001_20260230_130001-ch0.mp4",
            "VD3001_20260431_130001-ch1.mp4",
            "VD3001_20261020_246000-ch2.mp4",
            "VD3001_20261020_126100-ch3.mp4",
        ]
        paths = [self.make_file(self.rec, name) for name in names]
        self.assertEqual(self.execute("root"), 0)
        self.assertTrue(all(path.exists() for path in paths))

    def test_exactly_32_files_may_be_removed_per_pass(self):
        for second in range(40):
            self.make_file(self.rec, f"VD3001_20261020_1300{second:02d}-ch0.mp4")
        self.assertEqual(self.execute("root"), 32)
        self.assertEqual(len(list(self.rec.iterdir())), 8)

    def test_directory_named_as_video_is_not_removed(self):
        name = "VD3001_20261020_130001-ch0.mp4"
        (self.rec / name).mkdir()
        self.assertEqual(self.execute("root"), 0)
        self.assertTrue((self.rec / name).is_dir())

    def test_symlinked_root_and_recycle_directory_are_rejected(self):
        root_link = Path(self.work.name) / "root-link"
        root_link.symlink_to(self.rec, target_is_directory=True)
        result = subprocess.run([
            str(self.executable), "root", str(root_link),
            str(self.recycle), "VD3001", "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        recycle_link = Path(self.work.name) / "recycle-link"
        recycle_link.symlink_to(self.recycle, target_is_directory=True)
        result = subprocess.run([
            str(self.executable), "recycle", str(self.rec),
            str(recycle_link), "VD3001", "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_copy_generated_rms_event_files_are_pruned_but_invalid_formats_survive(self):
        # tcpServer.cpp formats COPY suffix with "_rmsMax_%0.1f".
        names = [
            "evt_VD3001_20261020_130000_rmsMax_12.4-ch0.mp4",
            "evt_VD3001_20261020_130000_rmsMax_-1.0-data.srt",
            "evt_VD3001_20261020_130000_rmsMax_0.0-vib.bin",
        ]
        allowed = [self.make_file(self.event, name) for name in names]
        rejected = [
            self.make_file(self.event, name)
            for name in [
                "evt_VD3001_20261020_130000_rmsMax_nan-ch1.mp4",
                "evt_VD3001_20261020_130000_rmsMax_3.14-ch1.mp4",
                "evt_VD3001_20261020_130000_rmsMax_1e6-ch1.mp4",
                "evt_VD3001_20261020_130000_rmsMax_123456789012.3-ch1.mp4",
                "evt_VD3001_20261020_130000_rmsMax_-Inf-ch1.mp4",
            ]
        ]
        self.assertEqual(self.execute("event", target=self.event), 3)
        self.assertTrue(all(not p.exists() for p in allowed))
        self.assertTrue(all(p.exists() for p in rejected))

    def test_large_unterminated_style_device_argument_is_rejected(self):
        self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        result = subprocess.run([
            str(self.executable), "root", str(self.rec), str(self.recycle),
            "A" * 10000, "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(list(self.rec.iterdir())), 1)

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


    def test_mutation_during_scan_blocks_root_prune(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        env = dict(os.environ, ORD_TEST_MUTATE_NAME=video.name)
        result = subprocess.run([
            str(self.executable), "root", str(self.rec), str(self.recycle),
            "VD3001", "mp4"
        ], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0")
        self.assertTrue(video.exists())
        self.assertIn(b"changed-after-scan", video.read_bytes())

    def test_mutation_during_scan_blocks_rotation(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        env = dict(os.environ, ORD_TEST_MUTATE_NAME=video.name)
        result = subprocess.run([
            str(self.executable), "rotate", str(self.rec), str(self.recycle),
            "VD3001", "mp4"
        ], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0")
        self.assertTrue(video.exists())
        self.assertFalse((self.recycle / "20261020_13" / video.name).exists())


    def test_path_replacement_before_root_rename_preserves_foreign_file(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        env = dict(os.environ, ORD_TEST_SWAP_BEFORE_MOVE=video.name)
        result = subprocess.run([
            str(self.executable), "root", str(self.rec), str(self.recycle),
            "VD3001", "mp4"
        ], capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(video.read_bytes(), b"IMPORTANT_NOT_RECORDING")
        self.assertEqual(
            (self.rec / "held-original.mp4").read_bytes(), video.name.encode()
        )
        self.assertFalse((self.rec / ".ord-retention-quarantine").exists())

    def test_path_replacement_before_rotation_restores_foreign_file(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        env = dict(os.environ, ORD_TEST_SWAP_BEFORE_MOVE=video.name)
        result = subprocess.run([
            str(self.executable), "rotate", str(self.rec), str(self.recycle),
            "VD3001", "mp4"
        ], capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(video.read_bytes(), b"IMPORTANT_NOT_RECORDING")
        self.assertEqual(
            (self.rec / "held-original.mp4").read_bytes(), video.name.encode()
        )
        self.assertFalse((self.recycle / "20261020_13" / video.name).exists())

    def test_nonempty_quarantine_blocks_deletion_and_preserves_content(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        stage = self.rec / ".ord-retention-quarantine"
        stage.mkdir(mode=0o700)
        retained = stage / "previous-unverified-recording.bin"
        retained.write_bytes(b"must preserve")
        result = subprocess.run([
            str(self.executable), "root", str(self.rec), str(self.recycle),
            "VD3001", "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(video.is_file())
        self.assertEqual(retained.read_bytes(), b"must preserve")


    def test_interrupted_quarantine_with_valid_filename_preserves_both_versions(self):
        name = "VD3001_20261020_130001-ch0.mp4"
        video = self.make_file(self.rec, name)
        stage = self.rec / ".ord-retention-quarantine"
        stage.mkdir(mode=0o700)
        retained = stage / name
        retained.write_bytes(b"unverified-crash-remainder")
        result = subprocess.run([
            str(self.executable), "root", str(self.rec),
            str(self.recycle), "VD3001", "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(video.read_bytes(), name.encode())
        self.assertEqual(retained.read_bytes(), b"unverified-crash-remainder")

    def test_symlinked_quarantine_does_not_escape_recording_root(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        external = Path(self.work.name) / "external-staging"
        external.mkdir()
        marker = (external / "outside-file.txt")
        marker.write_bytes(b"never-delete")
        stage = self.rec / ".ord-retention-quarantine"
        stage.symlink_to(external, target_is_directory=True)
        result = subprocess.run([
            str(self.executable), "root", str(self.rec),
            str(self.recycle), "VD3001", "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(video.is_file())
        self.assertTrue(stage.is_symlink())
        self.assertEqual(marker.read_bytes(), b"never-delete")

    def test_quarantine_with_public_permissions_is_rejected(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        stage = self.rec / ".ord-retention-quarantine"
        stage.mkdir()
        stage.chmod(0o755)
        result = subprocess.run([
            str(self.executable), "root", str(self.rec),
            str(self.recycle), "VD3001", "mp4"
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(video.exists())
        self.assertTrue(stage.is_dir())

    def test_preexisting_empty_private_quarantine_is_reusable(self):
        video = self.make_file(self.rec, "VD3001_20261020_130001-ch0.mp4")
        stage = self.rec / ".ord-retention-quarantine"
        stage.mkdir(mode=0o700)
        self.assertEqual(self.execute("root"), 1)
        self.assertFalse(video.exists())
        self.assertFalse(stage.exists())


if __name__ == "__main__":
    unittest.main()
