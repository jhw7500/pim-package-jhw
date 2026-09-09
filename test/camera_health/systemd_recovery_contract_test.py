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
RUNTIME_JSON = "/run/pim-camera/config/pim_runtime.json"
RUNTIME_VALIDATOR = "/opt/pim/bin/camera_runtime_config.py"
RUNTIME_BARRIER = (
    "/bin/sh -c 'until test -f "
    + RUNTIME_JSON
    + " && "
    + RUNTIME_VALIDATOR
    + " validate --file "
    + RUNTIME_JSON
    + "; do sleep 1; done'"
)

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


def effective_conditions(sections: Sections) -> List[Directive]:
    """Return [Unit] conditions after applying systemd's empty reset rule."""
    effective: List[Directive] = []
    for key, value in sections.get("Unit", []):
        if not key.startswith("Condition"):
            continue
        if value == "":
            effective.clear()
        else:
            effective.append((key, value))
    return effective


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
        "TimeoutStartSec": "90s",
        "TimeoutStopSec": "90s",
        "Restart": "on-failure",
        "RestartSec": "10s",
    }
    for key, value in expected.items():
        require_single(errors, sections, "Service", key, value)
    require_single(
        errors,
        sections,
        "Service",
        "ExecStop",
        "/opt/pim/bin/cam_operate_stop.sh",
    )
    require_single(errors, sections, "Service", "ExecStartPost", RUNTIME_BARRIER)
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
    part_of = [
        value
        for directives in sections.values()
        for key, value in directives
        if key == "PartOf"
    ]
    if part_of:
        errors.append(f"manual executor must have no PartOf propagation: {part_of}")
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
    require_single(
        errors, sections, "Service", "ExecStart", "/usr/local/bin/ord"
    )
    if "yes" in directive_tokens(sections, "Unit", "RefuseManualStart"):
        errors.append("manual executor must remain manually startable")
    return errors


def camera_consumer_errors(text: str, name: str) -> List[str]:
    sections = parse_unit(text)
    errors: List[str] = []
    require_token(errors, sections, "Unit", "Requires", "cam-operate.service")
    require_token(errors, sections, "Unit", "After", "cam-operate.service")
    conditions = effective_conditions(sections)
    if ("ConditionPathExists", RUNTIME_JSON) not in conditions:
        errors.append(
            f"{name} [Unit] ConditionPathExists= must include the merged runtime"
        )
    if name == "camera-health-shadow-compare.service" and (
        "ConditionPathExists",
        "/run/pim-camera/aggregate-shadow.json",
    ) not in conditions:
        errors.append(f"{name} must preserve its effective aggregate condition")
    if "/tmp/config/READY" in text:
        errors.append(f"{name} must not reference /tmp/config/READY")
    if "Install" in sections:
        errors.append(f"{name} must remain deliberately non-enabled")
    return errors


LogicalLine = Tuple[int, str]


def _strip_shell_comment(line: str) -> str:
    """Strip an active shell comment while preserving quoted # characters."""
    quote = ""
    escaped = False
    for index, character in enumerate(line):
        if escaped:
            escaped = False
            continue
        if quote == "'":
            if character == "'":
                quote = ""
            continue
        if quote == '"':
            if character == "\\":
                escaped = True
            elif character == '"':
                quote = ""
            continue
        if character == "\\":
            escaped = True
        elif character in ("'", '"'):
            quote = character
        elif character == "#" and (
            index == 0 or line[index - 1].isspace() or line[index - 1] in ";|&()"
        ):
            return line[:index]
    return line


def _quote_state(text: str) -> str:
    quote = ""
    escaped = False
    for character in text:
        if escaped:
            escaped = False
            continue
        if quote == "'":
            if character == "'":
                quote = ""
        elif quote == '"':
            if character == "\\":
                escaped = True
            elif character == '"':
                quote = ""
        elif character == "\\":
            escaped = True
        elif character in ("'", '"'):
            quote = character
    return quote


def _continues_on_next_line(code: str) -> bool:
    if not code.endswith("\\"):
        return False
    trailing = len(code) - len(code.rstrip("\\"))
    return trailing % 2 == 1 and _quote_state(code[:-1]) != "'"


