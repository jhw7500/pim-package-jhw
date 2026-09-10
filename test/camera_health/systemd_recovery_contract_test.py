#!/usr/bin/env python3
"""Contract tests for camera recovery systemd and Debian integration."""

from __future__ import annotations

import re
import shlex
import subprocess
import unittest
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = ROOT / "dist/pim"
UNIT_ROOT = PACKAGE_ROOT / "etc/systemd/system"
DEBIAN_ROOT = PACKAGE_ROOT / "DEBIAN"
RUNTIME_JSON = "/run/pim-camera/config/pim_runtime.json"
RUNTIME_VALIDATOR = "/opt/pim/bin/camera_runtime_config.py"
STOP_TERM_DEADLINE_SECONDS = 75
STOP_KILL_GRACE_SECONDS = 5
STOP_EXEC = (
    "/usr/bin/timeout --signal=TERM "
    f"--kill-after={STOP_KILL_GRACE_SECONDS}s {STOP_TERM_DEADLINE_SECONDS}s "
    "/opt/pim/bin/cam_operate_stop.sh --systemd"
)
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


def effective_scalar(sections: Sections, section: str, key: str) -> str | None:
    actual = values(sections, section, key)
    return actual[-1] if actual else None


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


def duration_seconds(value: str) -> int | None:
    match = re.fullmatch(r"([0-9]+)s", value)
    return int(match.group(1)) if match else None


def stop_budget_errors(sections: Sections) -> List[str]:
    errors: List[str] = []
    actual = values(sections, "Service", "ExecStop")
    if len(actual) != 1:
        return errors
    try:
        tokens = shlex.split(actual[0])
    except ValueError:
        return ["[Service] ExecStop= stop budget command is malformed"]
    if len(tokens) != 6 or tokens[0] != "/usr/bin/timeout":
        return ["[Service] ExecStop= must use one bounded timeout supervisor"]
    if tokens[1] != "--signal=TERM" or not tokens[2].startswith("--kill-after="):
        return ["[Service] ExecStop= timeout signal/kill grace is not exact"]
    grace = duration_seconds(tokens[2].split("=", 1)[1])
    deadline = duration_seconds(tokens[3])
    service_timeout = duration_seconds(
        effective_scalar(sections, "Service", "TimeoutStopSec") or ""
    )
    if grace is None or deadline is None or service_timeout is None:
        errors.append("[Service] ExecStop= stop budget durations must be seconds")
    elif deadline + grace >= service_timeout:
        errors.append(
            "[Service] ExecStop= stop budget must finish before TimeoutStopSec"
        )
    if tokens[4:] != ["/opt/pim/bin/cam_operate_stop.sh", "--systemd"]:
        errors.append("[Service] ExecStop= timeout must supervise the systemd stop route")
    return errors


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
        "SuccessExitStatus": "143",
    }
    for key, value in expected.items():
        require_single(errors, sections, "Service", key, value)
    require_single(
        errors,
        sections,
        "Service",
        "ExecStop",
        STOP_EXEC,
    )
    errors.extend(stop_budget_errors(sections))
    require_single(errors, sections, "Service", "ExecStartPost", RUNTIME_BARRIER)
    service_type = effective_scalar(sections, "Service", "Type")
    if service_type is not None and service_type != "simple":
        errors.append(
            "[Service] effective Type= must be absent/default or 'simple'; "
            f"found {service_type!r}"
        )
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
    true_values = {"1", "yes", "true", "on", "y", "t"}
    false_values = {"0", "no", "false", "off", "n", "f"}
    for key, action in (
        ("RefuseManualStart", "startable"),
        ("RefuseManualStop", "stoppable"),
    ):
        value = effective_scalar(sections, "Unit", key)
        if value is None:
            continue
        normalized = value.lower()
        if normalized in true_values:
            errors.append(f"manual executor must remain manually {action}")
        elif normalized not in false_values:
            errors.append(
                f"[Unit] effective {key}= has unrecognized boolean {value!r}"
            )
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
    split_function_re = re.compile(
        r"^(?:function\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*\(\s*\))?"
        r"|[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\))\s*$"
    )
    pending_function_line = 0
    for number, code in lines:
        stripped = code.strip()
        if pending_function_line:
            if stripped == "{":
                stack.append("function")
                pending_function_line = 0
                continue
            errors.append(
                f"{context} line {pending_function_line}: "
                "split function declaration is not followed by '{'"
            )
            pending_function_line = 0
        function_match = function_re.match(stripped)
        if function_match:
            stack.append("function")
            remainder = stripped[function_match.end() :].strip()
            if remainder == 'logger -s -p local0.notice "[$KEY][$tag:$LINENO] $*"; }':
                stack.pop()
            elif remainder:
                errors.append(
                    f"{context} line {number}: function opening '{{' must be final"
                )
            continue
        if split_function_re.match(stripped):
            pending_function_line = number
            continue
        if stripped == "{":
            errors.append(f"{context} line {number}: unmatched function open")
            continue
        if stripped == "}":
            if not stack or stack[-1] != "function":
                errors.append(f"{context} line {number}: unmatched function close")
            else:
                stack.pop()
            continue
        if (
            stack
            and stack[-1] == "function"
            and re.search(r"(?:^|;)\s*}\s*$", stripped)
        ):
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

    if pending_function_line:
        errors.append(
            f"{context} line {pending_function_line}: "
            "split function declaration is not followed by '{'"
        )
    if stack:
        errors.append(f"{context}: unterminated structural blocks: {stack}")
    return commands, errors


