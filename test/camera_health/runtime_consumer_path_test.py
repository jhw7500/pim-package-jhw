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
    Path("dist/pim/opt/pim/bin/sd_mount_stop.sh"),
    Path("dist/pim/opt/pim/bin/file_manager.sh"),
    Path("dist/pim/opt/pim/bin/cpu_limit.sh"),
    Path("dist/pim/opt/pim/bin/cam_rotate_setting.sh"),
    Path("dist/pim/opt/pim/bin/ncsftp.sh"),
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
    Path("dist/pim/opt/pim/bin/set_link_speed.py"),
)

# automnt runs before cam-operate can publish a runtime.  It owns only mount
# state and the existing mount flag, so it must remain explicitly independent
# from both source and runtime JSON.
RUNTIME_INDEPENDENT_MOUNT_AUTHORITIES = (
    Path("dist/pim/opt/pim/bin/automnt_sd_for_emmc_boot.sh"),
)

# The seven review findings stay visible as one exhaustive classification.
FIX_ROUND_CLASSIFICATION = {
    Path("dist/pim/opt/pim/bin/sd_mount_stop.sh"): "runtime-consumer",
    Path("dist/pim/opt/pim/bin/file_manager.sh"): "runtime-consumer",
    Path("dist/pim/opt/pim/bin/cpu_limit.sh"): "runtime-consumer",
    Path("dist/pim/opt/pim/bin/cam_rotate_setting.sh"): "runtime-consumer",
    Path("dist/pim/opt/pim/bin/ncsftp.sh"): "runtime-consumer",
    Path("dist/pim/opt/pim/bin/automnt_sd_for_emmc_boot.sh"): "mount-authority",
    Path("dist/pim/opt/pim/bin/set_link_speed.py"): "network-source",
}

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
    Path("dist/pim/opt/pim/bin/sd_mount_stop.sh"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/bin/file_manager.sh"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/bin/cpu_limit.sh"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/bin/cam_rotate_setting.sh"): RUNTIME_PATH,
    Path("dist/pim/opt/pim/bin/ncsftp.sh"): RUNTIME_PATH,
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
    Path("dist/pim/opt/pim/bin/sd_mount_stop.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/file_manager.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/cpu_limit.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/cam_rotate_setting.sh"): "PIM_CAMERA_RUNTIME_JSON",
    Path("dist/pim/opt/pim/bin/ncsftp.sh"): "PIM_CAMERA_RUNTIME_JSON",
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

SIMPLE_ASSIGNMENT = re.compile(
    r"^\s*(?:(?:export|readonly|local)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$"
)
PARAMETER_DEFAULT = re.compile(
    r"\$\{([A-Za-z_][A-Za-z0-9_]*):-([^{}]*)\}"
)
VARIABLE_REFERENCE = re.compile(
    r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"
)
ABSOLUTE_JSON_INPUT = re.compile(r"(?<![A-Za-z0-9_])(/[A-Za-z0-9_./*:-]*\.json)\b")
CONFIG_READ_CALL = re.compile(
    r"\bjq\b|\bopen\s*\(|\.read_text\s*\(|\bjson\.loads?\s*\("
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


def strip_inline_comment(line: str) -> str:
    """Remove a shell/Python comment without treating quoted `#` as a comment."""
    quote = ""
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "'\"":
            quote = char
        elif char == "#":
            return line[:index]
    return line


def expand_constants(line: str, constants: dict[str, str]) -> str:
    """Resolve reviewed simple assignments; leave dynamic expressions untouched."""
    previous = ""
    while previous != line:
        previous = line
        line = PARAMETER_DEFAULT.sub(
            lambda match: constants.get(match.group(1), match.group(2)), line
        )
        line = VARIABLE_REFERENCE.sub(
            lambda match: constants.get(
                match.group(1) or match.group(2), match.group(0)
            ),
            line,
        )
    return line


def normalized_contract_lines(text: str) -> list[str]:
    """Expose static shell/Python string composition without executing source."""
    constants: dict[str, str] = {}
    normalized: list[str] = []
    for raw_line in text.splitlines():
        expanded = expand_constants(strip_inline_comment(raw_line), constants)
        canonical = expanded.replace("'", "").replace('"', "").strip()
        normalized.append(canonical)

        assignment = SIMPLE_ASSIGNMENT.match(canonical.rstrip(";"))
        if assignment is None:
            continue
        name, value = assignment.groups()
        value = value.rstrip(";")
        if re.fullmatch(r"[A-Za-z0-9_./*:+?-]+", value):
            constants[name] = value
    return normalized


def logical_config_read_lines(text: str, lines: list[str]) -> list[str]:
    """Join shell continuations and quoted spans within the finite input."""
    logical: list[str] = []
    command_parts: list[str] = []
    quote = ""
    for raw_line, line in zip(text.splitlines(), lines, strict=True):
        escaped = False
        code_end = len(raw_line)
        for index, char in enumerate(raw_line):
            if quote == "'":
                if char == "'":
                    quote = ""
                continue
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if quote:
                if char == quote:
                    quote = ""
                continue
            if char in "'\"":
                quote = char
            elif char == "#":
                code_end = index
                break

        code = raw_line[:code_end].rstrip()
        trailing_backslashes = len(code) - len(code.rstrip("\\"))
        continued = trailing_backslashes % 2 == 1
        command_parts.append(line[:-1].rstrip() if continued else line)
        if continued or quote:
            continue
        logical.append(" ".join(command_parts))
        command_parts = []
    if command_parts:
        logical.append(" ".join(command_parts))
    return logical


def runtime_boundary_violations(
    text: str,
    marker: str,
    default: str | None = None,
    *,
    allow_source: bool = False,
) -> list[str]:
    """Audit normalized contracts and the concrete inputs of config readers."""
    lines = normalized_contract_lines(text)
    normalized_text = "\n".join(lines)
    violations: list[str] = []
    if marker not in normalized_text:
        violations.append("missing marker")
    if default is not None and default not in normalized_text:
        violations.append("missing default")
    for name, pattern in FORBIDDEN_CONFIG_CONTRACTS:
        if pattern.search(normalized_text) is not None:
            violations.append(name)
    if not allow_source and "/root/shared_v" in normalized_text:
        violations.append("source-root read")

    for line in logical_config_read_lines(text, lines):
        if CONFIG_READ_CALL.search(line) is None:
            continue
        for match in ABSOLUTE_JSON_INPUT.finditer(line):
            path = match.group(1)
            if path == RUNTIME_PATH:
                continue
            if allow_source and path.startswith("/root/shared_v/"):
                continue
            violations.append(f"alternate config read: {path}")

    return list(dict.fromkeys(violations))


def main() -> int:
    print("=== camera runtime consumer boundary ===")
    failures: list[str] = []

    check(
        len(FIX_ROUND_CLASSIFICATION) == 7,
        "all seven review findings have an explicit authority classification",
        failures,
    )
    check(
        {
            path
            for path, authority in FIX_ROUND_CLASSIFICATION.items()
            if authority == "runtime-consumer"
        }
        <= set(CAMERA_RUNTIME_CONSUMERS),
        "five omitted camera/recording readers are runtime consumers",
        failures,
    )
    check(
        {
            path
            for path, authority in FIX_ROUND_CLASSIFICATION.items()
            if authority == "mount-authority"
        }
        == set(RUNTIME_INDEPENDENT_MOUNT_AUTHORITIES),
        "automount is the explicit runtime-independent mount authority",
        failures,
    )
    check(
        {
            path
            for path, authority in FIX_ROUND_CLASSIFICATION.items()
            if authority == "network-source"
        }
        <= set(CAMERA_SOURCE_READERS),
        "set_link_speed is explicitly classified as NETWORK source authority",
        failures,
    )

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
        violations = runtime_boundary_violations(
            text,
            marker,
            allow_source=relative in DAEMON_SOURCE_OWNER_FILES,
        )
        check(
            "missing marker" not in violations,
            f"{relative}: resolves through {marker}",
            failures,
        )
        for name, pattern in FORBIDDEN_CONFIG_CONTRACTS:
            check(
                name not in violations,
                f"{relative}: no {name}",
                failures,
            )
        if relative not in DAEMON_SOURCE_OWNER_FILES:
            check(
                "source-root read" not in violations,
                f"{relative}: no source-root read",
                failures,
            )
        check(
            not any(item.startswith("alternate config read:") for item in violations),
            f"{relative}: config readers use only the merged runtime",
            failures,
        )

    for relative, expected_default in DIRECT_RUNTIME_DEFAULTS.items():
        text = executable_text(relative)
        check(
            expected_default in text,
            f"{relative}: production default is {RUNTIME_PATH}",
            failures,
        )

    for relative in RUNTIME_INDEPENDENT_MOUNT_AUTHORITIES:
        path = ROOT / relative
        check(path.is_file(), f"mount authority exists: {relative}", failures)
        if not path.is_file():
            continue
        text = executable_text(relative)
        check(
            "/root/shared_v" not in text,
            f"{relative}: no source-root read",
            failures,
        )
        check(
            "edgeconf_" not in text and "jq" not in text,
            f"{relative}: mount bootstrap is independent of camera JSON",
            failures,
        )
        check(
            "sd_mount_flag" in text,
            f"{relative}: publishes only the existing mount flag",
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
        normalized_text = "\n".join(normalized_contract_lines(text))
        check(
            bool(
                re.search(
                    r"/root/shared_v|PIM_CAMERA_SOURCE_ROOT|source_root",
                    normalized_text,
                )
            ),
            f"source reader remains explicitly classified: {relative}",
            failures,
        )

    set_link_speed = executable_text(
        Path("dist/pim/opt/pim/bin/set_link_speed.py")
    )
    check(
        "NETWORK" in set_link_speed and "VHL_CAM" not in set_link_speed,
        "set_link_speed source authority is NETWORK-only",
        failures,
    )

    print("=== audit mutation regressions ===")
    mutation_fixtures = (
        (
            "decoy runtime marker cannot hide an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
ACTUAL_CONFIG=/etc/pim/camera.json
jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
''',
            "alternate config read:",
        ),
        (
            "multiline config reader cannot hide an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
ACTUAL_CONFIG=/etc/pim/camera.json
jq -r \\
  .VHL_CAM.app \\
  "$ACTUAL_CONFIG"
''',
            "alternate config read:",
        ),
        (
            "long continued config reader retains alternate operand context",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
ACTUAL_CONFIG=/etc/pim/camera.json
jq -r \\
  --arg a a \\
  --arg b b \\
  --arg c c \\
  --arg d d \\
  --arg e e \\
  --arg f f \\
  --arg g g \\
  .VHL_CAM.app \\
  "$ACTUAL_CONFIG"
''',
            "alternate config read:",
        ),
        (
            "quoted multiline jq filter retains alternate operand context",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
ACTUAL_CONFIG=/etc/pim/camera.json
jq -e '
  .VHL_CAM
  | type == "object"
  and (.app | type == "string")
' "$ACTUAL_CONFIG"
''',
            "alternate config read:",
        ),
        (
            "composed source-root/newest-edgeconf discovery is rejected",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
ROOT=/root
SHARED=shared_v
PREFIX=edgeconf_
SUFFIX=.json
for candidate in "$ROOT"/"$SHARED"/"$PREFIX"*"$SUFFIX"; do FILE_JSON=$candidate; done
jq -r '.VHL_CAM.app' "$PIM_CAMERA_RUNTIME_JSON"
''',
            "source-root read",
        ),
        (
            "composed hash/generation field names are rejected",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
CONFIG_HASH="config_""sha256"
BOOT_HASH="boot_""import_""sha256"
OVERRIDE="runtime_""override"
GENERATION="config_""generation"
MANIFEST="boot_""manifest"
jq -r '.VHL_CAM.app' "$PIM_CAMERA_RUNTIME_JSON"
''',
            "config sha",
        ),
    )
    for label, fixture, expected_violation in mutation_fixtures:
        violations = runtime_boundary_violations(
            fixture, "PIM_CAMERA_RUNTIME_JSON", RUNTIME_PATH
        )
        check(
            any(
                item == expected_violation or item.startswith(expected_violation)
                for item in violations
            ),
            label,
            failures,
        )

    print()
    print(f"camera runtime consumer boundary: {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
