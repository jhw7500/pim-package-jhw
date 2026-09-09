#!/usr/bin/env python3
"""Contract tests for camera recovery systemd and Debian integration."""

from __future__ import annotations

import re
import shlex
import unittest
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = ROOT / "dist/pim"
UNIT_ROOT = PACKAGE_ROOT / "etc/systemd/system"
DEBIAN_ROOT = PACKAGE_ROOT / "DEBIAN"

Directive = Tuple[str, str]
Sections = Dict[str, List[Directive]]


def read(relative: Path) -> str:
    return (PACKAGE_ROOT / relative).read_text(encoding="utf-8")


def parse_unit(text: str) -> Sections:
    """Parse active systemd directives without losing duplicate keys."""
    sections: Sections = {}
    current = ""
    for number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, [])
            continue
        if not current or "=" not in line:
            raise ValueError(f"invalid unit line {number}: {raw_line!r}")
        key, value = line.split("=", 1)
        sections[current].append((key.strip(), value.strip()))
    return sections


def values(sections: Sections, section: str, key: str) -> List[str]:
    return [value for found_key, value in sections.get(section, []) if found_key == key]


def directive_tokens(sections: Sections, section: str, key: str) -> List[str]:
    result: List[str] = []
    for value in values(sections, section, key):
        result.extend(value.split())
    return result


def require_token(
    errors: List[str], sections: Sections, section: str, key: str, token: str
) -> None:
    if token not in directive_tokens(sections, section, key):
        errors.append(f"[{section}] {key}= must include {token}")


def require_single(
    errors: List[str], sections: Sections, section: str, key: str, expected: str
) -> None:
    actual = values(sections, section, key)
    if actual != [expected]:
        errors.append(
            f"[{section}] {key}= must occur once as {expected!r}; found {actual!r}"
        )


def pim_camera_config_errors(text: str) -> List[str]:
    sections = parse_unit(text)
    errors: List[str] = []
    require_token(
        errors, sections, "Unit", "Requires", "pim-config-guard.service"
    )
    require_token(errors, sections, "Unit", "After", "pim-config-guard.service")
    require_token(errors, sections, "Unit", "Before", "cam-operate.service")
    require_single(
        errors,
        sections,
        "Service",
        "ExecStart",
        "/opt/pim/bin/camera_config_bootstrap.sh",
    )
    description = " ".join(values(sections, "Unit", "Description")).lower()
    if any(word in description for word in ("snapshot", "publish", "publication")):
        errors.append("description must identify a prerequisite guard, not publication")
    if "/tmp/config/READY" in text or "/run/pim-camera/config" in text:
        errors.append("guard unit must not claim or condition on the runtime tree")
    for forbidden in ("RuntimeDirectory", "StateDirectory"):
        if any(key == forbidden for directives in sections.values() for key, _ in directives):
            errors.append(f"guard unit must not own {forbidden}")
    return errors


def cam_operate_errors(text: str) -> List[str]:
    sections = parse_unit(text)
    errors: List[str] = []
    require_token(
        errors, sections, "Unit", "Requires", "pim-camera-config.service"
    )
    require_token(errors, sections, "Unit", "After", "pim-camera-config.service")
    require_token(errors, sections, "Unit", "After", "sd-mount.service")
    expected = {
        "RuntimeDirectory": "pim-camera",
        "RuntimeDirectoryMode": "0750",
        "StateDirectory": "pim-camera",
        "StateDirectoryMode": "0750",
        "KillMode": "control-group",
        "TimeoutStopSec": "90s",
        "Restart": "on-failure",
        "RestartSec": "10s",
    }
    for key, value in expected.items():
        require_single(errors, sections, "Service", key, value)
    if values(sections, "Unit", "DefaultDependencies"):
        errors.append("DefaultDependencies= must be absent")
    if any(
        key == "RuntimeDirectoryPreserve"
        for directives in sections.values()
        for key, _ in directives
    ):
        errors.append("RuntimeDirectoryPreserve= must be absent")
    return errors


def ord_operate_errors(text: str) -> List[str]:
    sections = parse_unit(text)
    errors: List[str] = []
    require_token(errors, sections, "Unit", "After", "cam-operate.service")
    require_token(errors, sections, "Unit", "PartOf", "cam-operate.service")
    restart_keys = [
        key
        for directives in sections.values()
        for key, _ in directives
        if key.startswith("Restart")
    ]
    if restart_keys:
        errors.append(f"manual executor must have no restart directives: {restart_keys}")
    if "Install" in sections:
        errors.append("manual executor must not have an [Install] section")
    return errors


