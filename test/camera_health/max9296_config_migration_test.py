#!/usr/bin/env python3
"""Exercise MAX9296 crop-default migration through the packaged updater."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "dist/pim/opt/pim/config/edgeconf_pim_base.json"
UPDATER = ROOT / "dist/pim/opt/pim/bin/update_edgeconf.sh"


def migrate(document: dict) -> dict:
    with tempfile.TemporaryDirectory(prefix="max9296-config-migration.") as work:
        target = Path(work) / "edgeconf_pim.json"
        model_info = Path(work) / "model_info.json"
        target.write_text(json.dumps(document), encoding="utf-8")
        model_info.write_text(json.dumps({"model_name": "pim-test"}), encoding="utf-8")
        environment = os.environ.copy()
        environment["EDGE_CONF_FILE"] = str(target)
        environment["MODEL_INFO_FILE"] = str(model_info)
        result = subprocess.run(
            ["bash", str(UPDATER)],
            cwd=work,
            env=environment,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            "packaged edgeconf migration failed:\n"
            + result.stdout
            + result.stderr
        )
        return json.loads(target.read_text(encoding="utf-8"))


def controls(document: dict, bus: str, channel: str) -> tuple:
    camera = document["VHL_CAM"]
    return (
        camera[bus]["crop_enable"],
        camera[bus]["dz"],
        camera[bus][channel]["dz_x"],
        camera[bus][channel]["dz_y"],
    )


def main() -> int:
    legacy = json.loads(BASE.read_text(encoding="utf-8"))
    for bus, channels in (("i2c2", ("ch0", "ch1")),
                          ("i2c1", ("ch2", "ch3"))):
        legacy["VHL_CAM"][bus].pop("crop_enable", None)
        legacy["VHL_CAM"][bus].pop("dz", None)
        for channel in channels:
            legacy["VHL_CAM"][bus][channel].pop("dz_x", None)
            legacy["VHL_CAM"][bus][channel].pop("dz_y", None)

    migrated = migrate(legacy)
    for bus, channels in (("i2c2", ("ch0", "ch1")),
                          ("i2c1", ("ch2", "ch3"))):
        for channel in channels:
            assert controls(migrated, bus, channel) == (False, 100, 32768, 32768), (
                f"legacy {bus}.{channel} did not receive safe crop defaults"
            )

    customized = json.loads(BASE.read_text(encoding="utf-8"))
    expected = {
        ("i2c2", "ch0"): (True, 150, 12000, 22000),
        ("i2c2", "ch1"): (True, 150, 32000, 42000),
        ("i2c1", "ch2"): (True, 200, 14000, 24000),
        ("i2c1", "ch3"): (True, 200, 34000, 44000),
    }
    for (bus, channel), values in expected.items():
        crop_enable, dz, dz_x, dz_y = values
        customized["VHL_CAM"][bus]["crop_enable"] = crop_enable
        customized["VHL_CAM"][bus]["dz"] = dz
        customized["VHL_CAM"][bus][channel]["dz_x"] = dz_x
        customized["VHL_CAM"][bus][channel]["dz_y"] = dz_y

    preserved = migrate(customized)
    for key, values in expected.items():
        assert controls(preserved, *key) == values, (
            f"migration overwrote configured crop controls for {key[0]}.{key[1]}"
        )

    print("PASS: edgeconf migration backfills and preserves MAX9296 crop controls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
