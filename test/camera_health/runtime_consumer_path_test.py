#!/usr/bin/env python3
"""Explicit camera runtime/source ownership boundary audit."""

from __future__ import annotations

import ast
import re
import subprocess
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
SIMPLE_PRINTF_SUBSTITUTION = re.compile(
    r"^\$\(\s*(?:command\s+)?printf\s+(?:--\s+)?%s\s+"
    r"([A-Za-z0-9_./*:+?-]+)\s*\)$"
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


def remove_unquoted_shell_continuations(text: str) -> str:
    """Apply shell's unquoted backslash-newline removal to finite input."""
    normalized: list[str] = []
    quote = ""
    comment = False
    index = 0
    while index < len(text):
        char = text[index]
        if comment:
            normalized.append(char)
            if char == "\n":
                comment = False
            index += 1
            continue
        if quote == "'":
            normalized.append(char)
            if char == "'":
                quote = ""
            index += 1
            continue
        if char == "\\":
            next_char = text[index + 1] if index + 1 < len(text) else ""
            if not quote and next_char == "\n":
                index += 2
                continue
            normalized.append(char)
            if next_char:
                normalized.append(next_char)
                index += 2
            else:
                index += 1
            continue
        if quote:
            normalized.append(char)
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in "'\"":
            quote = char
        elif char == "#":
            comment = True
        normalized.append(char)
        index += 1
    return "".join(normalized)


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
    text = remove_unquoted_shell_continuations(text)
    constants: dict[str, str] = {}
    normalized: list[str] = []
    pending_assignment: tuple[str, list[str]] | None = None
    for raw_line in text.splitlines():
        expanded = expand_constants(strip_inline_comment(raw_line), constants)
        canonical = expanded.replace("'", "").replace('"', "").strip()
        normalized.append(canonical)

        if pending_assignment is not None:
            name, parts = pending_assignment
            parts.append(canonical)
            value = " ".join(parts).rstrip(";")
            if not value.rstrip().endswith(")"):
                continue
            printf_substitution = SIMPLE_PRINTF_SUBSTITUTION.fullmatch(value)
            if printf_substitution is not None:
                constants[name] = printf_substitution.group(1)
            pending_assignment = None
            continue

        assignment = SIMPLE_ASSIGNMENT.match(canonical.rstrip(";"))
        if assignment is None:
            continue
        name, value = assignment.groups()
        value = value.rstrip(";")
        if value.startswith("$(") and not value.rstrip().endswith(")"):
            pending_assignment = (name, [value])
            continue
        printf_substitution = SIMPLE_PRINTF_SUBSTITUTION.fullmatch(value)
        if printf_substitution is not None:
            value = printf_substitution.group(1)
        if re.fullmatch(r"[A-Za-z0-9_./*:+?-]+", value):
            constants[name] = value
    return normalized


def python_config_read_paths(text: str) -> list[str]:
    """Return statically-resolved Python JSON reader operands.

    This intentionally models only the small, executable data-flow surface used
    by deployed camera consumers: constant/path assignments, ``open`` and
    ``Path.open``/``read_text``, plus direct calls to simple local helpers.
    Unknown expressions remain unknown instead of being guessed safe or unsafe.
    """
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []

    functions = {
        node.name: node
        for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    reads: list[str] = []
    active_functions: set[int] = set()

    def call_name(node: ast.AST) -> str:
        if isinstance(node, ast.Name):
            return node.id
        if isinstance(node, ast.Attribute):
            prefix = call_name(node.value)
            return f"{prefix}.{node.attr}" if prefix else node.attr
        return ""

    def resolve(node: ast.AST | None, env: dict[str, set[str]]) -> set[str]:
        if node is None:
            return set()
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return {node.value}
        if isinstance(node, ast.Name):
            return set(env.get(node.id, ()))
        if isinstance(node, ast.JoinedStr):
            parts: list[set[str]] = []
            for value in node.values:
                if isinstance(value, ast.FormattedValue):
                    part = resolve(value.value, env)
                else:
                    part = resolve(value, env)
                if not part:
                    return set()
                parts.append(part)
            values = {""}
            for part in parts:
                values = {left + right for left in values for right in part}
            return values
        if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Div)):
            left = resolve(node.left, env)
            right = resolve(node.right, env)
            if isinstance(node.op, ast.Add):
                return {a + b for a in left for b in right}
            return {f"{a.rstrip('/')}/{b.lstrip('/')}" for a in left for b in right}
        if isinstance(node, ast.Call):
            name = call_name(node.func)
            if name in {"Path", "PurePath", "pathlib.Path", "pathlib.PurePath"}:
                return resolve(node.args[0], env) if node.args else set()
            if name in {"os.getenv", "os.environ.get", "environ.get"}:
                if len(node.args) > 1:
                    return resolve(node.args[1], env)
                for keyword in node.keywords:
                    if keyword.arg == "default":
                        return resolve(keyword.value, env)
        return set()

    def bind(target: ast.AST, values: set[str], env: dict[str, set[str]]) -> None:
        if isinstance(target, ast.Name):
            env[target.id] = set(values)
        elif isinstance(target, (ast.Tuple, ast.List)):
            for element in target.elts:
                bind(element, set(), env)

    def open_mode(call: ast.Call, env: dict[str, set[str]]) -> str | None:
        mode_node = call.args[1] if len(call.args) > 1 else None
        for keyword in call.keywords:
            if keyword.arg == "mode":
                mode_node = keyword.value
        modes = resolve(mode_node, env)
        return next(iter(modes)) if len(modes) == 1 else None

    def analyze_function(
        function: ast.FunctionDef | ast.AsyncFunctionDef,
        call: ast.Call | None,
        outer_env: dict[str, set[str]],
    ) -> None:
        identity = id(function)
        if identity in active_functions:
            return
        active_functions.add(identity)
        local_env = dict(outer_env)
        parameters = list(function.args.posonlyargs) + list(function.args.args)
        defaults = [None] * (len(parameters) - len(function.args.defaults)) + list(
            function.args.defaults
        )
        for parameter, default in zip(parameters, defaults, strict=True):
            local_env[parameter.arg] = resolve(default, outer_env)
        if call is not None:
            for parameter, argument in zip(parameters, call.args):
                local_env[parameter.arg] = resolve(argument, outer_env)
            keyword_values = {
                keyword.arg: resolve(keyword.value, outer_env)
                for keyword in call.keywords
                if keyword.arg is not None
            }
            for parameter in parameters:
                if parameter.arg in keyword_values:
                    local_env[parameter.arg] = keyword_values[parameter.arg]
        analyze_statements(function.body, local_env)
        active_functions.remove(identity)

    def analyze_expr(node: ast.AST | None, env: dict[str, set[str]]) -> set[str]:
        if node is None:
            return set()
        if isinstance(node, ast.Call):
            name = call_name(node.func)
            operand: ast.AST | None = None
            if name == "open":
                operand = node.args[0] if node.args else None
                if operand is None:
                    operand = next(
                        (
                            keyword.value
                            for keyword in node.keywords
                            if keyword.arg == "file"
                        ),
                        None,
                    )
            elif isinstance(node.func, ast.Attribute) and node.func.attr in {
                "open",
                "read_text",
            }:
                operand = node.func.value
            if operand is not None:
                mode = open_mode(node, env)
                if mode is None or not mode.startswith(("w", "a", "x")):
                    paths = resolve(operand, env)
                    reads.extend(paths)
                    for argument in node.args:
                        analyze_expr(argument, env)
                    for keyword in node.keywords:
                        analyze_expr(keyword.value, env)
                    return paths

            helper = functions.get(name) if isinstance(node.func, ast.Name) else None
            if helper is not None:
                analyze_function(helper, node, env)
            analyze_expr(node.func, env)
            for argument in node.args:
                analyze_expr(argument, env)
            for keyword in node.keywords:
                analyze_expr(keyword.value, env)
        else:
            for child in ast.iter_child_nodes(node):
                analyze_expr(child, env)
        return resolve(node, env)

    def analyze_statements(
        statements: list[ast.stmt], env: dict[str, set[str]]
    ) -> None:
        for statement in statements:
            if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                continue
            if isinstance(statement, (ast.Assign, ast.AnnAssign)):
                value = analyze_expr(statement.value, env)
                targets = statement.targets if isinstance(statement, ast.Assign) else [statement.target]
                for target in targets:
                    bind(target, value, env)
            elif isinstance(statement, ast.With):
                scoped = dict(env)
                for item in statement.items:
                    value = analyze_expr(item.context_expr, scoped)
                    if item.optional_vars is not None:
                        bind(item.optional_vars, value, scoped)
                analyze_statements(statement.body, scoped)
            elif isinstance(statement, ast.If):
                analyze_expr(statement.test, env)
                analyze_statements(statement.body, dict(env))
                analyze_statements(statement.orelse, dict(env))
            elif isinstance(statement, (ast.For, ast.AsyncFor)):
                analyze_expr(statement.iter, env)
                analyze_statements(statement.body, dict(env))
                analyze_statements(statement.orelse, dict(env))
            elif isinstance(statement, ast.Try):
                analyze_statements(statement.body, dict(env))
                for handler in statement.handlers:
                    analyze_statements(handler.body, dict(env))
                analyze_statements(statement.orelse, dict(env))
                analyze_statements(statement.finalbody, dict(env))
            else:
                for child in ast.iter_child_nodes(statement):
                    analyze_expr(child, env)

    globals_env: dict[str, set[str]] = {}
    analyze_statements(tree.body, globals_env)
    for function in functions.values():
        analyze_function(function, None, globals_env)
    return list(dict.fromkeys(reads))


