#!/usr/bin/env python3
"""Validate the packaged MAX9296 production camera defaults."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "dist/pim/opt/pim/config/edgeconf_pim_base.json"
FRAGMENT = ROOT / "dist/pim/opt/pim/config/max9296_640x360_fragment.json"


def main() -> int:
    document = json.loads(CONFIG.read_text(encoding="utf-8"))
    camera = document["VHL_CAM"]

    expected_output = (640, 360, 30)
    actual_output = (
        camera["cam_width"],
        camera["cam_height"],
        camera["fps"],
    )
    assert actual_output == expected_output, (
        f"production output must be 640x360@30, got "
        f"{actual_output[0]}x{actual_output[1]}@{actual_output[2]}"
    )

    for bus, channels in (("i2c2", ("ch0", "ch1")),
                          ("i2c1", ("ch2", "ch3"))):
        controls = camera[bus]
        assert controls["crop_enable"] is False, (
            f"{bus}.crop_enable must default to false"
        )
        assert controls["dz"] == 100, f"{bus}.dz must default to 1.00x"

        for channel in channels:
            center = controls[channel]
            assert center["dz_x"] == 32768, (
                f"{bus}.{channel}.dz_x must default to the horizontal center"
            )
            assert center["dz_y"] == 32768, (
                f"{bus}.{channel}.dz_y must default to the vertical center"
            )

    fragment = json.loads(FRAGMENT.read_text(encoding="utf-8"))
    assert (fragment["cam_width"], fragment["cam_height"], fragment["fps"]) == (
        640, 360, 30
    ), "the deployable fragment must select 640x360@30"
    for bus, channels in (("i2c2", ("ch0", "ch1")),
                          ("i2c1", ("ch2", "ch3"))):
        assert fragment[bus]["crop_enable"] is False
        assert fragment[bus]["dz"] == 100
        for channel in channels:
            assert fragment[bus][channel] == {"dz_x": 32768, "dz_y": 32768}

    print("PASS: packaged MAX9296 defaults and fragment select safe 640x360")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
