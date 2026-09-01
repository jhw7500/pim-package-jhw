#!/usr/bin/env python3
"""Contract tests for the daemon-owned mutable camera runtime config."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "dist/pim/opt/pim/bin/camera_runtime_config.py"

spec = importlib.util.spec_from_file_location("camera_runtime_config", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load camera_runtime_config.py")
runtime = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runtime
spec.loader.exec_module(runtime)


def edge(name: str, width: int = 1920) -> dict[str, object]:
    return {
        "VHL_CAM": {
            "vhl_name": name,
            "cam_width": width,
            "cam_height": 1080,
            "fps": 30,
            "i2c2": {"ch0": {"enable": True}, "ch1": {"enable": True}},
            "i2c1": {"ch2": {"enable": True}, "ch3": {"enable": True}},
        }
    }


def ord_document() -> dict[str, object]:
    return {
        "ORD": {"port_num": 10007},
        "VCM": {"port_num": 10009, "srt_enable": True},
        "ETC": {"camera_startup_grace_sec": 40},
        "SITE_NOTE": {"keep": True},
        "VHL_CAM": {"vhl_name": "must-be-overridden"},
    }


class RuntimeConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="camera-runtime-config.")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.ord = self.source / "ord_vcm_conf.json"
        self.write_json(self.ord, ord_document())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_json(self, path: Path, document: object) -> None:
        path.write_text(json.dumps(document), encoding="utf-8")

    def write_edge(self, name: str, *, mtime_ns: int, width: int = 1920) -> Path:
        path = self.source / name
        self.write_json(path, edge(name, width))
        os.utime(path, ns=(mtime_ns, mtime_ns))
        return path

    def candidate(self, name: str = "edgeconf_current.json") -> object:
        self.write_edge(name, mtime_ns=100)
        return runtime.merge_source_documents(self.source)

    def test_selects_newest_regular_file_by_nanosecond_mtime(self) -> None:
        older = self.write_edge("edgeconf_old.json", mtime_ns=100)
        newer = self.write_edge("edgeconf_new.json", mtime_ns=101)
        selected = runtime.select_latest_edgeconf(self.source)
        self.assertEqual(newer, selected.path)
        self.assertNotEqual(older, selected.path)
        self.assertEqual(101, selected.mtime_ns)

    def test_same_mtime_uses_lexical_tie_break(self) -> None:
        self.write_edge("edgeconf_b.json", mtime_ns=100)
        expected = self.write_edge("edgeconf_a.json", mtime_ns=100)
        self.assertEqual(expected, runtime.select_latest_edgeconf(self.source).path)

    def test_directories_and_symlinks_are_not_source_candidates(self) -> None:
        self.write_edge("edgeconf_real.json", mtime_ns=100)
        (self.source / "edgeconf_directory.json").mkdir()
        target = self.root / "target.json"
        self.write_json(target, edge("symlink"))
        (self.source / "edgeconf_link.json").symlink_to(target)
        self.assertEqual(
            self.source / "edgeconf_real.json",
            runtime.select_latest_edgeconf(self.source).path,
        )

    def test_malformed_newest_json_does_not_fall_back_to_older_file(self) -> None:
        self.write_edge("edgeconf_old.json", mtime_ns=100)
        newest = self.source / "edgeconf_new.json"
        newest.write_text("{broken", encoding="utf-8")
        os.utime(newest, ns=(101, 101))
        with self.assertRaises(runtime.ConfigError):
            runtime.merge_source_documents(self.source)

    def test_missing_or_non_object_required_sections_fail_validation(self) -> None:
        document = ord_document()
        document["VHL_CAM"] = edge("valid")["VHL_CAM"]
        for key in ("VHL_CAM", "ORD", "VCM"):
            missing = dict(document)
            missing.pop(key)
            with self.subTest(key=key, form="missing"):
                with self.assertRaises(runtime.ConfigError):
                    runtime.validate_runtime(missing)
            invalid = dict(document)
            invalid[key] = []
            with self.subTest(key=key, form="non-object"):
                with self.assertRaises(runtime.ConfigError):
                    runtime.validate_runtime(invalid)

    def test_merge_keeps_complete_ord_document_and_edge_vhl_wins(self) -> None:
        self.write_edge("edgeconf_current.json", mtime_ns=100)
        candidate = runtime.merge_source_documents(self.source)
        self.assertEqual("edgeconf_current.json", candidate.document["VHL_CAM"]["vhl_name"])
        self.assertEqual({"keep": True}, candidate.document["SITE_NOTE"])
        self.assertEqual({"port_num": 10007}, candidate.document["ORD"])
        self.assertEqual(self.ord, candidate.ord_path)

    def test_stage_result_contains_only_source_path_and_mtime(self) -> None:
        selected = self.write_edge("edgeconf_current.json", mtime_ns=100)
        candidate_path = self.root / "candidate.json"
        result_path = self.root / "stage-result.json"
        self.assertEqual(0, runtime.main(["stage", "--source-root", str(self.source), "--candidate", str(candidate_path), "--result", str(result_path)]))
        self.assertEqual(
            {"path": str(selected), "mtime_ns": 100},
            json.loads(result_path.read_text(encoding="utf-8")),
        )

    def test_publish_is_atomic_mode_0640_and_repairs_relative_aliases(self) -> None:
        candidate = self.candidate()
        candidate_path = self.root / "candidate.json"
        runtime.write_json_atomic(candidate_path, candidate.document)
        runtime_dir = self.root / "runtime"
        published = runtime.atomic_publish(candidate_path, runtime_dir)
        self.assertEqual(runtime_dir / runtime.RUNTIME_NAME, published)
        self.assertEqual(0o640, stat.S_IMODE(published.stat().st_mode))
        self.assertFalse(list(runtime_dir.glob(".pim_runtime.json.*")))
        for alias in runtime.ALIAS_NAMES:
            alias_path = runtime_dir / alias
            self.assertTrue(alias_path.is_symlink())
            self.assertEqual(runtime.RUNTIME_NAME, os.readlink(alias_path))

    def test_publish_rejects_symlink_runtime_directory_and_final_path(self) -> None:
        candidate = self.candidate()
        candidate_path = self.root / "candidate.json"
        runtime.write_json_atomic(candidate_path, candidate.document)
        target = self.root / "target"
        target.mkdir()
        symlink_dir = self.root / "runtime-link"
        symlink_dir.symlink_to(target, target_is_directory=True)
        with self.assertRaises(runtime.ConfigError):
            runtime.atomic_publish(candidate_path, symlink_dir)
        runtime_dir = self.root / "runtime"
        runtime_dir.mkdir()
        (runtime_dir / runtime.RUNTIME_NAME).symlink_to(candidate_path)
        with self.assertRaises(runtime.ConfigError):
            runtime.atomic_publish(candidate_path, runtime_dir)

    def test_later_stage_restores_values_after_manual_runtime_edit(self) -> None:
        first = self.candidate("edgeconf_initial.json")
        candidate_path = self.root / "candidate.json"
        runtime.write_json_atomic(candidate_path, first.document)
        runtime_dir = self.root / "runtime"
        published = runtime.atomic_publish(candidate_path, runtime_dir)
        edited = json.loads(published.read_text(encoding="utf-8"))
        edited["VHL_CAM"]["vhl_name"] = "manual"
        published.write_text(json.dumps(edited), encoding="utf-8")
        self.write_edge("edgeconf_later.json", mtime_ns=101, width=3840)
        later = runtime.merge_source_documents(self.source)
        runtime.write_json_atomic(candidate_path, later.document)
        runtime.atomic_publish(candidate_path, runtime_dir)
        self.assertEqual("edgeconf_later.json", json.loads(published.read_text(encoding="utf-8"))["VHL_CAM"]["vhl_name"])

    def test_stage_publish_and_plan_do_not_modify_selected_sources(self) -> None:
        selected = self.write_edge("edgeconf_current.json", mtime_ns=100)
        before = (selected.read_bytes(), self.ord.read_bytes())
        candidate = runtime.merge_source_documents(self.source)
        candidate_path = self.root / "candidate.json"
        runtime.write_json_atomic(candidate_path, candidate.document)
        runtime.atomic_publish(candidate_path, self.root / "runtime")
        runtime.classify_change(candidate.document, candidate.document)
        self.assertEqual(before, (selected.read_bytes(), self.ord.read_bytes()))

    def test_semantic_equality_ignores_json_key_order_and_whitespace(self) -> None:
        current = self.candidate().document
        reordered = json.loads(json.dumps(current, indent=4, sort_keys=True))
        plan = runtime.classify_change(current, reordered)
        self.assertFalse(plan.semantic_change)
        self.assertFalse(plan.hardware_change)
        self.assertEqual([], list(plan.steps))

    def test_hardware_projection_contains_only_centralized_hardware_fields(self) -> None:
        document = self.candidate().document
        document["VHL_CAM"]["unrelated"] = "not hardware"
        document["VHL_CAM"]["v4l_map"] = {"capture": "/dev/video0"}
        projection = runtime.hardware_projection(document)
        self.assertNotIn("unrelated", json.dumps(projection))
        self.assertEqual(1920, projection["cam_width"])
        self.assertEqual({"capture": "/dev/video0"}, projection["v4l_map"])

    def test_change_plan_unions_each_section_once_and_hard_reset_precedes_restarts(self) -> None:
        current = self.candidate().document
        changed = json.loads(json.dumps(current))
        changed["VHL_CAM"]["cam_width"] = 3840
        changed["ORD"]["port_num"] = 10008
        changed["VCM"]["port_num"] = 10010
        changed["ETC"]["camera_startup_grace_sec"] = 41
        changed["SITE_NOTE"] = {"keep": False}
        plan = runtime.classify_change(current, changed)
        self.assertTrue(plan.semantic_change)
        self.assertTrue(plan.hardware_change)
        self.assertEqual(["VHL_CAM", "ORD", "VCM", "ETC", "SCRIPT"], list(plan.changed_sections))
        self.assertEqual(["camera_hard_reset", "policy_reload"], list(plan.steps))

    def test_non_hardware_vhl_restart_and_section_specific_steps(self) -> None:
        current = self.candidate().document
        changed = json.loads(json.dumps(current))
        changed["VHL_CAM"]["vhl_name"] = "new-name"
        changed["ORD"]["port_num"] = 10008
        changed["VCM"]["port_num"] = 10010
        changed["ETC"]["camera_startup_grace_sec"] = 41
        plan = runtime.classify_change(current, changed)
        self.assertFalse(plan.hardware_change)
        self.assertEqual(
            ["gstapp_restart", "ord_restart", "vcm_restart", "policy_reload"],
            list(plan.steps),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