def _simple_case_match(pattern: str, value: str) -> bool | None:
    if not pattern or re.search(r"[\\'\"$()\s]", pattern):
        return None
    index = 0
    while index < len(pattern):
        if pattern[index] == "[":
            close = pattern.find("]", index + 1)
            if close < index + 2 or "[" in pattern[index + 1 : close]:
                return None
            index = close
        elif pattern[index] == "]":
            return None
        index += 1
    return fnmatchcase(value, pattern)


def maintainer_path_commands(
    text: str, selected_arg: str, script_name: str
) -> Tuple[List[List[str]], List[str]]:
    """Extract the unconditional Debian `$1` path without running the script."""
    lines, errors = logical_shell_lines(text)
    case_indices: List[int] = []
    for index, (_, code) in enumerate(lines):
        try:
            tokens = [_plain_quotes(token) for token in provenance_tokens(code)]
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

    selected_lines: List[LogicalLine] = []
    depth = 1
    active = False
    selected = False
    expecting_arm = True
    found_esac = False
    for number, code in lines[case_index + 1 :]:
        stripped = code.strip()
        try:
            tokens = provenance_tokens(stripped)
        except ValueError as error:
            errors.append(f"{script_name} line {number}: {error}")
            continue
        plain_tokens = [_plain_quotes(token) for token in tokens]
        if plain_tokens and plain_tokens[0] == "case":
            if active:
                selected_lines.append((number, code))
            depth += 1
            continue
        if plain_tokens and plain_tokens[0].rstrip(";") == "esac":
            if depth > 1 and active:
                selected_lines.append((number, code))
            depth -= 1
            if depth == 0:
                found_esac = True
                break
            continue
        if depth == 1:
            if expecting_arm:
                arm_match = re.fullmatch(r"(.+)\)\s*(.*)", stripped)
                if not arm_match:
                    errors.append(f"{script_name} line {number}: expected case arm")
                    continue
                matches = [
                    _simple_case_match(pattern, selected_arg)
                    for pattern in arm_match.group(1).split("|")
                ]
                if None in matches:
                    errors.append(f"{script_name} line {number}: unsupported case pattern")
                active = None not in matches and any(matches) and not selected
                selected = selected or (None not in matches and any(matches))
                terminator = tokens[-1] if tokens[-1] in {";;", ";&", ";;&"} else ""
                if terminator and terminator != ";;":
                    errors.append(f"{script_name} line {number}: unsupported fall-through")
                if active and arm_match.group(2):
                    selected_lines.append((number, arm_match.group(2)))
                expecting_arm = bool(terminator)
                active = active and not expecting_arm
                continue
            terminator = tokens[-1] if tokens[-1] in {";;", ";&", ";;&"} else ""
            if active:
                selected_lines.append((number, code))
            if terminator:
                if terminator != ";;":
                    errors.append(f"{script_name} line {number}: unsupported fall-through")
                active, expecting_arm = False, True
            continue
        if active:
            selected_lines.append((number, code))

    if not found_esac:
        errors.append(f"{script_name}: unterminated top-level case $1")
    if not selected:
        errors.append(f"{script_name}: missing case path for {selected_arg!r}")
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

    mapping = ["target=$1", "daemon_name=$2"]
    chain = [
        "if [[ $target = enable* ]]; then",
        "systemctl enable $daemon_name",
        "elif [[ $target = disable* ]]; then",
        "systemctl disable --now $daemon_name",
        "elif [[ $target = mask* ]]; then",
        "systemctl disable --now $daemon_name",
        "systemctl mask $daemon_name",
    ]
    simple = mapping + chain + ["fi"]
    status = "status=$(systemctl is-enabled $daemon_name 2>/dev/null)"
    packaged = (
        mapping
        + [status, "if [[ $status != ${target}* ]]; then"]
        + chain
        + ['else', 'echo "$target is wrong status"', "return 1", "fi", "fi"]
        + [status, 'echo "$daemon_name is $status"']
    )
    if body not in (simple, packaged):
        errors.append(
            "customctl enable/disable branch helper must match an approved complete shape"
        )
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
    commands, errors = maintainer_path_commands(text, "configure", "postinst")
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
    errors: List[str] = []
    for argument in ("install", "upgrade"):
        commands, path_errors = maintainer_path_commands(text, argument, "preinst")
        errors.extend(path_errors)
        cam = require_command(
            errors, commands, ("systemctl", "stop", "cam-operate.service")
        )
        sd_mount = require_command(
            errors, commands, ("systemctl", "stop", "sd-mount.service")
        )
        if cam >= 0 and sd_mount >= 0 and cam >= sd_mount:
            errors.append(
                f"{argument}: cam-operate.service must stop before sd-mount.service"
            )
    return errors