def camera_consumer_errors(text: str, name: str) -> List[str]:
    sections = parse_unit(text)
    errors: List[str] = []
    require_token(errors, sections, "Unit", "After", "cam-operate.service")
    conditions = values(sections, "Unit", "ConditionPathExists")
    runtime = "/run/pim-camera/config/pim_runtime.json"
    if runtime not in conditions:
        errors.append(
            f"{name} [Unit] ConditionPathExists= must include the merged runtime"
        )
    if "/tmp/config/READY" in text:
        errors.append(f"{name} must not reference /tmp/config/READY")
    if "Install" in sections:
        errors.append(f"{name} must remain deliberately non-enabled")
    return errors


def shell_commands(text: str) -> List[List[str]]:
    commands: List[List[str]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            tokens = shlex.split(line, comments=True, posix=True)
        except ValueError:
            continue
        if tokens:
            commands.append(tokens)
    return commands


def command_index(commands: Sequence[Sequence[str]], expected: Sequence[str]) -> int:
    for index, command in enumerate(commands):
        if list(command[: len(expected)]) == list(expected):
            return index
    return -1


def require_command(
    errors: List[str], commands: Sequence[Sequence[str]], expected: Sequence[str]
) -> int:
    index = command_index(commands, expected)
    if index < 0:
        errors.append("missing command: " + " ".join(expected))
    return index


def postinst_errors(text: str) -> List[str]:
    commands = shell_commands(text)
    errors: List[str] = []
    require_command(
        errors,
        commands,
        (
            "ln",
            "-sf",
            "/opt/pim/bin/cam-recoveryctl",
            "/usr/local/bin/cam-recoveryctl",
        ),
    )
    require_command(
        errors,
        commands,
        (
            "ln",
            "-sf",
            "/opt/pim/bin/kill_test.sh",
            "/usr/local/bin/killcam",
        ),
    )
    required_order = [
        ("customctl", "enable", "pim-config-guard"),
        ("customctl", "enable", "pim-camera-config"),
        ("customctl", "disable", "ord-operate"),
        ("customctl", "enable", "cam-operate"),
    ]
    positions = [require_command(errors, commands, command) for command in required_order]
    if all(position >= 0 for position in positions) and positions != sorted(positions):
        errors.append(
            "service lifecycle commands must enable both guards, disable stale ORD "
            "enablement, then enable cam-operate"
        )
    for command in commands:
        joined = " ".join(command)
        if "ord-operate" in joined and "mask" in command:
            errors.append("ord-operate.service must be disabled, never masked")
    return errors


def preinst_errors(text: str) -> List[str]:
    commands = shell_commands(text)
    errors: List[str] = []
    cam = require_command(
        errors, commands, ("systemctl", "stop", "cam-operate.service")
    )
    sd_mount = require_command(
        errors, commands, ("systemctl", "stop", "sd-mount.service")
    )
    if cam >= 0 and sd_mount >= 0 and cam >= sd_mount:
        errors.append("cam-operate.service must stop before sd-mount.service")
    return errors


def persistent_delete_lines(text: str) -> List[str]:
    """Return active destructive commands that target persistent recovery state."""
    paths = ("/var/lib/pim-camera", "service-state.json", "recovery/history")
    destructive = re.compile(r"(?:^|[;&|]\s*)(?:rm|rmdir|unlink|find)\b")
    bad: List[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if destructive.search(line) and any(path in line for path in paths):
            bad.append(line)
    return bad


def parse_control_fields(text: str) -> Dict[str, str]:
    fields: Dict[str, str] = {}
    for raw_line in text.splitlines():
        if not raw_line or raw_line[0].isspace() or ":" not in raw_line:
            continue
        key, value = raw_line.split(":", 1)
        fields[key] = value.strip()
    return fields


def control_errors(text: str) -> List[str]:
    fields = parse_control_fields(text)
    errors: List[str] = []
    expected_version = "0.6.3+jhw.camera7"
    expected_dependencies = "python3, python3-yaml, jq, util-linux, procps"
    if fields.get("Version") != expected_version:
        errors.append(
            f"Version must be {expected_version!r}; found {fields.get('Version')!r}"
        )
    if fields.get("Depends") != expected_dependencies:
        errors.append(
            f"Depends must be {expected_dependencies!r}; "
            f"found {fields.get('Depends')!r}"
        )
    return errors


class SystemdRecoveryContract(unittest.TestCase):
    def assert_contract(self, name: str, errors: Iterable[str]) -> None:
        found = list(errors)
        self.assertFalse(found, name + ":\n  - " + "\n  - ".join(found))

    def test_prerequisite_guard_does_not_publish_runtime(self) -> None:
        text = read(Path("etc/systemd/system/pim-camera-config.service"))
        self.assert_contract("pim-camera-config.service", pim_camera_config_errors(text))

    def test_cam_operate_owns_ephemeral_runtime_and_persistent_state(self) -> None:
        text = read(Path("etc/systemd/system/cam-operate.service"))
        self.assert_contract("cam-operate.service", cam_operate_errors(text))

    def test_ord_is_a_manual_executor_bound_to_cam_operate(self) -> None:
        text = read(Path("etc/systemd/system/ord-operate.service"))
        self.assert_contract("ord-operate.service", ord_operate_errors(text))

    def test_camera_consumers_wait_for_the_merged_runtime(self) -> None:
        names = (
            "camera-capture-probe.service",
            "camera-health-shadow.service",
            "camera-health-shadow-compare.service",
        )
        for name in names:
            with self.subTest(unit=name):
                text = read(Path("etc/systemd/system") / name)
                self.assert_contract(name, camera_consumer_errors(text, name))

    def test_no_changed_camera_unit_uses_the_ready_marker(self) -> None:
        names = (
            "pim-camera-config.service",
            "cam-operate.service",
            "ord-operate.service",
            "camera-capture-probe.service",
            "camera-health-shadow.service",
            "camera-health-shadow-compare.service",
        )
        offenders = [
            name
            for name in names
            if "/tmp/config/READY"
            in read(Path("etc/systemd/system") / name)
        ]
        self.assertEqual([], offenders)

    def test_postinst_links_cli_and_orders_service_enablement(self) -> None:
        self.assert_contract("postinst", postinst_errors(read(Path("DEBIAN/postinst"))))

    def test_preinst_stops_owner_before_shared_storage(self) -> None:
        self.assert_contract("preinst", preinst_errors(read(Path("DEBIAN/preinst"))))

    def test_postrm_never_deletes_persistent_recovery_history(self) -> None:
        bad = persistent_delete_lines(read(Path("DEBIAN/postrm")))
        self.assertEqual([], bad, "persistent recovery deletion found: " + repr(bad))

    def test_package_version_and_runtime_dependencies_are_exact(self) -> None:
        self.assert_contract(
            "DEBIAN/control", control_errors(read(Path("DEBIAN/control")))
        )


class ContractMutationSelfChecks(unittest.TestCase):
    """Prove the helpers reject realistic weakening of the intended contract."""

    def test_service_directive_moved_to_unit_section_is_rejected(self) -> None:
        fixture = """\
[Unit]
Requires=pim-camera-config.service
After=pim-camera-config.service sd-mount.service
RuntimeDirectory=pim-camera
[Service]
RuntimeDirectoryMode=0750
StateDirectory=pim-camera
StateDirectoryMode=0750
KillMode=control-group
TimeoutStopSec=90s
Restart=on-failure
RestartSec=10s
"""
        errors = cam_operate_errors(fixture)
        self.assertTrue(any("RuntimeDirectory=" in error for error in errors), errors)

    def test_maintainer_command_reordering_is_rejected(self) -> None:
        fixture = """\
ln -sf /opt/pim/bin/cam-recoveryctl /usr/local/bin/cam-recoveryctl
ln -sf /opt/pim/bin/kill_test.sh /usr/local/bin/killcam
customctl enable cam-operate
customctl enable pim-config-guard
customctl enable pim-camera-config
customctl disable ord-operate
"""
        errors = postinst_errors(fixture)
        self.assertTrue(any("lifecycle commands" in error for error in errors), errors)

    def test_persistent_history_delete_is_rejected(self) -> None:
        fixture = """\
# rm -rf /var/lib/pim-camera is documentation, not behavior
rm -rf /var/lib/pim-camera/recovery/history
"""
        self.assertEqual(
            ["rm -rf /var/lib/pim-camera/recovery/history"],
            persistent_delete_lines(fixture),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
