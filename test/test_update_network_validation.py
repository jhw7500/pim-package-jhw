#!/usr/bin/env python3
"""Regression tests for generated netplan validation."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATHS = (
    ROOT / "dist/pim/opt/cis/bin/update_network.py",
    ROOT / "dist/pim/opt/pim/bin/update_network_pim.py",
)


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location(
        f"update_network_{path.parent.parent.name}", path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class UpdateNetworkValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.modules = [(path, load_module(path)) for path in MODULE_PATHS]

    def test_accepts_valid_yaml_and_rejects_malformed_yaml(self):
        with tempfile.TemporaryDirectory() as directory:
            valid = Path(directory) / "valid.yaml"
            invalid = Path(directory) / "invalid.yaml"
            valid.write_text("network:\n  version: 2\n", encoding="utf-8")
            invalid.write_text("network: [\n", encoding="utf-8")

            for path, module in self.modules:
                with self.subTest(path=path):
                    validator = getattr(module, "check_yaml_file", None)
                    self.assertIsNotNone(
                        validator, f"{path} must validate generated YAML"
                    )
                    self.assertTrue(validator(valid))
                    self.assertFalse(validator(invalid))

    def test_invalid_ipv4_address_is_rejected_without_an_exception(self):
        for path, module in self.modules:
            with self.subTest(path=path):
                try:
                    result = module.calcu_set_static_ip("not-an-ip", "255.255.255.0")
                except Exception as exc:
                    self.fail(f"{path} raised for invalid IPv4 input: {exc}")
                self.assertEqual("", result)


if __name__ == "__main__":
    unittest.main()
