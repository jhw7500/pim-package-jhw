#!/usr/bin/env python3
"""Validate packaged MAX9296 360p qualification tools."""

from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "dist/pim/opt/pim/bin"


def require_contract(path: Path, tokens: tuple[str, ...]) -> None:
    assert path.is_file(), f"missing packaged MAX9296 tool: {path.name}"
    assert os.access(path, os.X_OK), f"packaged tool is not executable: {path.name}"
    source = path.read_text(encoding="utf-8")
    for token in tokens:
        assert token in source, f"{path.name} is missing contract token: {token}"


def main() -> int:
    require_contract(
        BIN / "cam_fps_stack.sh",
        ("1280x360@*", "--requested-fps", "FPS_RESULT"),
    )
    require_contract(
        BIN / "cam_360p_resource.sh",
        ("derive_dmesg_delta", "V4L2_FORMAT", "DMESG_RESULT"),
    )
    require_contract(
        BIN / "uyvy_frame_check.py",
        ("UYVY_RESULT", "mostly_green", "luma_variance"),
    )

    print("PASS: packaged MAX9296 FPS, resource, and UYVY tools")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
