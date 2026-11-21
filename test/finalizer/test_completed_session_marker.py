"""Offline regression of finalizer session marker handling. No board access."""

from pathlib import Path
import os
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
FINALIZER = ROOT / "dist/pim/opt/pim/bin/chk_cam_operate.sh"


class CompletedSessionMarkerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = FINALIZER.read_text(encoding="utf-8")
        start = source.index("ProcessCompletedSessions() {")
        end = source.index("\n}\n\n# Stale .part", start) + 2
        function = source[start:end]
        original_glob = "for done_file in /tmp/session_*.all_done; do"
        if function.count(original_glob) != 1:
            raise AssertionError("finalizer marker glob changed")
        # Extract the genuine function; replace ONLY the marker glob so this
        # test never scans or removes files in the host's /tmp directory.
        cls.function = function.replace(
            original_glob,
            'for done_file in "$TEST_MARKER_DIR"/session_*.all_done; do',
        )

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="finalizer-marker-")
        self.root = Path(self.scratch.name)
        for part in ("markers", "tmp", "sdtmp", "final"):
            (self.root / part).mkdir()
        self.session = time.strftime(
            "%Y%m%d_%H%M", time.localtime(time.time() - 86400)
        )
        self.marker = self.root / "markers" / f"session_{self.session}.all_done"

    def tearDown(self):
        self.scratch.cleanup()

    def execute(self, *, matching_fragment=False, move_success=True,
                unknown_file=False, enabled_channels=(0,),
                fragment_channels=(0,), srt_enabled=False, srt_final=False,
                fragment_bytes=b"synthetic-completed-fragment"):
        self.marker.write_text(self.session + "\n", encoding="utf-8")
        if matching_fragment:
            for ch in fragment_channels:
                path = self.root / "tmp" / f"VD3001_{self.session}00-ch{ch}.mp4.part"
                path.write_bytes(fragment_bytes)
        if srt_final:
            (self.root / "final" / f"VD3001_{self.session}00-data.srt").write_bytes(
                b"synthetic-srt"
            )
        if unknown_file:
            (self.root / "tmp" / "unrelated.settings").write_bytes(b"preserve")
        env = os.environ.copy()
        env.update({
            "TEST_MARKER_DIR": str(self.root / "markers"),
            "tmp_path": str(self.root / "tmp"),
            "sd_tmp_path": str(self.root / "sdtmp"),
            "final_path": str(self.root / "final"),
            "TEST_MOVE_RESULT": "ok" if move_success else "fail",
            "vhl_name": "VD3001",
            "muxer": "mp4",
            "srt_en": "true" if srt_enabled else "false",
            **{f"cam_ch{ch}": "true" if ch in enabled_channels else "false"
               for ch in range(4)},
        })
        harness = """
KEY=OFFLINE_FIXTURE
tag=finalizer
logger() { :; }
sync() { :; }
MovePartFile() {
    if [ "$TEST_MOVE_RESULT" != "ok" ]; then return 1; fi
    local name
    name=$(basename "$1" | sed 's/[.]part$//')
    cp -- "$1" "$final_path/$name"
}
""" + self.function + "\nProcessCompletedSessions\n"
        result = subprocess.run(
            ["bash", "-c", harness], env=env, capture_output=True,
            text=True, timeout=12, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.marker.exists()

    def test_zero_matching_fragments_preserves_completion_marker(self):
        self.assertTrue(self.execute())

    def test_only_unrelated_files_preserves_completion_marker(self):
        self.assertTrue(self.execute(unknown_file=True))
        self.assertEqual(
            (self.root / "tmp" / "unrelated.settings").read_bytes(), b"preserve"
        )

    def test_successfully_processed_fragment_consumes_completion_marker(self):
        self.assertFalse(self.execute(matching_fragment=True))

    def test_failed_fragment_processing_preserves_completion_marker(self):
        self.assertTrue(self.execute(matching_fragment=True, move_success=False))


    def test_missing_second_enabled_video_preserves_marker(self):
        self.assertTrue(self.execute(
            matching_fragment=True, enabled_channels=(0, 1),
            fragment_channels=(0,),
        ))

    def test_two_enabled_video_files_allow_marker_removal(self):
        self.assertFalse(self.execute(
            matching_fragment=True, enabled_channels=(0, 1),
            fragment_channels=(0, 1),
        ))

    def test_required_srt_missing_preserves_marker(self):
        self.assertTrue(self.execute(
            matching_fragment=True, srt_enabled=True,
        ))

    def test_required_srt_finalized_allows_marker_removal(self):
        self.assertFalse(self.execute(
            matching_fragment=True, srt_enabled=True, srt_final=True,
        ))

    def test_empty_final_video_does_not_prove_completion(self):
        self.assertTrue(self.execute(
            matching_fragment=True, fragment_bytes=b"",
        ))

    def test_invalid_enabled_channel_flags_preserve_marker(self):
        self.assertTrue(self.execute(
            matching_fragment=True, enabled_channels=(),
        ))



if __name__ == "__main__":
    unittest.main()
