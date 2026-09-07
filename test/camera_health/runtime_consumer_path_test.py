#!/usr/bin/env python3
"""Explicit camera runtime/source ownership boundary audit."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNTIME_PATH = "/run/pim-camera/config/pim_runtime.json"

# This list is intentionally explicit.  Adding a camera consumer requires a
# review of its configuration ownership instead of silently widening a grep.
CAMERA_RUNTIME_CONSUMERS = (
    Path("dist/pim/opt/pim/bin/chk_cam_operate.sh"),
    Path("dist/pim/opt/pim/bin/cam_operate_stop.sh"),
    Path("dist/pim/opt/pim/bin/start_cam.sh"),
    Path("dist/pim/opt/pim/bin/restart_app.sh"),
    Path("dist/pim/opt/pim/bin/kill_test.sh"),
    Path("dist/pim/opt/pim/bin/init_cam.sh"),
    Path("dist/pim/opt/pim/bin/cam_hard_reset.sh"),
    Path("dist/pim/opt/pim/bin/BG_Check_for_pim.sh"),
    Path("dist/pim/opt/pim/bin/cam_channel_resolve.sh"),
    Path("dist/pim/opt/pim/bin/pim_guardian.py"),
    Path("dist/pim/opt/pim/bin/camera_config_expectation.py"),
    Path("dist/pim/opt/pim/bin/camera_capture_probe.py"),
    Path("dist/pim/opt/pim/lib/cam_recovery.sh"),
    Path("dist/pim/opt/pim/lib/cam_recovery_actions.sh"),
    Path("dist/pim/opt/pim/lib/cam_liveness.sh"),
    Path("dist/pim/opt/pim/lib/cam_operate_control.sh"),
)

# These files deliberately own or edit source configuration.  They are kept
# out of broad consumer cleanups and are audited separately as an allowlist.
CAMERA_SOURCE_READERS = (
    Path("dist/pim/opt/pim/bin/camera_runtime_config.py"),
    Path("dist/pim/opt/pim/lib/cam_operate_control.sh"),
    Path("dist/pim/opt/pim/bin/config_guard.sh"),
    Path("dist/pim/opt/pim/bin/camera_config_bootstrap.sh"),
    Path("dist/pim/opt/pim/bin/update_edgeconf.sh"),
    Path("dist/pim/opt/pim/bin/update_ordvcmconf.sh"),
    Path("dist/pim/opt/pim/bin/update_network_pim.py"),
    Path("dist/pim/opt/pim/bin/update_eap_id.py"),
    Path("dist/pim/opt/pim/bin/update_time_sync.sh"),
    Path("dist/pim/opt/pim/bin/factory_init.sh"),
    Path("dist/pim/opt/pim/bin/factory_init_pim_gate.sh"),
    Path("dist/pim/opt/pim/bin/chk_wifi.sh"),
    Path("dist/pim/opt/pim/bin/chk_eth1.sh"),
)

# cam_operate_control is both a runtime consumer and the daemon-owned handoff
# to the sole source builder.  Its source-root injection is the one reviewed
# exception inside CAMERA_RUNTIME_CONSUMERS.
DAEMON_SOURCE_OWNER_FILES = {
    Path("dist/pim/opt/pim/lib/cam_operate_control.sh"),
}

DIRECT_RUNTIME_DEFAULTS = {
    Path("dist/pim/opt/pim/bin/BG_Check_for_pim.sh"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/bin/cam_channel_resolve.sh"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/bin/pim_guardian.py"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/bin/camera_config_expectation.py"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/lib/cam_recovery.sh"): "PIM_CAMERA_RUN_DIR/config/pim_runtime.json",
}

RUNTIME_BOUNDARY_MARKERS = {
    Path("dist/pim/opt/pim/bin/chk_cam_operate.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/cam_operate_stop.sh"): "cam_recovery_actions.sh",
    Path("dist/pim/opt/pim/bin/start_cam.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/restart_app.sh"): "cam-recoveryctl",
    Path("dist/pim/opt/pim/bin/kill_test.sh"): "cam-recoveryctl",
    Path("dist/pim/opt/pim/bin/init_cam.sh"): "cam-recoveryctl",
    Path("dist/pim/opt/pim/bin/cam_hard_reset.sh"): "cam-recoveryctl",
    Path("dist/pim/opt/pim/bin/BG_Check_for_pim.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/cam_channel_resolve.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/pim_guardian.py"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/camera_config_expectation.py"): "pim_runtime.json",
    Path("dist/pim/opt/pim/bin/camera_capture_probe.py"): "load_expectation",
    Path("dist/pim/opt/pim/lib/cam_recovery.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/lib/cam_recovery_actions.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/lib/cam_liveness.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/lib/cam_operate_control.sh"): "PIM_CAMERA_RUNTIME_JSON",
}

FORBIDDEN_CONFIG_CONTRACTS = (
    ("temporary config directory", re.compile(r"/tmp/config(?:/|\b)")),
    ("temporary source fallback", re.compile(r"/tmp/shared_v(?:/|\b)")),
    ("source edgeconf discovery", re.compile(r"edgeconf_[^\n\"']*\*[^\n\"']*\.json")),
    ("config sha", re.compile(r"\bconfig_sha256\b")),
    ("boot import sha", re.compile(r"\bboot_import_sha256\b")),
    ("runtime override hash state", re.compile(r"\bruntime_override\b")),
    ("boot manifest", re.compile(r"\bboot_manifest(?:\.json)?\b")),
    ("config generation", re.compile(r"\b(?:config|runtime)_generation\b|\bgeneration_id\b")),
)

GUARDIAN_BANNED_CAMERA_SIDE_EFFECTS = (
    "/tmp/recover_req_init_cam",
    "init_cam.sh",
    "kill_test.sh",
    "start_cam.sh",
    "cam_hard_reset.sh",
)


def executable_text(path: Path) -> str:
    """Drop full-line comments so policy checks inspect executable contracts."""
    text = (ROOT / path).read_text(encoding="utf-8")
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def check(condition: bool, label: str, failures: list[str]) -> None:
    if condition:
        print(f"  OK   {label}")
    else:
        failures.append(label)
        print(f"  FAIL {label}", file=sys.stderr)


def main() -> int:
    print("=== camera runtime consumer boundary ===")
    failures: list[str] = []

    check(
        set(RUNTIME_BOUNDARY_MARKERS) == set(CAMERA_RUNTIME_CONSUMERS),
        "every explicit camera consumer has a reviewed runtime boundary",
        failures,
    )
    for relative in CAMERA_RUNTIME_CONSUMERS:
        path = ROOT / relative
        check(path.is_file(), f"consumer exists: {relative}", failures)
        if not path.is_file():
            continue
        text = executable_text(relative)
        marker = RUNTIME_BOUNDARY_MARKERS[relative]
        check(marker in text, f"{relative}: resolves through {marker}", failures)
        for name, pattern in FORBIDDEN_CONFIG_CONTRACTS:
            check(
                pattern.search(text) is None,
                f"{relative}: no {name}",
                failures,
            )
        if relative not in DAEMON_SOURCE_OWNER_FILES:
            check(
                "/root/shared_v" not in text,
                f"{relative}: no source-root read",
                failures,
            )

    for relative, expected_default in DIRECT_RUNTIME_DEFAULTS.items():
        text = executable_text(relative)
        check(
            expected_default in text,
            f"{relative}: production default is {RUNTIME_PATH}",
            failures,
        )

    guardian = executable_text(Path("dist/pim/opt/pim/bin/pim_guardian.py"))
    for banned in GUARDIAN_BANNED_CAMERA_SIDE_EFFECTS:
        check(banned not in guardian, f"guardian never invokes {banned}", failures)
    check(
        "cam-recoveryctl" in guardian,
        "guardian camera recovery uses cam-recoveryctl",
        failures,
    )

    check(
        set(DAEMON_SOURCE_OWNER_FILES) <= set(CAMERA_SOURCE_READERS),
        "daemon source handoff is explicitly source-owned",
        failures,
    )
    for relative in CAMERA_SOURCE_READERS:
        path = ROOT / relative
        check(path.is_file(), f"source reader exists: {relative}", failures)
        if not path.is_file():
            continue
        text = executable_text(relative)
        check(
            bool(re.search(r"/root/shared_v|PIM_CAMERA_SOURCE_ROOT|source_root", text)),
            f"source reader remains explicitly classified: {relative}",
            failures,
        )

    print()
    print(f"camera runtime consumer boundary: {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
