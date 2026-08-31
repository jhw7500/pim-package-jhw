#!/usr/bin/env python3
"""Validate packaged MAX9296 360p qualification tools."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "dist/pim/opt/pim/bin"


def require_contract(path: Path, tokens: tuple[str, ...]) -> None:
    assert path.is_file(), f"missing packaged MAX9296 tool: {path.name}"
    assert os.access(path, os.X_OK), f"packaged tool is not executable: {path.name}"
    source = path.read_text(encoding="utf-8")
    for token in tokens:
        assert token in source, f"{path.name} is missing contract token: {token}"


def rgb565(red: int, green: int, blue: int) -> bytes:
    word = ((red * 31 // 255) << 11) | ((green * 63 // 255) << 5) | (
        blue * 31 // 255)
    return bytes((word & 0xFF, word >> 8))


def require_rgb565_behavior(path: Path) -> None:
    width = 16
    height = 8
    stride = width * 2
    command = [
        str(path), "--width", str(width), "--height", str(height),
        "--bytesperline", str(stride),
    ]
    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        valid = temporary / "valid.rgb565"
        valid.write_bytes(
            (rgb565(255, 255, 255) + rgb565(255, 0, 0) +
             rgb565(0, 0, 255) + rgb565(0, 0, 0)) *
            (width * height // 4)
        )
        result = subprocess.run(
            command + [str(valid)], text=True, capture_output=True, check=False)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "RGB565_RESULT" in result.stdout
        assert "mostly_green=0" in result.stdout

        green = temporary / "green.rgb565"
        green.write_bytes(rgb565(0, 160, 0) * width * height)
        result = subprocess.run(
            command + [str(green)], text=True, capture_output=True, check=False)
        assert result.returncode != 0, result.stdout
        assert "mostly_green=1" in result.stdout


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
    rgb565_checker = BIN / "rgb565_frame_check.py"
    require_contract(
        rgb565_checker,
        ("RGB565_RESULT", "mostly_green", "luma_variance"),
    )
    require_rgb565_behavior(rgb565_checker)

    print("PASS: packaged MAX9296 FPS, resource, UYVY, and RGB565 tools")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