def logical_shell_lines(text: str) -> Tuple[List[LogicalLine], List[str]]:
    """Join valid backslash continuations and reject incomplete shell fragments."""
    lines: List[LogicalLine] = []
    errors: List[str] = []
    pending = ""
    pending_line = 0
    for number, raw_line in enumerate(text.splitlines(), start=1):
        code = _strip_shell_comment(raw_line)
        if not pending and not code.strip():
            continue
        if not pending:
            pending_line = number
        if _continues_on_next_line(code):
            pending += code[:-1] + " "
            continue
        logical = pending + code
        pending = ""
        if not logical.strip():
            continue
        try:
            shell_tokens(logical)
        except ValueError as error:
            errors.append(f"line {pending_line}: malformed shell syntax: {error}")
        else:
            lines.append((pending_line, logical))
    if pending:
        errors.append(f"line {pending_line}: dangling backslash continuation")
    return lines, errors


def shell_tokens(command: str) -> List[str]:
    lexer = shlex.shlex(
        command, posix=True, punctuation_chars=";&|(){}<>",
    )
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def _command_segments(tokens: Sequence[str]) -> List[List[str]]:
    segments: List[List[str]] = []
    current: List[str] = []
    for token in tokens:
        if token and set(token) <= set(";&|(){}"):
            if current:
                segments.append(current)
                current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments


def _has_same_line_close(code: str, close_word: str) -> bool:
    return bool(re.search(rf"(?:^|;)\s*{close_word}(?:\s*;|\s*$)", code))


def unconditional_shell_commands(
    lines: Sequence[LogicalLine], context: str
) -> Tuple[List[List[str]], List[str]]:
    """Extract commands guaranteed to run, skipping definitions/control bodies."""
    commands: List[List[str]] = []
    errors: List[str] = []
    stack: List[str] = []
    function_re = re.compile(
        r"^(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*(?:\(\s*\))?\s*\{"
    )
    for number, code in lines:
        stripped = code.strip()
        if function_re.match(stripped):
            if "}" not in stripped.split("{", 1)[1]:
                stack.append("function")
            continue
        if stripped == "}":
            if not stack or stack[-1] != "function":
                errors.append(f"{context} line {number}: unmatched function close")
            else:
                stack.pop()
            continue

        opener = ""
        closer = ""
        if re.match(r"^if(?:\s|\[)", stripped):
            opener, closer = "if", "fi"
        elif re.match(r"^case\s", stripped):
            opener, closer = "case", "esac"
        elif re.match(r"^(?:for|while|until|select)\s", stripped):
            opener, closer = "loop", "done"

        if opener:
            if not _has_same_line_close(stripped, closer):
                stack.append(opener)
            continue

        closing = {"fi": "if", "esac": "case", "done": "loop"}
        first = stripped.split(None, 1)[0].rstrip(";") if stripped else ""
        if first in closing:
            expected = closing[first]
            if not stack or stack[-1] != expected:
                errors.append(
                    f"{context} line {number}: unmatched {first} (expected {expected})"
                )
            else:
                stack.pop()
            continue
        if stack or first in {"then", "elif", "else", ";;", ";&", ";;&"}:
            continue

        try:
            tokens = shell_tokens(stripped)
        except ValueError as error:
            errors.append(f"{context} line {number}: {error}")
            continue
        segments = _command_segments(tokens)
        # A required lifecycle command must be a standalone unconditional
        # command, never one side of a pipeline/boolean/semicolon construct.
        if len(segments) == 1:
            commands.extend(segments)

    if stack:
        errors.append(f"{context}: unterminated structural blocks: {stack}")
    return commands, errors


