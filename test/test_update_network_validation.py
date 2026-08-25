#!/usr/bin/env python3
"""Regression tests for generated netplan validation."""

from __future__ import annotations

import builtins
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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

    def test_non_string_static_ip_values_are_rejected(self):
        invalid_values = (
            (1234, "255.255.255.0"),
            (True, "255.255.255.0"),
            ("192.168.0.10", 24),
        )

        for path, module in self.modules:
            for address, netmask in invalid_values:
                with self.subTest(path=path, address=address, netmask=netmask):
                    try:
                        result = module.calcu_set_static_ip(address, netmask)
                    except Exception as exc:
                        self.fail(f"{path} raised for non-string IPv4 input: {exc}")
                    self.assertEqual("", result)

    def test_invalid_static_ip_aborts_before_network_side_effects(self):
        edgeconf = {
            "NETWORK": {
                "used": "ETH0",
                "ETH0": {
                    "method": "static",
                    "address": "not-an-ip",
                    "netmask": "255.255.255.0",
                },
                "ETH1": {"method": "dhcp"},
                "WLAN0": {
                    "method": "dhcp",
                    "security": "OPEN",
                    "ssid": "test-network",
                },
            }
        }

        for path, module in self.modules:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                directory_path = Path(directory)
                config_path = directory_path / "edgeconf.json"
                config_path.write_text(json.dumps(edgeconf), encoding="utf-8")
                shell_calls = []

                def redirected_open(file, *args, **kwargs):
                    file_path = Path(file)
                    if file_path.parent == Path("/tmp"):
                        file_path = directory_path / file_path.name
                    return builtins.open(file_path, *args, **kwargs)

                def record_shell_call(command):
                    shell_calls.append(command)
                    return True

                with mock.patch.object(
                    module, "get_global_conf", return_value=str(config_path)
                ), mock.patch.object(
                    module, "_shell", side_effect=record_shell_call
                ), mock.patch.object(
                    module, "open", side_effect=redirected_open, create=True
                ), mock.patch.object(
                    module.os.path, "isfile", return_value=False
                ):
                    result = module.update_network()

                self.assertFalse(result)
                self.assertEqual([], shell_calls)


if __name__ == "__main__":
    unittest.main()