VARIABLE = re.compile(
    r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+)\}|"
    r"([A-Za-z_][A-Za-z0-9_]*|[0-9]+))"
)
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.DOTALL)
DIRECT_DESTRUCTIVE = {"rm", "rmdir", "unlink", "shred"}
SHELL_LITERAL = dict(zip("$`*?[];&|(){}<>", map(chr, range(0xE000, 0xE00F))))
SHELL_UNMASK = str.maketrans({marker: value for value, marker in SHELL_LITERAL.items()})
DOUBLE_QUOTE = "\ue020"


def _mask_shell_provenance(text: str) -> str:
    """Keep bounded quoted/escaped shell syntax distinguishable after shlex."""
    result: List[str] = []
    quote = ""
    index = 0
    while index < len(text):
        character = text[index]
        if character == "'" and quote != '"':
            quote = "" if quote == "'" else "'"
        elif character == '"' and quote != "'":
            if quote == '"':
                result.append(character)
                result.append(DOUBLE_QUOTE)
                quote = ""
            else:
                result.append(DOUBLE_QUOTE)
                result.append(character)
                quote = '"'
            index += 1
            continue
        if character == "\\" and quote != "'" and index + 1 < len(text):
            escaped = text[index + 1]
            if escaped in SHELL_LITERAL:
                result.append(SHELL_LITERAL[escaped])
            else:
                result.extend((character, escaped))
            index += 2
            continue
        literal = quote == "'" or (quote == '"' and character in "*?[]")
        result.append(SHELL_LITERAL.get(character, character) if literal else character)
        index += 1
    return "".join(result)


def provenance_tokens(command: str) -> List[str]:
    return shell_tokens(_mask_shell_provenance(command))


def _plain_quotes(value: str) -> str:
    return value.replace(DOUBLE_QUOTE, "")


def _resolve_shell_value(
    value: str, constants: Dict[str, str], assignment: bool = False
) -> Tuple[str, bool]:
    unresolved = bool("$(" in value or "`" in value)

    def replace(match: re.Match[str]) -> str:
        nonlocal unresolved
        name = match.group(1) or match.group(2)
        if name not in constants:
            unresolved = True
            return match.group(0)
        quoted = value[: match.start()].count(DOUBLE_QUOTE) % 2 == 1
        literal = "$`;&|(){}<>" + ("*?[]" if assignment or quoted else "")
        return "".join(SHELL_LITERAL.get(char, char) if char in literal else char
                       for char in constants[name])

    resolved = _plain_quotes(VARIABLE.sub(replace, value))
    if "$" in resolved or "`" in resolved:
        unresolved = True
    return resolved, unresolved