def maintainer_path_commands(
    text: str, selected_arms: Sequence[str], script_name: str
) -> Tuple[List[List[str]], List[str]]:
    """Extract the unconditional Debian `$1` path without running the script."""
    lines, errors = logical_shell_lines(text)
    case_indices: List[int] = []
    for index, (_, code) in enumerate(lines):
        try:
            tokens = shell_tokens(code)
        except ValueError:
            continue
        if len(tokens) >= 3 and tokens[:3] == ["case", "$1", "in"]:
            case_indices.append(index)
    if len(case_indices) != 1:
        errors.append(
            f"{script_name}: expected one top-level case $1 path, found {len(case_indices)}"
        )
        return [], errors

    case_index = case_indices[0]
    before_commands, before_errors = unconditional_shell_commands(
        lines[:case_index], f"{script_name} pre-case"
    )
    errors.extend(before_errors)

    wanted = set(selected_arms)
    selected_lines: List[LogicalLine] = []
    depth = 1
    active = False
    found_arm = False
    found_esac = False
    for number, code in lines[case_index + 1 :]:
        stripped = code.strip()
        try:
            tokens = shell_tokens(stripped)
        except ValueError as error:
            errors.append(f"{script_name} line {number}: {error}")
            continue
        if tokens and tokens[0] == "case":
            if active:
                selected_lines.append((number, code))
            depth += 1
            continue
        if tokens and tokens[0].rstrip(";") == "esac":
            if depth > 1 and active:
                selected_lines.append((number, code))
            depth -= 1
            if depth == 0:
                found_esac = True
                break
            continue
        if depth == 1:
            arm_match = (
                re.fullmatch(r"([^=$()\s]+(?:\|[^=$()\s]+)*)\)\s*", stripped)
                if code == code.lstrip()
                else None
            )
            if arm_match:
                arm_names = {
                    item.strip().strip("'\"")
                    for item in arm_match.group(1).split("|")
                }
                active = bool(wanted & arm_names)
                found_arm = found_arm or active
                continue
            if stripped in {";;", ";&", ";;&"}:
                active = False
                continue
        if active:
            selected_lines.append((number, code))

    if not found_esac:
        errors.append(f"{script_name}: unterminated top-level case $1")
    if not found_arm:
        errors.append(
            f"{script_name}: missing selected case arm(s): {sorted(wanted)!r}"
        )
    arm_commands, arm_errors = unconditional_shell_commands(
        selected_lines, f"{script_name} selected path"
    )
    errors.extend(arm_errors)
    return before_commands + arm_commands, errors


def _customctl_errors(text: str) -> List[str]:
    lines, errors = logical_shell_lines(text)
    starts = [
        index
        for index, (_, code) in enumerate(lines)
        if re.match(r"^\s*customctl\s*\(\s*\)\s*\{", code)
    ]
    if len(starts) != 1:
        errors.append(f"customctl must have one definition; found {len(starts)}")
        return errors
    body: List[str] = []
    for _, code in lines[starts[0] + 1 :]:
        if code.strip() == "}":
            break
        body.append(code.strip())
    else:
        errors.append("customctl definition is unterminated")
        return errors

    compact = {re.sub(r"\s+", "", line) for line in body}
    if "target=$1" not in compact:
        errors.append("customctl must map its first argument to target")
    if "daemon_name=$2" not in compact:
        errors.append("customctl must map its second argument to daemon_name")

    branch_re = re.compile(
        r"^(?:if|elif)\s+\[\[\s+\$\{?target\}?\s*=\s*"
        r"(enable|disable|mask)\*\s+\]\];?\s*then$"
    )
    branches: Dict[str, List[List[str]]] = {}
    current = ""
    for line in body:
        match = branch_re.match(line)
        if match:
            current = match.group(1)
            branches[current] = []
            continue
        if re.match(r"^(?:elif|else|fi)\b", line):
            current = ""
            continue
        if current:
            if re.match(r"^(?:if|case|for|while|until|select)\b", line):
                errors.append(
                    f"customctl {current} branch has unsupported nested control flow"
                )
                continue
            try:
                segments = _command_segments(shell_tokens(line))
            except ValueError as error:
                errors.append(f"customctl {current} branch: {error}")
            else:
                if len(segments) == 1:
                    branches[current].extend(segments)

    daemon_args = {"$daemon_name", "${daemon_name}"}

    def has_command(branch: str, arguments: Sequence[str]) -> bool:
        return any(
            len(command) == len(arguments) + 2
            and Path(command[0]).name == "systemctl"
            and command[1 : 1 + len(arguments)] == list(arguments)
            and command[-1] in daemon_args
            for command in branches.get(branch, [])
        )

    if not has_command("enable", ("enable",)):
        errors.append("customctl enable branch must execute systemctl enable")
    if not has_command("disable", ("disable", "--now")):
        errors.append("customctl disable branch must execute systemctl disable --now")
    if any(
        len(command) >= 2
        and Path(command[0]).name == "systemctl"
        and command[1] == "mask"
        for command in branches.get("disable", [])
    ):
        errors.append("customctl disable branch must never resolve to mask")
    if not has_command("mask", ("disable", "--now")) or not has_command(
        "mask", ("mask",)
    ):
        errors.append("customctl mask branch must remain a distinct disable+mask path")
    return errors


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
    commands, errors = maintainer_path_commands(text, ("configure",), "postinst")
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
    errors.extend(_customctl_errors(text))
    return errors