def logical_config_read_lines(text: str, lines: list[str]) -> list[str]:
    """Join shell continuations and quoted spans within the finite input."""
    text = remove_unquoted_shell_continuations(text)
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

    for path in python_config_read_paths(text):
        if not path.startswith("/") or not path.endswith(".json"):
            continue
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
    continued_assignment = """\
ACTUAL_CONFIG=$(
  command printf -- %s \\
  /etc/pim/camera.json
)
"""
    continued_reader_fixture = f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
{continued_assignment}jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
'''
    renamed_continued_fixture = f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
    REVIEWED_INPUT=$(
        printf %s \\
          /var/lib/pim/reviewed-camera.json
    )
jq -r '.VHL_CAM.app' "$REVIEWED_INPUT"
'''
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
            "Path.open data flow cannot hide an alternate JSON read",
            f'''\
from pathlib import Path
import json
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
actual = Path("/etc/pim/camera.json")
with actual.open(encoding="utf-8") as stream:
    json.load(stream)
''',
            "alternate config read:",
        ),
        (
            "helper parameter flow cannot hide an alternate JSON read",
            f'''\
import json
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)
load("/etc/pim/camera.json")
''',
            "alternate config read:",
        ),
        (
            "built-in open file keyword flow cannot hide an alternate JSON read",
            f'''\
from pathlib import Path
import json
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
actual = Path("/etc/pim/camera.json")
with open(file=actual, encoding="utf-8") as stream:
    json.load(stream)
''',
            "alternate config read:",
        ),
        (
            "command substitution cannot hide an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
ACTUAL_CONFIG=$(printf %s /etc/pim/camera.json)
jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
''',
            "alternate config read:",
        ),
        (
            "multiline command substitution cannot hide an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
ACTUAL_CONFIG=$(
  command printf -- %s /etc/pim/camera.json
)
jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
''',
            "alternate config read:",
        ),
        (
            "continued multiline command substitution cannot hide an alternate JSON read",
            continued_reader_fixture,
            "alternate config read:",
        ),
        (
            "renamed indented continued substitution cannot hide an alternate JSON read",
            renamed_continued_fixture,
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

    bash_result = subprocess.run(
        [
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-c",
            continued_assignment + 'printf "%s\\n" "$ACTUAL_CONFIG"\n',
        ],
        capture_output=True,
        text=True,
        timeout=5,
        env={"BASH_ENV": "/dev/null", "PATH": "/usr/bin:/bin"},
        check=False,
    )
    check(
        bash_result.returncode == 0
        and bash_result.stdout == "/etc/pim/camera.json\n"
        and bash_result.stderr == "",
        "Bash evaluates the continued substitution to the alternate path",
        failures,
    )

    quoted_data_fixture = f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
QUOTED_DATA=$(
  command printf -- %s '\\
/etc/pim/camera.json'
)
jq -r '.VHL_CAM.app' "$QUOTED_DATA"
'''
    check(
        not any(
            item.startswith("alternate config read:")
            for item in runtime_boundary_violations(
                quoted_data_fixture,
                "PIM_CAMERA_RUNTIME_JSON",
                RUNTIME_PATH,
            )
        ),
        "single-quoted backslash-newline remains data, not continuation",
        failures,
    )

    print()
    print(f"camera runtime consumer boundary: {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