def _is_protected_state(value: str) -> bool:
    normalized = re.sub(r"/+", "/", value).rstrip("/")
    root = "/var/lib/pim-camera"
    parts = normalized.strip("/").split("/")
    root_match = len(parts) >= 3 and _simple_case_match(
        "/".join(parts[:3]), root[1:]
    )
    return (
        root_match is True
        or (root_match is None and normalized.startswith("/var/lib/")
            and any(marker in normalized for marker in "*?["))
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
    while remaining and remaining[0] in {"command", "builtin", "env", "exec"}:
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
        root_index = 0
        while root_index < len(arguments) and arguments[root_index] in {
            "-H",
            "-L",
            "-P",
        }:
            root_index += 1
        ambiguous_root = False
        if root_index < len(arguments) and arguments[root_index] == "--":
            root_index += 1
        elif root_index < len(arguments) and arguments[root_index].startswith("-"):
            ambiguous_root = True
        for argument in arguments[root_index:]:
            if argument.startswith("-"):
                break
            roots.append(argument)
        root_unsafe = any(_target_is_unsafe(root, constants) for root in roots)
        path_unsafe = any(
            index + 1 >= len(arguments)
            or _target_is_unsafe(arguments[index + 1], constants)
            for index, argument in enumerate(arguments)
            if argument in {"-path", "-ipath", "-wholename", "-iwholename"}
        )
        input_unsafe = protected_pipeline or root_unsafe or path_unsafe
        if "-delete" in arguments:
            return ambiguous_root or not roots or input_unsafe
        for marker in ("-exec", "-execdir", "-ok", "-okdir"):
            if marker not in arguments:
                continue
            start = arguments.index(marker) + 1
            nested = arguments[start:]
            command = _strip_command_prefix(nested)
            supported = DIRECT_DESTRUCTIVE | {"truncate", "dd"}
            if input_unsafe and (
                not command or Path(command[0]).name not in supported
            ):
                return True
            if _destructive_argv(nested, constants, protected_pipeline=input_unsafe):
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
        return protected_pipeline
    return False


def persistent_delete_lines(text: str) -> List[str]:
    """Return parsed destructive commands that can erase persistent state."""
    logical, parse_errors = logical_shell_lines(text)
    bad: List[str] = [f"parse error: {error}" for error in parse_errors]
    constants: Dict[str, str] = {}
    for _, code in logical:
        tokens = provenance_tokens(code)
        pipelines: List[List[str]] = [[]]
        for token in tokens:
            if token in {";", "&&", "||", "&", "(", ")", "{", "}", ";&", ";;&"}:
                pipelines.append([])
            else:
                pipelines[-1].append(token)
        unsafe = False
        for pipeline in pipelines:
            protected_pipeline = any(
                _target_is_unsafe(token, constants) for token in pipeline
            )
            for segment in _command_segments(pipeline):
                while segment:
                    assignment = ASSIGNMENT.match(segment[0])
                    if not assignment:
                        break
                    name, value = assignment.groups()
                    resolved, unresolved = _resolve_shell_value(
                        value, constants, assignment=True
                    )
                    if not unresolved:
                        constants[name] = resolved.translate(SHELL_UNMASK)
                    else:
                        constants.pop(name, None)
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
SuccessExitStatus=143
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
ExecStop={STOP_EXEC}
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
SuccessExitStatus=143
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

    def test_coordinated_stop_exit_status_is_exact(self) -> None:
        unit = read(Path("etc/systemd/system/cam-operate.service"))
        unit = re.sub(r"^SuccessExitStatus=.*\n", "", unit, flags=re.MULTILINE)
        unit = re.sub(r"^ExecStop=.*\n", "", unit, flags=re.MULTILINE)
        fixture = unit.replace(
            "[Service]\n",
            "[Service]\n"
            f"ExecStop={STOP_EXEC}\n"
            "SuccessExitStatus=143\n",
            1,
        )
        self.assertEqual([], cam_operate_errors(fixture))
        status = "SuccessExitStatus=143\n"
        status_mutations = {
            "removed": fixture.replace(status, "", 1),
            "adds 75": fixture.replace(status, "SuccessExitStatus=75 143\n", 1),
            "removes 143": fixture.replace(status, "SuccessExitStatus=75\n", 1),
            "duplicate": fixture.replace(status, status + status, 1),
            "reset": fixture.replace(status, status + "SuccessExitStatus=\n", 1),
            "wrong section": fixture.replace(status, "", 1).replace(
                "[Unit]\n", "[Unit]\n" + status, 1
            ),
        }
        for label, mutation in status_mutations.items():
            with self.subTest(mutation=label):
                errors = cam_operate_errors(mutation)
                self.assertTrue(
                    any("[Service] SuccessExitStatus=" in error for error in errors),
                    (label, errors),
                )

        exec_stop = f"ExecStop={STOP_EXEC}\n"
        exec_mutations = {
            "removes timeout supervisor": fixture.replace(
                exec_stop,
                "ExecStop=/opt/pim/bin/cam_operate_stop.sh --systemd\n",
                1,
            ),
            "loses systemd": fixture.replace(
                exec_stop, "ExecStop=/opt/pim/bin/cam_operate_stop.sh\n", 1
            ),
            "wrong timeout path": fixture.replace(
                "/usr/bin/timeout", "/bin/true", 1
            ),
            "missing kill grace": fixture.replace("--kill-after=5s ", "", 1),
            "timeout after command": fixture.replace(
                STOP_EXEC,
                "/opt/pim/bin/cam_operate_stop.sh --systemd "
                "/usr/bin/timeout --signal=TERM --kill-after=5s 75s",
                1,
            ),
            "duplicate": fixture.replace(exec_stop, exec_stop + exec_stop, 1),
            "reset": fixture.replace(exec_stop, exec_stop + "ExecStop=\n", 1),
            "wrong section": fixture.replace(exec_stop, "", 1).replace(
                "[Unit]\n", "[Unit]\n" + exec_stop, 1
            ),
        }
        for label, mutation in exec_mutations.items():
            with self.subTest(mutation=label):
                errors = cam_operate_errors(mutation)
                self.assertTrue(
                    any("[Service] ExecStop=" in error for error in errors),
                    (label, errors),
                )

        budget_mutations = {
            "deadline plus grace equals service timeout": fixture.replace(
                " 75s /opt/pim/bin/cam_operate_stop.sh",
                " 85s /opt/pim/bin/cam_operate_stop.sh",
                1,
            ),
            "kill grace reaches service timeout": fixture.replace(
                "--kill-after=5s", "--kill-after=15s", 1
            ),
            "service timeout equals stop budget": fixture.replace(
                "TimeoutStopSec=90s", "TimeoutStopSec=80s", 1
            ),
        }
        for label, mutation in budget_mutations.items():
            with self.subTest(mutation=label):
                errors = cam_operate_errors(mutation)
                self.assertTrue(
                    any("stop budget must finish" in error for error in errors),
                    (label, errors),
                )

    def test_timeout_supervisor_preserves_status_and_expires(self) -> None:
        for status in (0, 69, 70, 75, 143):
            with self.subTest(status=status):
                completed = subprocess.run(
                    [
                        "/usr/bin/timeout",
                        "--signal=TERM",
                        "--kill-after=1s",
                        "2s",
                        "/bin/sh",
                        "-c",
                        f"exit {status}",
                    ],
                    check=False,
                )
                self.assertEqual(status, completed.returncode)
        expired = subprocess.run(
            [
                "/usr/bin/timeout",
                "--signal=TERM",
                "--kill-after=0.2s",
                "0.1s",
                "/bin/sh",
                "-c",
                "sleep 5",
            ],
            check=False,
            timeout=2,
        )
        self.assertEqual(124, expired.returncode)

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


class RoundTwoReviewerCounterexamples(unittest.TestCase):
    """Exact bypasses from the fix-round-1 scoped re-review."""

    def test_persistent_deletion_bypasses_are_rejected(self) -> None:
        cases = {
            "special parameter": 'rm -rf "$@"\n',
            "parameter default": (
                'rm -rf "${unknown_state:-/var/lib/pim-camera}"\n'
            ),
            "unresolved overwrite": (
                "state=/tmp/cache\n"
                'state="$(printf /var/lib/pim-camera)"\n'
                'rm -rf "$state"\n'
            ),
            "exec prefix": (
                "exec /bin/rm -rf /var/lib/pim-camera/recovery/history\n"
            ),
            "find global option": "find -H /var/lib/pim-camera -delete\n",
            "find option terminator": "find -- /var/lib/pim-camera -delete\n",
        }
        survivors = [
            label
            for label, fixture in cases.items()
            if not persistent_delete_lines(fixture)
        ]
        self.assertEqual([], survivors, f"persistent deletion bypasses: {survivors}")

    def test_unreachable_lifecycle_bypasses_are_rejected(self) -> None:
        duplicate_postinst = f"""\
#!/bin/bash
{GOOD_CUSTOMCTL}case "$1" in
configure)
  ln -sf /opt/pim/bin/cam-recoveryctl /usr/local/bin/cam-recoveryctl
  ln -sf /opt/pim/bin/kill_test.sh /usr/local/bin/killcam
  :
  ;;
configure)
{GOOD_LIFECYCLE_COMMANDS}  ;;
*)
  :
  ;;
esac
"""
        split_function_postinst = postinst_fixture(
            """\
  never_called ()
  {
    customctl enable pim-config-guard
    customctl enable pim-camera-config
    customctl disable ord-operate
    customctl enable cam-operate
    :; }
"""
        )
        duplicate_preinst = """\
#!/bin/bash
case "$1" in
install|upgrade)
  :
  ;;
install|upgrade)
  systemctl stop cam-operate.service
  systemctl stop sd-mount.service
  ;;
*)
  :
  ;;
esac
"""
        duplicate_disable = GOOD_CUSTOMCTL.replace(
            "elif [[ $target = disable* ]]; then\n"
            "    systemctl disable --now $daemon_name\n",
            "elif [[ $target = disable* ]]; then\n"
            "    systemctl mask $daemon_name\n"
            "  elif [[ $target = disable* ]]; then\n"
            "    systemctl disable --now $daemon_name\n",
        )
        cases = {
            "duplicate configure": postinst_errors(duplicate_postinst),
            "split-brace function": postinst_errors(split_function_postinst),
            "duplicate install-upgrade": preinst_errors(duplicate_preinst),
            "duplicate customctl disable": postinst_errors(
                postinst_fixture(GOOD_LIFECYCLE_COMMANDS, duplicate_disable)
            ),
        }
        survivors = [label for label, errors in cases.items() if not errors]
        self.assertEqual([], survivors, f"unreachable lifecycle bypasses: {survivors}")

    def test_split_brace_runner_bypass_is_rejected(self) -> None:
        fixture = """\
#!/bin/bash
never_called ()
{
  python3 systemd_recovery_contract_test.py
  :; }
"""
        self.assertTrue(
            runner_contract_errors(fixture),
            "split-brace never-called function counted as an active runner command",
        )

    def test_non_simple_cam_service_types_are_rejected(self) -> None:
        unit = read(Path("etc/systemd/system/cam-operate.service"))
        unit = re.sub(r"^SuccessExitStatus=.*\n", "", unit, flags=re.MULTILINE)
        unit = re.sub(r"^ExecStop=.*\n", "", unit, flags=re.MULTILINE)
        unit = unit.replace(
            "[Service]\n",
            "[Service]\n"
            f"ExecStop={STOP_EXEC}\n"
            "SuccessExitStatus=143\n",
            1,
        )
        mutations = {
            service_type: unit.replace(
                "[Service]\n", f"[Service]\nType={service_type}\n", 1
            )
            for service_type in ("oneshot", "notify", "forking", "unknown")
        }
        mutations["effective duplicate"] = unit.replace(
            "[Service]\n", "[Service]\nType=simple\nType=notify\n", 1
        )
        survivors = [
            label
            for label, mutation in mutations.items()
            if not cam_operate_errors(mutation)
        ]
        self.assertEqual([], survivors, f"non-simple Type bypasses: {survivors}")
        simple_last = unit.replace(
            "[Service]\n", "[Service]\nType=notify\nType=simple\n", 1
        )
        self.assertEqual([], cam_operate_errors(simple_last))

    def test_ord_manual_control_boolean_bypasses_are_rejected(self) -> None:
        unit = read(Path("etc/systemd/system/ord-operate.service"))

        def with_directives(*directives: str) -> str:
            return unit.replace(
                "[Unit]\n", "[Unit]\n" + "\n".join(directives) + "\n", 1
            )

        mutations = {
            "start true": with_directives("RefuseManualStart=true"),
            "start on": with_directives("RefuseManualStart=on"),
            "start one": with_directives("RefuseManualStart=1"),
            "start mixed case": with_directives("RefuseManualStart=TRUE"),
            "stop true": with_directives("RefuseManualStop=true"),
            "unknown start": with_directives("RefuseManualStart=maybe"),
            "effective true": with_directives(
                "RefuseManualStart=false", "RefuseManualStart=TRUE"
            ),
        }
        survivors = [
            label
            for label, mutation in mutations.items()
            if not ord_operate_errors(mutation)
        ]
        self.assertEqual([], survivors, f"manual-control boolean bypasses: {survivors}")
        for false_value in ("no", "false", "off", "0"):
            with self.subTest(false_value=false_value):
                self.assertEqual(
                    [],
                    ord_operate_errors(
                        with_directives(
                            f"RefuseManualStart={false_value}",
                            f"RefuseManualStop={false_value.upper()}",
                        )
                    ),
                )
        self.assertEqual(
            [],
            ord_operate_errors(
                with_directives(
                    "RefuseManualStart=true", "RefuseManualStart=false"
                )
            ),
        )


class RoundThreeReviewerCounterexamples(unittest.TestCase):
    def test_outer_case_uses_first_matching_pattern_per_argument(self) -> None:
        template = f"""\
#!/bin/bash
{GOOD_CUSTOMCTL}case "$1" in
BLOCKER)
  :
  ;;
configure)
  ln -sf /opt/pim/bin/cam-recoveryctl /usr/local/bin/cam-recoveryctl
  ln -sf /opt/pim/bin/kill_test.sh /usr/local/bin/killcam
{GOOD_LIFECYCLE_COMMANDS}  ;;
esac
"""
        bad = {
            pattern: postinst_errors(template.replace("BLOCKER", pattern, 1))
            for pattern in ("*", "config*", "configur?", r"config\ ure")
        }
        bad["preinst wildcard"] = preinst_errors("""\
#!/bin/bash
case "$1" in
*) : ;;
install|upgrade)
  systemctl stop cam-operate.service
  systemctl stop sd-mount.service
  ;;
esac
""")
        disjoint = (
            '#!/bin/bash\ncase "$1" in\ninstall)\n'
            "  systemctl stop cam-operate.service\n  systemctl stop sd-mount.service\n  ;;\n"
            "upgrade)\n  systemctl stop cam-operate.service\n"
            "  systemctl stop sd-mount.service\n  ;;\nesac\n"
        )
        observed = [label for label, errors in bad.items() if not errors]
        self.assertEqual(([], []), (observed, preinst_errors(disjoint)))

    def test_customctl_rejects_dominating_or_dead_shape(self) -> None:
        prefix = "  target=$1\n  daemon_name=$2\n"
        enable = "  if [[ $target = enable* ]]; then"
        mutants = {
            "leading catch-all": GOOD_CUSTOMCTL.replace(
                enable,
                "  if [[ -n $target ]]; then\n    systemctl mask $daemon_name\n"
                "  elif [[ $target = enable* ]]; then",
            ),
            "target reassignment": GOOD_CUSTOMCTL.replace(
                prefix, prefix + "  target=never\n"
            ),
            "dead mappings": GOOD_CUSTOMCTL.replace(
                prefix, "  if false; then\n    target=$1\n    daemon_name=$2\n  fi\n"
            ),
            "bracket override": GOOD_CUSTOMCTL.replace(
                "  elif [[ $target = disable* ]]; then",
                "  elif [[ $target = disabl[e]* ]]; then\n"
                "    systemctl mask $daemon_name\n"
                "  elif [[ $target = disable* ]]; then",
            ),
        }
        survivors = [label for label, helper in mutants.items() if not postinst_errors(
            postinst_fixture(GOOD_LIFECYCLE_COMMANDS, helper))]
        self.assertEqual([], survivors, f"customctl shape bypasses: {survivors}")

    def test_inline_function_body_cannot_expose_dead_commands(self) -> None:
        lifecycle = postinst_fixture("""\
  never_called() { echo '}'
    customctl enable pim-config-guard
    customctl enable pim-camera-config
    customctl disable ord-operate
    customctl enable cam-operate
    :; }
""")
        runner = """\
#!/bin/bash
never_called() { echo '}'
  python3 systemd_recovery_contract_test.py
  :; }
"""
        cases = (("lifecycle", postinst_errors(lifecycle)),
                 ("runner", runner_contract_errors(runner)))
        survivors = [label for label, errors in cases if not errors]
        self.assertEqual([], survivors, f"inline function bypasses: {survivors}")

    def test_bounded_persistent_deletion_bypasses_are_rejected(self) -> None:
        cases = {
            "unresolved xargs": "printf '%s\\0' \"$unknown_state\" | xargs -0 rm -rf\n",
            "find path": "find /var/lib -path '/var/lib/pim-camera/*' -delete\n",
            "find shell": "find /var/lib/pim-camera -exec sh -c 'rm -rf \"$1\"' sh {} \\;\n",
            "xargs shell": "find /var/lib/pim-camera -print0 | xargs -0 sh -c 'rm -rf \"$1\"' sh\n",
            "glob": "rm -rf /var/lib/pim-camera*\n",
            "double slash": "rm -rf //var/lib/pim-camera\n",
        }
        survivors = [label for label, fixture in cases.items()
                     if not persistent_delete_lines(fixture)]
        self.assertEqual([], survivors, f"persistent deletion bypasses: {survivors}")

    def test_quoted_or_escaped_dollars_are_safe_literals(self) -> None:
        cases = {
            "single dollar": "rm -rf '$unknown_state'\n",
            "escaped dollar": r"rm -rf \$unknown_state" + "\n",
            "single substitution": "rm -rf '$(printf /var/lib/pim-camera)'\n",
        }
        false_positives = [label for label, fixture in cases.items()
                           if persistent_delete_lines(fixture)]
        self.assertEqual([], false_positives, f"safe literals rejected: {false_positives}")


class RoundFourReviewerCounterexamples(unittest.TestCase):
    def test_indented_arms_and_fallthrough_are_bounded(self) -> None:
        configured = f"""\
#!/bin/bash
{GOOD_CUSTOMCTL}case "$1" in
configure)
  ln -sf /opt/pim/bin/cam-recoveryctl /usr/local/bin/cam-recoveryctl
  ln -sf /opt/pim/bin/kill_test.sh /usr/local/bin/killcam
{GOOD_LIFECYCLE_COMMANDS}"""
        blocker = configured.replace(
            "configure)", "  *)\n    :\n    ;;\nconfigure)", 1
        ) + "  ;;\nesac\n"
        fallthrough = configured + """  FALLTHROUGH
*)
  customctl mask ord-operate
  ;;
esac
"""
        bad = {"indented wildcard": postinst_errors(blocker)}
        for terminator in (";&", ";;&"):
            bad[terminator] = postinst_errors(
                fallthrough.replace("FALLTHROUGH", terminator)
            )
        control = postinst_fixture(GOOD_LIFECYCLE_COMMANDS).replace(
            "\nconfigure)", "\n  configure)", 1
        )
        survivors = [name for name, errors in bad.items() if not errors]
        self.assertEqual(([], []), (survivors, postinst_errors(control)))

    def test_active_and_literal_protected_globs_are_distinguished(self) -> None:
        dangerous = ("rm -rf /var/lib/pim-camer[a]\n",
                     "rm -rf /var/lib/pim-camer?\n")
        safe = ("rm -rf '/var/lib/pim-camera*'\n",
                r"rm -rf /var/lib/pim-camera\*" + "\n")
        survivors = [case for case in dangerous if not persistent_delete_lines(case)]
        false_positives = [case for case in safe if persistent_delete_lines(case)]
        self.assertEqual(([], []), (survivors, false_positives))

    def test_unresolved_provenance_stays_within_its_pipeline(self) -> None:
        cases = ('logger "$unknown_state"; rm -rf /tmp/cache\n',
                 'logger "$unknown_state" && rm -rf /tmp/cache\n',
                 'logger "$unknown_state" || rm -rf /tmp/cache\n')
        self.assertEqual([], [case for case in cases if persistent_delete_lines(case)])


class RoundFiveReviewerCounterexamples(unittest.TestCase):
    def test_inline_case_terminators_preserve_syntax_provenance(self) -> None:
        configured = f"""\
#!/bin/bash
{GOOD_CUSTOMCTL}case "$1" in
configure)
  ln -sf /opt/pim/bin/cam-recoveryctl /usr/local/bin/cam-recoveryctl
  ln -sf /opt/pim/bin/kill_test.sh /usr/local/bin/killcam
"""
        decoy = configured + f"""\
  : ;;
*)
{GOOD_LIFECYCLE_COMMANDS}  ;;
esac
"""
        bad = {"inline normal": postinst_errors(decoy)}
        for terminator in (";&", ";;&"):
            fixture = configured + GOOD_LIFECYCLE_COMMANDS.rstrip("\n")
            fixture += f" {terminator}\n*)\n  :\n  ;;\nesac\n"
            bad[terminator] = postinst_errors(fixture)
        safe_data = (
            postinst_fixture(
                "  printf '%s\\n' ';; ;& ;;&'\n" + GOOD_LIFECYCLE_COMMANDS
            ),
            postinst_fixture(
                "  printf '%s\\n' \\;\\; \\;\\& \\;\\;\\&\n"
                + GOOD_LIFECYCLE_COMMANDS
            ),
        )
        survivors = [label for label, errors in bad.items() if not errors]
        false_positives = [fixture for fixture in safe_data if postinst_errors(fixture)]
        self.assertEqual(([], []), (survivors, false_positives))

    def test_assignment_globs_follow_destructive_use_quote_context(self) -> None:
        dangerous = (
            "state='/var/lib/pim-camer[a]'\nrm -rf $state\n",
            "state=/var/lib/pim-camer\\[a]\nrm -rf $state\n",
        )
        safe = (
            'state=/var/lib/pim-camera*\nrm -rf "$state"\n',
            'rm -rf "/var/lib/pim-camera*"\n',
        )
        survivors = [fixture for fixture in dangerous
                     if not persistent_delete_lines(fixture)]
        false_positives = [fixture for fixture in safe
                           if persistent_delete_lines(fixture)]
        self.assertEqual(([], []), (survivors, false_positives))

    def test_connector_data_preserves_pipeline_provenance(self) -> None:
        dangerous = (
            "printf '%s\\0' \"$unknown_state\" ';' | xargs -0 rm -rf\n",
            "printf '%s\\0' \"$unknown_state\" \\; | xargs -0 rm -rf\n",
        )
        data_tokens = (
            "';'", "'&&'", "'||'", "'|'", "'&'", "'('", "')'", "'{'", "'}'",
            "'>'", "'>|'", "'<'", r"\;", r"\&\&", r"\|\|", r"\|", r"\&",
            r"\(", r"\)", r"\{", r"\}", r"\>", r"\>\|", r"\<",
            '";"', '"&&"', '"||"', '"|"', '"&"', '"("', '")"', '"{"', '"}"',
            '">"', '">|"', '"<"',
        )
        safe = tuple(f'logger "$unknown_state" {token} rm -rf /tmp/cache\n'
                     for token in data_tokens)
        survivors = [fixture for fixture in dangerous
                     if not persistent_delete_lines(fixture)]
        false_positives = [fixture for fixture in safe
                           if persistent_delete_lines(fixture)]
        self.assertEqual(([], []), (survivors, false_positives))


if __name__ == "__main__":
    unittest.main(verbosity=2)