def preinst_errors(text: str) -> List[str]:
    commands, errors = maintainer_path_commands(
        text, ("install", "upgrade"), "preinst"
    )
    cam = require_command(
        errors, commands, ("systemctl", "stop", "cam-operate.service")
    )
    sd_mount = require_command(
        errors, commands, ("systemctl", "stop", "sd-mount.service")
    )
    if cam >= 0 and sd_mount >= 0 and cam >= sd_mount:
        errors.append("cam-operate.service must stop before sd-mount.service")
    return errors


VARIABLE = re.compile(
    r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+)\}|"
    r"([A-Za-z_][A-Za-z0-9_]*|[0-9]+))"
)
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.DOTALL)
DIRECT_DESTRUCTIVE = {"rm", "rmdir", "unlink", "shred"}


def _resolve_shell_value(
    value: str, constants: Dict[str, str]
) -> Tuple[str, bool]:
    unresolved = bool("$(" in value or "`" in value)

    def replace(match: re.Match[str]) -> str:
        nonlocal unresolved
        name = match.group(1) or match.group(2)
        if name not in constants:
            unresolved = True
            return match.group(0)
        return constants[name]

    return VARIABLE.sub(replace, value), unresolved


def _is_protected_state(value: str) -> bool:
    normalized = value.rstrip("/")
    return (
        normalized == "/var/lib/pim-camera"
        or normalized.startswith("/var/lib/pim-camera/")
        or "service-state.json" in normalized
        or "recovery/history" in normalized
    )


def _target_is_unsafe(value: str, constants: Dict[str, str]) -> bool:
    resolved, unresolved = _resolve_shell_value(value, constants)
    return unresolved or _is_protected_state(resolved)


def _strip_command_prefix(tokens: Sequence[str]) -> List[str]:
    remaining = list(tokens)
    while remaining and remaining[0] in {
        "if",
        "then",
        "elif",
        "else",
        "do",
        "!",
        "time",
    }:
        remaining.pop(0)
    while remaining and remaining[0] in {"command", "builtin", "env"}:
        wrapper = remaining.pop(0)
        while remaining and (
            remaining[0].startswith("-")
            or (wrapper == "env" and ASSIGNMENT.match(remaining[0]))
        ):
            remaining.pop(0)
    return remaining


def _direct_targets_are_unsafe(
    arguments: Sequence[str], constants: Dict[str, str]
) -> bool:
    targets = [argument for argument in arguments if not argument.startswith("-")]
    return any(_target_is_unsafe(target, constants) for target in targets)


def _destructive_argv(
    argv: Sequence[str], constants: Dict[str, str], protected_pipeline: bool = False
) -> bool:
    command = _strip_command_prefix(argv)
    if not command:
        return False
    executable = Path(command[0]).name
    arguments = command[1:]

    if executable in DIRECT_DESTRUCTIVE:
        return protected_pipeline or _direct_targets_are_unsafe(arguments, constants)

    if executable == "truncate":
        zero_size = False
        targets: List[str] = []
        skip_next = False
        for index, argument in enumerate(arguments):
            if skip_next:
                skip_next = False
                continue
            if argument in {"-s", "--size"}:
                if index + 1 < len(arguments):
                    zero_size = arguments[index + 1] == "0"
                    skip_next = True
                continue
            if argument.startswith("--size="):
                zero_size = argument.split("=", 1)[1] == "0"
                continue
            if re.fullmatch(r"-s0", argument):
                zero_size = True
                continue
            if not argument.startswith("-"):
                targets.append(argument)
        return zero_size and any(
            _target_is_unsafe(target, constants) for target in targets
        )

    if executable == "dd":
        outputs = [argument[3:] for argument in arguments if argument.startswith("of=")]
        return any(_target_is_unsafe(output, constants) for output in outputs)

    if executable == "find":
        roots: List[str] = []
        for argument in arguments:
            if argument.startswith("-"):
                break
            roots.append(argument)
        root_unsafe = any(_target_is_unsafe(root, constants) for root in roots)
        if "-delete" in arguments:
            return root_unsafe
        for marker in ("-exec", "-execdir", "-ok", "-okdir"):
            if marker not in arguments:
                continue
            start = arguments.index(marker) + 1
            nested = arguments[start:]
            if _destructive_argv(nested, constants, protected_pipeline=root_unsafe):
                return True
        return False

    if executable == "xargs":
        destructive_index = next(
            (
                index
                for index, argument in enumerate(arguments)
                if Path(argument).name
                in DIRECT_DESTRUCTIVE | {"truncate", "dd"}
            ),
            -1,
        )
        if destructive_index >= 0:
            return _destructive_argv(
                arguments[destructive_index:],
                constants,
                protected_pipeline=protected_pipeline,
            )
    return False


def persistent_delete_lines(text: str) -> List[str]:
    """Return parsed destructive commands that can erase persistent state."""
    logical, parse_errors = logical_shell_lines(text)
    bad: List[str] = [f"parse error: {error}" for error in parse_errors]
    constants: Dict[str, str] = {}
    for _, code in logical:
        tokens = shell_tokens(code)
        segments = _command_segments(tokens)
        protected_pipeline = any(
            _is_protected_state(_resolve_shell_value(token, constants)[0])
            for token in tokens
        )
        unsafe = False
        for segment in segments:
            while segment:
                assignment = ASSIGNMENT.match(segment[0])
                if not assignment:
                    break
                name, value = assignment.groups()
                resolved, unresolved = _resolve_shell_value(value, constants)
                if not unresolved:
                    constants[name] = resolved
                segment = segment[1:]
            for index, token in enumerate(segment[:-1]):
                if token in {">", ">|"} and _target_is_unsafe(
                    segment[index + 1], constants
                ):
                    unsafe = True
            if _destructive_argv(
                segment, constants, protected_pipeline=protected_pipeline
            ):
                unsafe = True
        if unsafe and code.strip() not in bad:
            bad.append(code.strip())
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


def runner_contract_errors(text: str) -> List[str]:
    logical, errors = logical_shell_lines(text)
    commands, structure_errors = unconditional_shell_commands(
        logical, "camera-health runner"
    )
    errors.extend(structure_errors)
    expected = ["python3", "systemd_recovery_contract_test.py"]
    occurrences = sum(command == expected for command in commands)
    if occurrences != 1:
        errors.append(
            "run_all.sh must invoke active command "
            "'python3 systemd_recovery_contract_test.py' exactly once; "
            f"found {occurrences}"
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

    def test_camera_health_runner_invokes_this_contract_once(self) -> None:
        runner = (ROOT / "test/camera_health/run_all.sh").read_text(encoding="utf-8")
        self.assert_contract("camera-health runner", runner_contract_errors(runner))


GOOD_CUSTOMCTL = """\
customctl() {
  target=$1
  daemon_name=$2
  if [[ $target = enable* ]]; then
    systemctl enable $daemon_name
  elif [[ $target = disable* ]]; then
    systemctl disable --now $daemon_name
  elif [[ $target = mask* ]]; then
    systemctl disable --now $daemon_name
    systemctl mask $daemon_name
  fi
}
"""


def postinst_fixture(commands: str, customctl: str = GOOD_CUSTOMCTL) -> str:
    return f"""\
#!/bin/bash
{customctl}
case "$1" in
configure)
  ln -sf /opt/pim/bin/cam-recoveryctl /usr/local/bin/cam-recoveryctl
  ln -sf /opt/pim/bin/kill_test.sh /usr/local/bin/killcam
{commands}
  ;;
upgrade)
  :
  ;;
*)
  :
  ;;
esac
"""


GOOD_LIFECYCLE_COMMANDS = """\
  customctl enable pim-config-guard
  customctl enable pim-camera-config
  customctl disable ord-operate
  customctl enable cam-operate
"""


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

    def test_partof_propagation_is_rejected(self) -> None:
        fixture = """\
[Unit]
After=cam-operate.service
PartOf=cam-operate.service
[Service]
Type=simple
ExecStart=/usr/local/bin/ord
"""
        errors = ord_operate_errors(fixture)
        self.assertTrue(any("PartOf" in error for error in errors), errors)

    def test_after_without_requires_does_not_pull_cam(self) -> None:
        fixture = f"""\
[Unit]
After=cam-operate.service
ConditionPathExists={RUNTIME_JSON}
[Service]
ExecStart=/bin/true
"""
        errors = camera_consumer_errors(fixture, "standalone.service")
        self.assertTrue(any("Requires=" in error for error in errors), errors)

    def test_consumer_dependency_mutations_are_rejected(self) -> None:
        fixture = f"""\
[Unit]
Requires=cam-operate.service
After=cam-operate.service
ConditionPathExists={RUNTIME_JSON}
[Service]
ExecStart=/bin/true
"""
        self.assertEqual([], camera_consumer_errors(fixture, "consumer.service"))
        mutations = {
            "removed": fixture.replace("Requires=cam-operate.service\n", ""),
            "wrong path": fixture.replace(
                "Requires=cam-operate.service", "Requires=other.service"
            ),
            "wrong section": fixture.replace(
                "Requires=cam-operate.service\n", ""
            ).replace("[Service]\n", "[Service]\nRequires=cam-operate.service\n"),
        }
        for label, mutation in mutations.items():
            with self.subTest(mutation=label):
                errors = camera_consumer_errors(mutation, "consumer.service")
                self.assertTrue(any("Requires=" in error for error in errors), errors)

    def test_condition_reset_order_uses_effective_values(self) -> None:
        required_then_reset = f"""\
[Unit]
Requires=cam-operate.service
After=cam-operate.service
ConditionPathExists={RUNTIME_JSON}
ConditionPathExists=
[Service]
ExecStart=/bin/true
"""
        reset_then_required = f"""\
[Unit]
Requires=cam-operate.service
After=cam-operate.service
ConditionPathExists=
ConditionPathExists={RUNTIME_JSON}
[Service]
ExecStart=/bin/true
"""
        self.assertTrue(
            any(
                "ConditionPathExists=" in error
                for error in camera_consumer_errors(
                    required_then_reset, "reset-after.service"
                )
            )
        )
        self.assertEqual(
            [], camera_consumer_errors(reset_then_required, "reset-before.service")
        )

    def test_runtime_barrier_is_exact_and_bounded(self) -> None:
        fixture = f"""\
[Unit]
Requires=pim-camera-config.service
After=pim-camera-config.service sd-mount.service
[Service]
ExecStop=/opt/pim/bin/cam_operate_stop.sh
ExecStartPost={RUNTIME_BARRIER}
RuntimeDirectory=pim-camera
RuntimeDirectoryMode=0750
StateDirectory=pim-camera
StateDirectoryMode=0750
KillMode=control-group
TimeoutStartSec=90s
TimeoutStopSec=90s
Restart=on-failure
RestartSec=10s
"""
        self.assertEqual([], cam_operate_errors(fixture))
        mutations = {
            "missing barrier": fixture.replace(f"ExecStartPost={RUNTIME_BARRIER}\n", ""),
            "wrong validator": fixture.replace(RUNTIME_VALIDATOR, "/bin/true"),
            "wrong runtime": fixture.replace(RUNTIME_JSON, "/tmp/config/READY"),
            "unbounded start": fixture.replace("TimeoutStartSec=90s\n", ""),
            "infinite start": fixture.replace("TimeoutStartSec=90s", "TimeoutStartSec=infinity"),
            "wrong section": fixture.replace(
                f"[Service]\nExecStop=", f"ExecStartPost={RUNTIME_BARRIER}\n[Service]\nExecStop="
            ).replace(f"ExecStartPost={RUNTIME_BARRIER}\nRuntimeDirectory", "RuntimeDirectory"),
        }
        for label, mutation in mutations.items():
            with self.subTest(mutation=label):
                self.assertTrue(cam_operate_errors(mutation), label)

    def test_maintainer_command_reordering_is_rejected(self) -> None:
        fixture = postinst_fixture(
            """\
  customctl enable cam-operate
  customctl enable pim-config-guard
  customctl enable pim-camera-config
  customctl disable ord-operate
"""
        )
        errors = postinst_errors(fixture)
        self.assertTrue(any("lifecycle commands" in error for error in errors), errors)

    def test_never_called_function_does_not_satisfy_postinst(self) -> None:
        fixture = postinst_fixture(
            """\
  never_called() {
    customctl enable pim-config-guard
    customctl enable pim-camera-config
    customctl disable ord-operate
    customctl enable cam-operate
  }
"""
        )
        errors = postinst_errors(fixture)
        self.assertTrue(any("missing command: customctl" in error for error in errors), errors)

    def test_false_branch_does_not_satisfy_preinst(self) -> None:
        fixture = """\
#!/bin/bash
case "$1" in
install|upgrade)
  if false; then
    systemctl stop cam-operate.service
    systemctl stop sd-mount.service
  fi
  ;;
*)
  :
  ;;
esac
"""
        errors = preinst_errors(fixture)
        self.assertTrue(any("missing command" in error for error in errors), errors)

    def test_wrong_case_arm_does_not_satisfy_postinst(self) -> None:
        fixture = f"""\
#!/bin/bash
{GOOD_CUSTOMCTL}
case "$1" in
configure)
  ln -sf /opt/pim/bin/cam-recoveryctl /usr/local/bin/cam-recoveryctl
  ln -sf /opt/pim/bin/kill_test.sh /usr/local/bin/killcam
  ;;
upgrade)
{GOOD_LIFECYCLE_COMMANDS}
  ;;
esac
"""
        errors = postinst_errors(fixture)
        self.assertTrue(any("missing command: customctl" in error for error in errors), errors)

    def test_bad_customctl_disable_semantics_are_rejected(self) -> None:
        broken = GOOD_CUSTOMCTL.replace(
            "systemctl disable --now $daemon_name\n  elif [[ $target = mask*",
            "systemctl mask $daemon_name\n  elif [[ $target = mask*",
        )
        errors = postinst_errors(postinst_fixture(GOOD_LIFECYCLE_COMMANDS, broken))
        self.assertTrue(any("disable branch" in error for error in errors), errors)

    def test_quoted_lifecycle_decoys_are_rejected(self) -> None:
        decoys = """\
  echo 'customctl enable pim-config-guard'
  echo 'customctl enable pim-camera-config'
  echo 'customctl disable ord-operate'
  echo 'customctl enable cam-operate'
"""
        errors = postinst_errors(postinst_fixture(decoys))
        self.assertTrue(any("missing command: customctl" in error for error in errors), errors)

    def test_valid_lifecycle_continuations_are_joined(self) -> None:
        continued = (
            "  customctl enable \\\n    pim-config-guard\n"
            "  customctl enable \\\n    pim-camera-config\n"
            "  customctl disable \\\n    ord-operate\n"
            "  customctl enable \\\n    cam-operate\n"
        )
        self.assertEqual([], postinst_errors(postinst_fixture(continued)))

    def test_malformed_lifecycle_continuation_is_rejected(self) -> None:
        malformed = GOOD_LIFECYCLE_COMMANDS.replace(
            "customctl enable pim-config-guard",
            "customctl enable \\ \n    pim-config-guard",
        )
        errors = postinst_errors(postinst_fixture(malformed))
        self.assertTrue(any("pim-config-guard" in error for error in errors), errors)

    def test_persistent_history_delete_is_rejected(self) -> None:
        fixture = """\
# rm -rf /var/lib/pim-camera is documentation, not behavior
rm -rf /var/lib/pim-camera/recovery/history
"""
        self.assertEqual(
            ["rm -rf /var/lib/pim-camera/recovery/history"],
            persistent_delete_lines(fixture),
        )

    def test_reviewer_exact_persistent_deletions_are_rejected(self) -> None:
        cases = {
            "absolute rm": "/bin/rm -rf /var/lib/pim-camera/recovery/history\n",
            "if prefix": "if rm -rf /var/lib/pim-camera/recovery/history; then :; fi\n",
            "constant target": (
                "state=/var/lib/pim-camera/recovery/history\nrm -rf \"$state\"\n"
            ),
            "continuation target": (
                "rm -rf \\\n  /var/lib/pim-camera/recovery/history\n"
            ),
            "truncate": "truncate -s 0 /var/lib/pim-camera/service-state.json\n",
        }
        for label, fixture in cases.items():
            with self.subTest(case=label):
                self.assertTrue(persistent_delete_lines(fixture), label)

    def test_additional_persistent_destructive_forms_are_rejected(self) -> None:
        cases = {
            "rmdir": "rmdir /var/lib/pim-camera/recovery/history\n",
            "unlink": "unlink /var/lib/pim-camera/service-state.json\n",
            "shred": "shred /var/lib/pim-camera/service-state.json\n",
            "dd": "dd if=/dev/zero of=/var/lib/pim-camera/service-state.json\n",
            "find delete": "find /var/lib/pim-camera -type f -delete\n",
            "find exec": (
                "find /var/lib/pim-camera -type f -exec /bin/rm -f '{}' \\;\n"
            ),
            "xargs rm": (
                "find /var/lib/pim-camera -type f -print0 | xargs -0 rm -f\n"
            ),
            "truncate redirect": ": > /var/lib/pim-camera/service-state.json\n",
        }
        for label, fixture in cases.items():
            with self.subTest(case=label):
                self.assertTrue(persistent_delete_lines(fixture), label)

    def test_harmless_find_and_logged_deletion_text_are_allowed(self) -> None:
        fixture = """\
find /var/lib/pim-camera -type f -print
echo 'rm -rf /var/lib/pim-camera/recovery/history'
logger "truncate -s 0 /var/lib/pim-camera/service-state.json"
state=/tmp/cache
rm -rf "$state"
"""
        self.assertEqual([], persistent_delete_lines(fixture))

    def test_unresolved_destructive_target_fails_closed(self) -> None:
        bad = persistent_delete_lines('rm -rf "$unknown_state"\n')
        self.assertTrue(bad, "unresolved destructive target must fail closed")

    def test_runner_missing_duplicate_decoy_and_dead_variants_are_rejected(self) -> None:
        active = "python3 systemd_recovery_contract_test.py\n"
        self.assertEqual([], runner_contract_errors("#!/bin/bash\n" + active))
        cases = {
            "missing": "#!/bin/bash\npython3 schema_test.py\n",
            "duplicate": "#!/bin/bash\n" + active + active,
            "commented": "#!/bin/bash\n# " + active,
            "quoted": "#!/bin/bash\necho 'python3 systemd_recovery_contract_test.py'\n",
            "dead if": (
                "#!/bin/bash\nif false; then\n" + active + "fi\n"
            ),
            "dead function": (
                "#!/bin/bash\nnever_called() {\n" + active + "}\n"
            ),
            "malformed": "#!/bin/bash\npython3 \\",
        }
        for label, fixture in cases.items():
            with self.subTest(case=label):
                self.assertTrue(runner_contract_errors(fixture), label)


if __name__ == "__main__":
    unittest.main(verbosity=2)
