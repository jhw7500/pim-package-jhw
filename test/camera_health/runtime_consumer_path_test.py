#!/usr/bin/env python3
"""Explicit camera runtime/source ownership boundary audit."""

from __future__ import annotations

import ast
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
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

SHELL_ASSIGNMENT_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SHELL_VARIABLE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$|^[0-9]+$")

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


@dataclass(frozen=True)
class ShellOrigin:
    kind: str
    value: str | None = None


@dataclass(frozen=True)
class ShellProvenanceResult:
    contract_text: str
    marker_present: bool
    default_present: bool
    reader_violations: tuple[str, ...]


UNKNOWN_ORIGIN = ShellOrigin("unknown")
RUNTIME_CONTENT = ShellOrigin("runtime-content")
STATE_CONTENT = ShellOrigin("state-content")
ALTERNATE_CONTENT = ShellOrigin("alternate-content")


@dataclass(frozen=True)
class ShellWord:
    raw: str
    parts: tuple[tuple[str, str], ...]
    malformed: bool = False


@dataclass(frozen=True)
class ShellCommand:
    raw: str
    words: tuple[ShellWord, ...]
    malformed: bool = False
    piped_input: bool = False


@dataclass(frozen=True)
class ShellLexicalResult:
    normalized: str
    contract_text: str
    top: tuple[ShellCommand, ...]
    functions: dict[str, tuple[str, tuple[ShellCommand, ...]]]
    malformed: bool


def lex_shell(text: str) -> ShellLexicalResult:
    """Tokenize the bounded deployed shell surface once, without evaluation."""

    def substitution_end(source: str, start: int) -> int | None:
        quotes = [""]
        comments = [False]
        depths = [1]
        index = start + 2
        while index < len(source):
            char = source[index]
            following = source[index + 1] if index + 1 < len(source) else ""
            if comments[-1]:
                comments[-1] = char != "\n"
            elif quotes[-1] == "'":
                if char == "'":
                    quotes[-1] = ""
            elif char == "\\":
                index += bool(following)
            elif char == "$" and following == "(":
                quotes.append("")
                comments.append(False)
                depths.append(1)
                index += 1
            elif quotes[-1]:
                if char == quotes[-1]:
                    quotes[-1] = ""
            elif char in "'\"":
                quotes[-1] = char
            elif char == "#":
                comments[-1] = True
            elif char == "(":
                depths[-1] += 1
            elif char == ")":
                depths[-1] -= 1
                if depths[-1] == 0:
                    quotes.pop()
                    comments.pop()
                    depths.pop()
                    if not depths:
                        return index
            index += 1
        return None

    normalized: list[str] = []
    frames: list[list[object]] = [["", False, 0]]
    index = 0
    while index < len(text):
        quote, comment, depth = frames[-1]
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if comment:
            normalized.append(char)
            if char == "\n":
                frames[-1][1] = False
        elif quote == "'":
            normalized.append(char)
            if char == "'":
                frames[-1][0] = ""
        elif char == "\\":
            if following == "\n":
                index += 1
            else:
                normalized.extend((char, following) if following else (char,))
                index += bool(following)
        elif char == "$" and following == "(":
            normalized.extend((char, following))
            frames.append(["", False, 1])
            index += 1
        else:
            normalized.append(char)
            if quote:
                if char == quote:
                    frames[-1][0] = ""
            elif char in "'\"":
                frames[-1][0] = char
            elif char == "#":
                frames[-1][1] = True
            elif len(frames) > 1 and char == "(":
                frames[-1][2] = int(depth) + 1
            elif len(frames) > 1 and char == ")":
                frames[-1][2] = int(depth) - 1
                if frames[-1][2] == 0:
                    frames.pop()
        index += 1
    source = "".join(normalized)

    heredoc: str | None = None
    stripped: list[str] = []
    declaration = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_]\w*)\1")
    for line in source.splitlines(keepends=True):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            stripped.append("\n" if line.endswith("\n") else "")
        else:
            stripped.append(line)
            match = declaration.search(line)
            heredoc = match.group(2) if match else None
    source = "".join(stripped)

    function_pattern = re.compile(
        r"^[ \t]*(?:function[ \t]+)?([A-Za-z_]\w*)"
        r"[ \t]*(?:\(\s*\))?[ \t]*\{"
    )
    lines = source.splitlines(keepends=True)
    offsets: list[int] = []
    total = 0
    for line in lines:
        offsets.append(total)
        total += len(line)
    bodies: dict[str, str] = {}
    spans: list[tuple[int, int]] = []
    line_index = 0
    while line_index < len(lines):
        match = function_pattern.match(lines[line_index])
        if match is None:
            line_index += 1
            continue
        brace = lines[line_index].find("{", match.start(), match.end())
        opening = offsets[line_index] + brace
        end_line = line_index
        if "}" in lines[line_index][brace + 1 :]:
            closing = offsets[line_index] + lines[line_index].rfind("}")
        else:
            end_line += 1
            while end_line < len(lines) and not lines[end_line].startswith("}"):
                end_line += 1
            if end_line == len(lines):
                break
            closing = offsets[end_line]
        bodies[match.group(1)] = source[opening + 1 : closing]
        spans.append((offsets[line_index], closing + 1))
        line_index = end_line + 1
    top_chars = list(source)
    for start, end in spans:
        top_chars[start:end] = ["\n" if char == "\n" else " " for char in top_chars[start:end]]

    source_malformed = len(frames) != 1 or bool(frames[0][0])

    def word_parts(word: str) -> tuple[tuple[tuple[str, str], ...], bool]:
        parts: list[tuple[str, str]] = []
        literal: list[str] = []
        quote = ""
        bad = False

        def flush() -> None:
            if literal:
                parts.append(("literal", "".join(literal)))
                literal.clear()

        index = 0
        while index < len(word):
            char = word[index]
            following = word[index + 1] if index + 1 < len(word) else ""
            if quote == "'":
                if char == "'":
                    flush()
                    quote = ""
                else:
                    literal.append(char)
            elif char == "\\":
                if following:
                    literal.append(following)
                    index += 1
                else:
                    bad = True
            elif char == "$" and following == "(":
                flush()
                end = substitution_end(word, index)
                if end is None:
                    bad = True
                    break
                parts.append(("command", word[index + 2 : end]))
                index = end
            elif quote and char == quote:
                flush()
                quote = ""
            elif not quote and char in "'\"":
                flush()
                quote = char
            elif char == "$" and following == "{":
                flush()
                end = word.find("}", index + 2)
                if end < 0:
                    bad = True
                    break
                parts.append(("parameter", word[index + 2 : end]))
                index = end
            elif char == "$" and (following.isalnum() or following == "_"):
                flush()
                end = index + 2
                while end < len(word) and (word[end].isalnum() or word[end] == "_"):
                    end += 1
                parts.append(("variable", word[index + 1 : end]))
                index = end - 1
            elif char == "$" and following in "$?@*#-!":
                flush()
                parts.append(("special", following))
                index += 1
            else:
                literal.append(char)
            index += 1
        flush()
        return tuple(parts), bad or bool(quote)

    def tokenize(command: str, piped_input: bool = False) -> ShellCommand:
        masked: list[str] = []
        substitutions: dict[str, str] = {}
        quote = ""
        index = 0
        while index < len(command):
            char = command[index]
            following = command[index + 1] if index + 1 < len(command) else ""
            if quote == "'":
                quote = "" if char == "'" else quote
            elif char == "\\":
                masked.extend((char, following) if following else (char,))
                index += bool(following)
                index += 1
                continue
            elif char == "$" and following == "(":
                end = substitution_end(command, index)
                if end is None:
                    return ShellCommand(command, (ShellWord(command, (), True),), True, piped_input)
                key = f"__PIM_SUB_{len(substitutions)}__"
                substitutions[key] = command[index : end + 1]
                masked.extend(key)
                index = end + 1
                continue
            elif quote:
                quote = "" if char == quote else quote
            elif char in "'\"":
                quote = char
            masked.append(char)
            index += 1
        try:
            lexer = shlex.shlex("".join(masked), posix=False, punctuation_chars="<>")
            lexer.whitespace_split = True
            lexer.commenters = ""
            raw_words = list(lexer)
        except ValueError:
            return ShellCommand(command, (ShellWord(command, (), True),), True, piped_input)
        words: list[ShellWord] = []
        for raw in raw_words:
            raw = re.sub(
                r"__PIM_SUB_[0-9]+__",
                lambda match: substitutions[match.group(0)],
                raw,
            )
            parts, bad = word_parts(raw)
            words.append(ShellWord(raw, parts, bad))
        return ShellCommand(
            command,
            tuple(words),
            bool(quote) or any(word.malformed for word in words),
            piped_input,
        )

    def commands(scope: str) -> tuple[ShellCommand, ...]:
        parsed: list[ShellCommand] = []
        pending_nested: list[ShellCommand] = []
        current: list[str] = []
        quote = ""
        index = 0
        piped_input = False

        def finish() -> None:
            nonlocal piped_input
            command = "".join(current).strip()
            parsed.extend(pending_nested)
            pending_nested.clear()
            if command:
                parsed.append(tokenize(command, piped_input))
                piped_input = False
            current.clear()

        while index < len(scope):
            char = scope[index]
            following = scope[index + 1] if index + 1 < len(scope) else ""
            if quote == "'":
                current.append(char)
                quote = "" if char == "'" else quote
            elif char == "\\":
                current.extend((char, following) if following else (char,))
                index += bool(following)
            elif char == "$" and following == "(":
                end = substitution_end(scope, index)
                if end is None:
                    current.append(scope[index:])
                    break
                substitution = scope[index : end + 1]
                pending_nested.extend(commands(substitution[2:-1]))
                current.append(substitution)
                index = end
            elif char == "$" and following == "{":
                end = scope.find("}", index + 2)
                if end < 0:
                    current.append(scope[index:])
                    break
                current.append(scope[index : end + 1])
                index = end
            elif quote:
                current.append(char)
                quote = "" if char == quote else quote
            elif char in "'\"":
                quote = char
                current.append(char)
            elif char == "#":
                while index < len(scope) and scope[index] != "\n":
                    index += 1
                continue
            elif char in "\n;{}|&":
                is_pipe = char == "|" and following != "|"
                finish()
                if is_pipe:
                    piped_input = True
                if (following == char and char in "|&") or (char == "|" and following == "&"):
                    index += 1
            else:
                current.append(char)
            index += 1
        finish()
        return tuple(parsed)

    def contract_render(command_groups: list[tuple[ShellCommand, ...]]) -> str:
        constants: dict[str, str] = {}
        rendered: list[str] = []
        assignment = re.compile(r"^\s*(?:(?:export|readonly|local)\s+)?([A-Za-z_]\w*)\s*=\s*(.*?)\s*$")
        for command in (item for group in command_groups for item in group):
            line = command.raw
            previous = None
            while previous != line:
                previous = line
                line = re.sub(r"\$\{([A-Za-z_]\w*):-([^{}]*)\}", lambda m: constants.get(m.group(1), m.group(2)), line)
                line = re.sub(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)", lambda m: constants.get(m.group(1) or m.group(2), m.group(0)), line)
            canonical = line.replace("'", "").replace('"', "").strip()
            rendered.append(canonical)
            match = assignment.match(canonical.rstrip(";"))
            if match and re.fullmatch(r"[A-Za-z0-9_./*:+? -]+", match.group(2).rstrip(";")):
                constants[match.group(1)] = match.group(2).rstrip(";")
        return "\n".join(rendered)

    top = commands("".join(top_chars))
    functions = {name: (body, commands(body)) for name, body in bodies.items()}
    contract = contract_render([top, *(items for _, items in functions.values())])
    return ShellLexicalResult(source, contract, top, functions, source_malformed)


class ShellProvenanceProof:
    """Small fail-closed transfer proof over one immutable lexical result."""

    def __init__(self, lexical: ShellLexicalResult, marker: str, default: str | None, allow_source: bool) -> None:
        self.lexical = lexical
        self.marker = marker
        self.default = default
        self.allow_source = allow_source
        self.violations: list[str] = []
        self.marker_seeded = False
        self.default_seeded = default is None

        def recovery_import(word: ShellWord) -> str | None:
            literal = self.literal(word)
            if literal and literal.endswith(("cam_recovery.sh", "cam_recovery_actions.sh")):
                return literal.rsplit("/", 1)[-1]
            for name in ("cam_recovery.sh", "cam_recovery_actions.sh"):
                if word.parts == (("variable", "PIM_LIB"), ("literal", f"/{name}")):
                    return name
            return None

        imports = {
            imported
            for command in lexical.top
            if (argv := self.argv(command.words))
            and self.literal(argv[0]) in {"source", "."}
            and len(argv) > 1
            and (imported := recovery_import(argv[1]))
        }
        self.imports_recovery = bool(imports)
        helper_bodies = dict(lexical.functions)
        if self.imports_recovery:
            imported = lex_shell(executable_text(Path("dist/pim/opt/pim/lib/cam_recovery.sh")))
            helper_bodies = {**imported.functions, **helper_bodies}
        self.helpers = self.proven_helpers(helper_bodies)

    @staticmethod
    def literal(word: ShellWord) -> str | None:
        return word.parts[0][1] if not word.malformed and len(word.parts) == 1 and word.parts[0][0] == "literal" else None

    @staticmethod
    def assignment(word: ShellWord) -> tuple[str, ShellWord] | None:
        if "=" not in word.raw:
            return None
        name, value = word.raw.split("=", 1)
        if SHELL_ASSIGNMENT_NAME.fullmatch(name) is None:
            return None
        parts = list(word.parts)
        prefix = f"{name}="
        if not parts or parts[0][0] != "literal" or not parts[0][1].startswith(prefix):
            return name, ShellWord(value, (), True)
        remainder = parts[0][1][len(prefix) :]
        parts[:1] = (("literal", remainder),) if remainder else ()
        return name, ShellWord(value, tuple(parts), word.malformed)

    def argv(self, words: tuple[ShellWord, ...]) -> tuple[ShellWord, ...]:
        controls = {"if", "then", "elif", "while", "until", "do", "!", "time"}
        index = 0
        while index < len(words) and self.literal(words[index]) in controls:
            index += 1
        while index < len(words) and self.assignment(words[index]):
            index += 1
        return words[index:]

    def simple_command(
        self,
        words: tuple[ShellWord, ...],
        values: dict[str, ShellOrigin],
    ) -> tuple[tuple[ShellWord, ...], tuple[ShellOrigin, ...], bool]:
        """Separate redirections before determining the bounded executable."""

        controls = {"if", "then", "elif", "while", "until", "do", "!", "time"}
        index = 0
        while index < len(words) and self.literal(words[index]) in controls:
            index += 1
        argv: list[ShellWord] = []
        inputs: list[ShellOrigin] = []
        explicit_stdin = False
        executable_seen = False
        while index < len(words):
            literal = self.literal(words[index])
            if not executable_seen and self.assignment(words[index]):
                index += 1
                continue

            descriptor = None
            operator_index = index
            if (
                literal is not None
                and literal.isdigit()
                and index + 1 < len(words)
                and self.literal(words[index + 1]) in {"<", "<<<", "<<", ">", ">>"}
            ):
                descriptor = literal
                operator_index += 1
            operator = self.literal(words[operator_index])
            if operator in {"<", "<<<", "<<", ">", ">>"}:
                operand_index = operator_index + 1
                if operator in {"<", "<<<"} and descriptor in {None, "0"}:
                    explicit_stdin = True
                    origin = self.value(words[operand_index], values) if operand_index < len(words) else UNKNOWN_ORIGIN
                    if operator == "<<<" and origin.kind == "literal":
                        origin = STATE_CONTENT
                    inputs.append(origin)
                index = operand_index + 1
                continue

            argv.append(words[index])
            executable_seen = True
            index += 1
        return tuple(argv), tuple(inputs), explicit_stdin

    def proven_helpers(self, functions: dict[str, tuple[str, tuple[ShellCommand, ...]]]) -> dict[str, ShellOrigin]:
        proven: dict[str, ShellOrigin] = {}
        while True:
            before = len(proven)
            for name, (body, commands) in functions.items():
                if name in proven:
                    continue
                cat = re.fullmatch(
                    r'''\s*cat\s+["']?\$\(([A-Za-z_]\w*)\)["']?\s+2\s*>\s*/dev/null\s*;?\s*''',
                    body,
                    re.S,
                )
                if cat and proven.get(cat.group(1), UNKNOWN_ORIGIN).kind == "state-path":
                    proven[name] = STATE_CONTENT
                    continue
                last = commands[-1] if commands else None
                if last and body.rstrip().endswith(last.raw.rstrip()):
                    jq_argv = self.jq_invocation(self.argv_static(last.words))
                    if jq_argv is not None:
                        inputs, _, null_input = self.jq_inputs(jq_argv, {})
                        prefix = body[: body.rfind(last.raw)]
                        setup = [line.strip() for line in prefix.splitlines() if line.strip()]
                        safe_setup = all(
                            re.fullmatch(r"local(?:\s+[A-Za-z_]\w*)+", line) is not None
                            or re.fullmatch(
                                r'''[A-Za-z_]\w*=\$\([^\n]+\)(?:\s*\|\|\s*return\s+[0-9]+)?''',
                                line,
                            )
                            is not None
                            for line in setup
                        )
                        if null_input and not inputs and safe_setup:
                            proven[name] = STATE_CONTENT
                            continue
                lines = [line.strip() for line in body.splitlines() if line.strip()]
                if len(lines) == 3:
                    local = re.fullmatch(r"local\s+([A-Za-z_]\w*)", lines[0])
                    relay = re.fullmatch(
                        r'''([A-Za-z_]\w*)=\$\(cat\s+["']?\$\(([A-Za-z_]\w*)\)["']?\s+2\s*>\s*/dev/null\)'''
                        r'''\s*&&\s*([A-Za-z_]\w*)\s*<<<\s*["']?\$\1["']?'''
                        r'''\s*&&\s*\{\s*printf\s+["']%s\\n["']\s+["']?\$\1["']?;\s*return\s+0;\s*\}''',
                        lines[1],
                    )
                    fallback = re.fullmatch(r"([A-Za-z_]\w*)", lines[2])
                    if local and relay and fallback and local.group(1) == relay.group(1):
                        path = proven.get(relay.group(2), UNKNOWN_ORIGIN)
                        validator = functions.get(relay.group(3))
                        quiet_validator = bool(
                            validator
                            and re.fullmatch(
                                r'''\s*jq\s+-e\s+'[^']*'\s*>\s*/dev/null\s+2\s*>\s*&\s*1\s*''',
                                validator[0],
                                re.S,
                            )
                        )
                        fallback_origin = proven.get(fallback.group(1), UNKNOWN_ORIGIN)
                        if path.kind == "state-path" and quiet_validator and fallback_origin.kind == "state-content":
                            proven[name] = STATE_CONTENT
                            continue
                printf = [command for command in commands if (argv := ShellProvenanceProof.argv_static(command.words)) and ShellProvenanceProof.literal(argv[0]) == "printf"]
                if len(printf) != 1 or "jq" in body:
                    continue
                argv = ShellProvenanceProof.argv_static(printf[0].words)
                format_index = 2 if len(argv) > 1 and ShellProvenanceProof.literal(argv[1]) == "--" else 1
                format_text = ShellProvenanceProof.literal(argv[format_index]) if len(argv) > format_index else None
                approved_roots = {"PIM_CAMERA_RUN_DIR", "PIM_CAMERA_STATE_DIR", "PIM_CAMERA_CONTROL_WORK_DIR"}
                rooted = any(
                    (kind == "variable" and value in approved_roots)
                    or (
                        kind == "command"
                        and proven.get(value.strip(), UNKNOWN_ORIGIN).kind
                        in {"state-path", "source-path"}
                    )
                    for word in argv[format_index + 1 :]
                    for kind, value in word.parts
                )
                if format_text and format_text.startswith("%s") and re.search(r"(?:\.json|/recovery|/control)", format_text) and rooted:
                    proven[name] = ShellOrigin("source-path" if "candidate.json" in format_text else "state-path")
            if len(proven) == before:
                return proven

    @staticmethod
    def argv_static(words: tuple[ShellWord, ...]) -> tuple[ShellWord, ...]:
        index = 0
        while index < len(words) and ShellProvenanceProof.literal(words[index]) in {"if", "then", "elif", "while", "until", "do", "!", "time"}:
            index += 1
        while index < len(words) and ShellProvenanceProof.assignment(words[index]):
            index += 1
        return words[index:]

    @staticmethod
    def classify(value: str) -> ShellOrigin:
        if value == RUNTIME_PATH:
            return ShellOrigin("runtime-path", value)
        if value in {"/run/pim-camera", "/var/lib/pim-camera", "/run/pim-camera/control"}:
            return ShellOrigin("state-root", value)
        if value == "/root/shared_v":
            return ShellOrigin("source-root", value)
        if value.startswith("/root/shared_v/") and value.endswith(".json"):
            return ShellOrigin("source-path", value)
        state = value in {"/run/pim-camera/owner.json", "/var/lib/pim-camera/service-state.json", "/run/pim-camera/control/source.json", "/run/pim-camera/control/plan.json", "/run/pim-camera/control/projection.json"} or value.startswith(("/run/pim-camera/recovery/", "/var/lib/pim-camera/recovery/"))
        if state:
            return ShellOrigin("state-path", value)
        if value == "/run/pim-camera/control/candidate.json":
            return ShellOrigin("source-path", value)
        return ShellOrigin("alternate-path", value) if value.startswith("/") and value.endswith(".json") else ShellOrigin("literal", value)

    def substitution(self, body: str, values: dict[str, ShellOrigin]) -> ShellOrigin:
        body = body.strip()
        if re.fullmatch(r"[A-Za-z_]\w*", body):
            return self.helpers.get(body, UNKNOWN_ORIGIN)
        cat = re.fullmatch(
            r'''cat\s+["']?\$\(([A-Za-z_]\w*)(?:\s+.*?)?\)["']?\s+2\s*>\s*/dev/null''',
            body,
            re.S,
        )
        if cat:
            path = self.helpers.get(cat.group(1), UNKNOWN_ORIGIN)
            if path.kind == "runtime-path":
                return RUNTIME_CONTENT
            if path.kind == "state-path":
                return STATE_CONTENT
            if path.kind in {"alternate-path", "source-path"}:
                return ALTERNATE_CONTENT
        if not body.startswith("<"):
            lexical = lex_shell(body)
            if lexical.malformed or len(lexical.top) != 1:
                return UNKNOWN_ORIGIN
            argv = self.argv(lexical.top[0].words)
            jq_argv = self.jq_invocation(argv)
            if jq_argv is None:
                return UNKNOWN_ORIGIN
            inputs, _, null_input = self.jq_inputs(jq_argv, values)
            if null_input and not inputs:
                return STATE_CONTENT
            if "<<<" not in body or not inputs:
                return UNKNOWN_ORIGIN
            kinds = {origin.kind for origin in inputs}
            if kinds <= {"runtime-content"}:
                return RUNTIME_CONTENT
            if kinds <= {"state-content"}:
                return STATE_CONTENT
            if kinds & {"alternate-content", "alternate-path", "source-path"}:
                return ALTERNATE_CONTENT
            return UNKNOWN_ORIGIN
        operand = body[1:].strip()
        if len(operand) >= 2 and operand[0] == operand[-1] and operand[0] in "'\"":
            operand = operand[1:-1]
        match = re.fullmatch(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))", operand)
        origin = values.get((match.group(1) or match.group(2)), UNKNOWN_ORIGIN) if match else self.classify(operand)
        return {"runtime-path": RUNTIME_CONTENT, "state-path": STATE_CONTENT, "alternate-path": ALTERNATE_CONTENT, "source-path": ALTERNATE_CONTENT}.get(origin.kind, UNKNOWN_ORIGIN)

    def value(self, word: ShellWord, values: dict[str, ShellOrigin]) -> ShellOrigin:
        if word.malformed or not word.parts:
            return UNKNOWN_ORIGIN
        origins: list[ShellOrigin] = []
        for kind, value in word.parts:
            if kind == "literal":
                origins.append(self.classify(value))
            elif kind == "variable":
                origins.append(values.get(value, UNKNOWN_ORIGIN))
            elif kind == "command":
                origins.append(self.substitution(value, values))
            elif kind == "parameter":
                match = re.fullmatch(r"([A-Za-z_]\w*|[0-9]+)(:?[-?])(.*)", value, re.S)
                if SHELL_VARIABLE_NAME.fullmatch(value):
                    origins.append(values.get(value, UNKNOWN_ORIGIN))
                elif match and values.get(match.group(1), UNKNOWN_ORIGIN).kind != "unknown":
                    origins.append(values[match.group(1)])
                elif match and match.group(2).endswith("-"):
                    fallback = match.group(3)
                    if fallback == "$PIM_CAMERA_RUN_DIR/config/pim_runtime.json" and values.get("PIM_CAMERA_RUN_DIR", UNKNOWN_ORIGIN).kind == "state-root":
                        origins.append(ShellOrigin("runtime-path", RUNTIME_PATH))
                    else:
                        origins.append(self.classify(fallback))
                else:
                    origins.append(UNKNOWN_ORIGIN)
            else:
                origins.append(UNKNOWN_ORIGIN)
        if len(origins) == 1:
            return origins[0]
        if all(kind == "literal" for kind, _ in word.parts) or any(origin.kind == "unknown" for origin in origins):
            return UNKNOWN_ORIGIN
        rooted = [origin for origin in origins if origin.kind in {"state-root", "state-path", "source-root", "source-path"}]
        if len(rooted) != 1 or any(origin.value is None for origin in origins):
            return UNKNOWN_ORIGIN
        return self.classify("".join(origin.value or "" for origin in origins))

    def reader_violation(self, origin: ShellOrigin) -> str | None:
        if origin.kind in {"runtime-path", "runtime-content", "state-path", "state-content"} or (self.allow_source and origin.kind == "source-path"):
            return None
        if origin.kind in {"alternate-path", "source-path"} and origin.value:
            return f"alternate config read: {origin.value}"
        return "unproven config reader operand"

    def jq_invocation(self, argv: tuple[ShellWord, ...]) -> tuple[ShellWord, ...] | None:
        if not argv:
            return None
        index = 0
        executable = self.literal(argv[index])
        if executable == "command":
            index += 1
            if index < len(argv) and self.literal(argv[index]) == "--":
                index += 1
            executable = self.literal(argv[index]) if index < len(argv) else None
        if executable == "jq" or (
            executable is not None
            and executable.startswith("/")
            and executable.rsplit("/", 1)[-1] == "jq"
        ):
            return argv[index:]
        return None

    def jq_inputs(
        self,
        argv: tuple[ShellWord, ...],
        values: dict[str, ShellOrigin],
    ) -> tuple[list[ShellOrigin], bool, bool]:
        inputs: list[ShellOrigin] = []
        explicit_stdin = False
        null_input = False
        filter_seen = False
        index = 1
        while index < len(argv):
            literal = self.literal(argv[index])
            if literal in {"<", "<<<"}:
                explicit_stdin = True
                origin = (
                    self.value(argv[index + 1], values)
                    if index + 1 < len(argv)
                    else UNKNOWN_ORIGIN
                )
                if literal == "<<<" and origin.kind == "literal":
                    origin = STATE_CONTENT
                inputs.append(origin)
                index += 2
            elif literal and literal.isdigit() and index + 1 < len(argv) and self.literal(argv[index + 1]) in {">", ">>"}:
                index += 3
            elif literal in {">", ">>", "<<"}:
                index += 2
            elif not filter_seen and literal and literal.startswith("-"):
                if literal == "--null-input" or (
                    not literal.startswith("--") and "n" in literal[1:]
                ):
                    null_input = True
                if literal in {"--arg", "--argjson"}:
                    index += 3
                elif literal in {"--slurpfile", "--rawfile", "--argfile"}:
                    inputs.append(self.value(argv[index + 2], values) if index + 2 < len(argv) else UNKNOWN_ORIGIN)
                    index += 3
                else:
                    index += 1
            elif not filter_seen:
                filter_seen = True
                index += 1
            else:
                inputs.append(self.value(argv[index], values))
                index += 1
        return inputs, explicit_stdin, null_input

    def inspect_jq(
        self,
        argv: tuple[ShellWord, ...],
        values: dict[str, ShellOrigin],
        malformed: bool,
        piped_input: bool,
        redirected_inputs: tuple[ShellOrigin, ...] = (),
        redirected_stdin: bool = False,
    ) -> None:
        inputs, explicit_stdin, null_input = self.jq_inputs(argv, values)
        inputs[:0] = redirected_inputs
        explicit_stdin = explicit_stdin or redirected_stdin
        for origin in inputs:
            if violation := self.reader_violation(origin):
                self.violations.append(violation)
        if not inputs and not explicit_stdin and not null_input and piped_input:
            self.violations.append("unproven config reader operand")
        if malformed and (inputs or explicit_stdin):
            self.violations.append("unproven config reader operand")

    def inspect(self, commands: tuple[ShellCommand, ...], values: dict[str, ShellOrigin], calls: list[tuple[str, tuple[ShellOrigin, ...]]]) -> None:
        for command in commands:
            for word in command.words:
                if assignment := self.assignment(word):
                    origin = self.value(assignment[1], values)
                    values[assignment[0]] = origin
                    if assignment[0] == self.marker and origin.kind == "runtime-path":
                        self.marker_seeded = True
                        self.default_seeded = self.default is None or origin.value == self.default
            argv = self.argv(command.words)
            if not argv:
                continue
            executable = self.literal(argv[0])
            simple_argv, redirected_inputs, redirected_stdin = self.simple_command(command.words, values)
            if jq_argv := self.jq_invocation(simple_argv):
                self.inspect_jq(
                    jq_argv,
                    values,
                    command.malformed,
                    command.piped_input,
                    redirected_inputs,
                    redirected_stdin,
                )
            elif not (
                len(simple_argv) > 1
                and self.literal(simple_argv[0]) == "command"
                and self.literal(simple_argv[1]) in {"-v", "-V"}
            ) and any(
                (literal := self.literal(word)) == "jq"
                or (literal is not None and literal.startswith("/") and literal.rsplit("/", 1)[-1] == "jq")
                for word in simple_argv
            ):
                self.violations.append("unproven config reader operand")
            if executable in self.lexical.functions:
                calls.append((executable, tuple(self.value(word, values) for word in argv[1:])))

    def run(self) -> tuple[str, ...]:
        values: dict[str, ShellOrigin] = {}
        if self.imports_recovery:
            values.update(PIM_CAMERA_RUN_DIR=ShellOrigin("state-root", "/run/pim-camera"), PIM_CAMERA_STATE_DIR=ShellOrigin("state-root", "/var/lib/pim-camera"), **{self.marker: ShellOrigin("runtime-path", RUNTIME_PATH)})
            self.marker_seeded = True
        calls: list[tuple[str, tuple[ShellOrigin, ...]]] = []
        self.inspect(self.lexical.top, values, calls)
        snapshot = re.search(rf'''cat\s+--\s+["']?\$(?:\{{)?{re.escape(self.marker)}(?:\}})?["']?\s*>\s*["']?\$([A-Za-z_]\w*)["']?.*?exec\s+\{{([A-Za-z_]\w*)\}}\s*<\s*["']?\$\1["']?.*?([A-Za-z_]\w*)\s*=\s*["']/proc/\$\$/fd/\$(?:\{{)?\2(?:\}})?["']''', self.lexical.normalized, re.S)
        if snapshot:
            values[snapshot.group(3)] = ShellOrigin("runtime-path")
        for name, (body, _) in self.lexical.functions.items():
            if self.marker in body or "cam_validate_runtime" in body:
                count = max((int(item) for item in re.findall(r"\$(?:\{)?([1-9])", body)), default=0)
                calls.append((name, (UNKNOWN_ORIGIN,) * count))
        seen: set[tuple[str, tuple[ShellOrigin, ...]]] = set()
        while calls:
            name, arguments = calls.pop(0)
            if (name, arguments) in seen:
                continue
            seen.add((name, arguments))
            local = dict(values)
            local.update({str(index): origin for index, origin in enumerate(arguments, 1)})
            self.inspect(self.lexical.functions[name][1], local, calls)
        if self.lexical.malformed and "jq" in self.lexical.normalized:
            self.violations.append("unproven config reader operand")
        return tuple(dict.fromkeys(self.violations))


def analyze_shell_provenance(text: str, marker: str, default: str | None = None, *, allow_source: bool = False) -> ShellProvenanceResult:
    lexical = lex_shell(text)
    proof = ShellProvenanceProof(lexical, marker, default, allow_source)
    reader_violations = proof.run()
    variable_marker = SHELL_ASSIGNMENT_NAME.fullmatch(marker) is not None
    return ShellProvenanceResult(
        contract_text=lexical.contract_text,
        marker_present=proof.marker_seeded if variable_marker else marker in lexical.contract_text,
        default_present=proof.default_seeded,
        reader_violations=reader_violations,
    )


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

    def open_mode(
        call: ast.Call,
        env: dict[str, set[str]],
        positional_index: int,
    ) -> str | None:
        mode_node = (
            call.args[positional_index]
            if len(call.args) > positional_index
            else None
        )
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
        positional_parameters = list(function.args.posonlyargs) + list(
            function.args.args
        )
        positional_defaults = [None] * (
            len(positional_parameters) - len(function.args.defaults)
        ) + list(
            function.args.defaults
        )
        keyword_parameters = list(function.args.kwonlyargs)
        for parameter, default in zip(
            positional_parameters, positional_defaults, strict=True
        ):
            local_env[parameter.arg] = resolve(default, outer_env)
        for parameter, default in zip(
            keyword_parameters, function.args.kw_defaults, strict=True
        ):
            local_env[parameter.arg] = resolve(default, outer_env)
        if call is not None:
            for parameter, argument in zip(positional_parameters, call.args):
                local_env[parameter.arg] = resolve(argument, outer_env)
            keyword_values = {
                keyword.arg: resolve(keyword.value, outer_env)
                for keyword in call.keywords
                if keyword.arg is not None
            }
            for parameter in list(function.args.args) + keyword_parameters:
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
            mode_position: int | None = None
            if isinstance(node.func, ast.Name) and node.func.id == "open":
                operand = node.args[0] if node.args else None
                mode_position = 1
                if operand is None:
                    operand = next(
                        (
                            keyword.value
                            for keyword in node.keywords
                            if keyword.arg == "file"
                        ),
                        None,
                    )
            elif isinstance(node.func, ast.Attribute) and node.func.attr == "open":
                operand = node.func.value
                mode_position = 0
            elif (
                isinstance(node.func, ast.Attribute)
                and node.func.attr == "read_text"
            ):
                operand = node.func.value
            if operand is not None:
                mode = (
                    open_mode(node, env, mode_position)
                    if mode_position is not None
                    else "r"
                )
                if mode is None or "+" in mode or not mode.startswith(("w", "a", "x")):
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


def runtime_boundary_violations(
    text: str,
    marker: str,
    default: str | None = None,
    *,
    allow_source: bool = False,
) -> list[str]:
    """Audit contracts and reader operands through one authoritative front end."""
    violations: list[str] = []
    try:
        ast.parse(text)
    except SyntaxError:
        result = analyze_shell_provenance(
            text, marker, default, allow_source=allow_source
        )
        normalized_text = result.contract_text
        if not result.marker_present:
            violations.append("missing marker")
        if not result.default_present:
            violations.append("missing default")
        violations.extend(result.reader_violations)
    else:
        normalized_text = text
        if marker not in normalized_text:
            violations.append("missing marker")
        if default is not None and default not in normalized_text:
            violations.append("missing default")
        for path in python_config_read_paths(text):
            if not path.startswith("/") or not path.endswith(".json"):
                continue
            if path == RUNTIME_PATH:
                continue
            if allow_source and path.startswith("/root/shared_v/"):
                continue
            violations.append(f"alternate config read: {path}")

    for name, pattern in FORBIDDEN_CONFIG_CONTRACTS:
        if pattern.search(normalized_text) is not None:
            violations.append(name)
    if not allow_source and "/root/shared_v" in normalized_text:
        violations.append("source-root read")

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
            not any(
                item == "unproven config reader operand"
                or item.startswith("alternate config read:")
                for item in violations
            ),
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
        try:
            ast.parse(text)
        except SyntaxError:
            normalized_text = analyze_shell_provenance(
                text,
                RUNTIME_BOUNDARY_MARKERS.get(relative, "source_root"),
                allow_source=True,
            ).contract_text
        else:
            normalized_text = text
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
    double_quoted_continued_assignment = """\
ACTUAL_CONFIG="$(command printf -- %s \\
/etc/pim/camera.json)"
"""
    double_quoted_direct_assignment = """\
ACTUAL_CONFIG="/etc/pim/\\
camera.json"
"""
    nested_single_quoted_assignment = """\
ACTUAL_CONFIG="$(command printf -- %s '\\
/etc/pim/camera.json')"
"""
    inner_double_quoted_assignment = """\
ACTUAL_CONFIG="$(command printf -- %s "/etc/pim/\\
inner-double.json")"
"""
    nested_continued_assignment = """\
ACTUAL_CONFIG="$(command printf -- %s "$( (command printf -- %s /etc/pim/\\
nested.json) )")"
"""
    escaped_substitution_assignment = """\
ACTUAL_CONFIG="\\$(command printf -- %s /etc/pim/escaped.json)"
"""
    commented_substitution_assignment = f"""\
ACTUAL_CONFIG="$(
  # $(command printf -- %s /etc/pim/commented.json)
  command printf -- %s {RUNTIME_PATH}
)"
"""
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
            "unproven config reader operand",
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
            "unproven config reader operand",
        ),
        (
            "continued multiline command substitution cannot hide an alternate JSON read",
            continued_reader_fixture,
            "unproven config reader operand",
        ),
        (
            "renamed indented continued substitution cannot hide an alternate JSON read",
            renamed_continued_fixture,
            "unproven config reader operand",
        ),
        (
            "double-quoted continued substitution cannot hide an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
{double_quoted_continued_assignment}jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
''',
            "unproven config reader operand",
        ),
        (
            "double-quoted direct continuation cannot hide an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
{double_quoted_direct_assignment}jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
''',
            "alternate config read:",
        ),
        (
            "inner double-quoted continuation remains an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
{inner_double_quoted_assignment}jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
''',
            "unproven config reader operand",
        ),
        (
            "nested command-substitution continuation remains an alternate JSON read",
            f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
jq -r '.VHL_CAM.app' "$(command printf -- %s "$( (command printf -- %s /etc/pim/\\
nested.json) )")"
''',
            "unproven config reader operand",
        ),
        (
            "keyword-only helper argument cannot hide an alternate JSON read",
            f'''\
import json
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
def load(*, path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)
load(path="/etc/pim/keyword-camera.json")
''',
            "alternate config read:",
        ),
        (
            "keyword-only helper default cannot hide an alternate JSON read",
            f'''\
import json
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
def load(*, path="/etc/pim/default-camera.json"):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)
load()
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

    print("=== shell reader provenance proof boundary ===")

    def shell_reader_violations(
        fixture: str, *, allow_source: bool = False
    ) -> list[str]:
        return [
            item
            for item in runtime_boundary_violations(
                fixture,
                "PIM_CAMERA_RUNTIME_JSON",
                RUNTIME_PATH,
                allow_source=allow_source,
            )
            if item == "unproven config reader operand"
            or item.startswith("alternate config read:")
        ]

    reviewer_direct_assignment = """\
REVIEWED_INPUT="$(command printf -- %s '\\
/etc/pim/direct-data.json')"
"""
    reviewer_direct_fixture = f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . "$(command printf -- %s '\\
/etc/pim/direct-data.json')"
'''
    check(
        shell_reader_violations(reviewer_direct_fixture)
        == ["unproven config reader operand"],
        "nested single-quoted reader data is rejected without inventing an alternate path",
        failures,
    )

    reviewer_nested_assignment = """\
REVIEWED_INPUT="$(printf %s "$(printf %s /var/lib/pim/\\
reviewed-nested.json)")"
"""
    reviewer_nested_fixture = f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
{reviewer_nested_assignment}jq -r . "$REVIEWED_INPUT"
'''
    check(
        shell_reader_violations(reviewer_nested_fixture)
        == ["unproven config reader operand"],
        "nested static substitution is rejected as unproven instead of recursively authorized",
        failures,
    )

    provenance_allow_cases = (
        (
            "exact runtime literal remains an approved reader operand",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . "{RUNTIME_PATH}"
''',
            False,
        ),
        (
            "reviewed runtime variable remains an approved reader operand",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . "$PIM_CAMERA_RUNTIME_JSON"
''',
            False,
        ),
        (
            "simple runtime alias retains approved provenance",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
REVIEWED_INPUT="$PIM_CAMERA_RUNTIME_JSON"
jq -r . "$REVIEWED_INPUT"
''',
            False,
        ),
        (
            "immutable runtime content snapshot remains approved through jq stdin",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
runtime_json=$(<"$PIM_CAMERA_RUNTIME_JSON") || exit 64
jq -r . <<<"$runtime_json"
''',
            False,
        ),
        (
            "approved runtime path remains approved through jq input redirect",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . < "$PIM_CAMERA_RUNTIME_JSON"
''',
            False,
        ),
        (
            "leading approved runtime input remains approved before jq",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
< "$PIM_CAMERA_RUNTIME_JSON" jq -r .
''',
            False,
        ),
        (
            "leading approved runtime content remains approved before jq",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
runtime_json=$(<"$PIM_CAMERA_RUNTIME_JSON") || exit 64
<<<"$runtime_json" jq -r .
''',
            False,
        ),
        (
            "and-or control operators do not create pipe provenance",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
false || jq -r .
true && jq -r .
''',
            False,
        ),
        (
            "leading output redirects do not become jq input sources",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
>"/tmp/jq.out" 2>"/tmp/jq.err" jq -n -r .
''',
            False,
        ),
        (
            "jq short null-input mode requires no file or stdin authority",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -n -r .
''',
            False,
        ),
        (
            "jq long null-input mode requires no file or stdin authority",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq --null-input -r .
''',
            False,
        ),
        (
            "proven source alias remains narrowly approved for a source owner",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
SOURCE_INPUT="/root/shared_v/edgeconf_20260908.json"
jq -r . "$SOURCE_INPUT"
''',
            True,
        ),
    )
    for label, fixture, allow_source in provenance_allow_cases:
        check(
            shell_reader_violations(fixture, allow_source=allow_source) == [],
            label,
            failures,
        )

    provenance_reject_cases = (
        (
            "literal alternate alias cannot inherit runtime authority",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
REVIEWED_INPUT="/etc/pim/alias.json"
jq -r . "$REVIEWED_INPUT"
''',
            False,
            ["alternate config read: /etc/pim/alias.json"],
        ),
        (
            "command-substitution alias cannot be recursively authorized",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
REVIEWED_INPUT="$(printf %s /etc/pim/substituted.json)"
jq -r . "$REVIEWED_INPUT"
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "unresolved variable alias fails closed at the reader boundary",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
REVIEWED_INPUT="$UNRESOLVED_RUNTIME_JSON"
jq -r . "$REVIEWED_INPUT"
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "concatenated mixed alias fails closed at the reader boundary",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
REVIEWED_INPUT="/etc/pim/"'mixed.json'
jq -r . "$REVIEWED_INPUT"
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "decoy runtime marker cannot authorize a different reader operand",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . "/etc/pim/decoy.json"
''',
            False,
            ["alternate config read: /etc/pim/decoy.json"],
        ),
        (
            "malformed quoted operand fails closed at the reader boundary",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
REVIEWED_INPUT="$PIM_CAMERA_RUNTIME_JSON"
jq -r . "$REVIEWED_INPUT
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "alternate content snapshot cannot feed jq under runtime authority",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
runtime_json=$(<"/etc/pim/alternate-snapshot.json")
jq -r . <<<"$runtime_json"
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "source authority cannot approve an unresolved reader operand",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
SOURCE_INPUT="$UNRESOLVED_SOURCE_JSON"
jq -r . "$SOURCE_INPUT"
''',
            True,
            ["unproven config reader operand"],
        ),
        (
            "unknown jq here-string input fails closed",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . <<<"$UNRESOLVED_JSON"
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "literal alternate jq input redirect is rejected precisely",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . < "/etc/pim/redirect.json"
''',
            False,
            ["alternate config read: /etc/pim/redirect.json"],
        ),
        (
            "unknown jq input redirect fails closed",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . < "$UNRESOLVED_JSON"
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "source authority cannot approve an unknown jq here-string",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
jq -r . <<<"$UNRESOLVED_JSON"
''',
            True,
            ["unproven config reader operand"],
        ),
        (
            "command-prefixed jq cannot hide an alternate reader",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
command jq -r . "/etc/pim/command-prefix.json"
''',
            False,
            ["alternate config read: /etc/pim/command-prefix.json"],
        ),
        (
            "command double-dash jq cannot hide an alternate reader",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
command -- jq -r . "/etc/pim/command-double-dash.json"
''',
            False,
            ["alternate config read: /etc/pim/command-double-dash.json"],
        ),
        (
            "absolute jq executable cannot hide an alternate reader",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
/usr/bin/jq -r . "/etc/pim/absolute-jq.json"
''',
            False,
            ["alternate config read: /etc/pim/absolute-jq.json"],
        ),
        (
            "ignored validator failure cannot upgrade alternate provenance",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
PIM_LIB=/opt/pim/lib
. "$PIM_LIB/cam_recovery_actions.sh"
EVIL="/etc/pim/validator.json"
cam_validate_runtime "$EVIL" || true
jq -r . "$EVIL"
''',
            False,
            ["alternate config read: /etc/pim/validator.json"],
        ),
        (
            "bare validator call cannot upgrade unresolved provenance",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
PIM_LIB=/opt/pim/lib
. "$PIM_LIB/cam_recovery_actions.sh"
EVIL="$UNRESOLVED_JSON"
cam_validate_runtime "$EVIL"
jq -r . "$EVIL"
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "jq pipe without proven input origin fails closed",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
printf '%s\\n' '{{}}' | jq -r .
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "multiline pipe cannot lose jq input provenance",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
cat "/etc/pim/multiline-pipe.json" |
  jq -r .
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "multiline stderr pipe cannot lose jq input provenance",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
cat "/etc/pim/multiline-pipe-stderr.json" |&
  jq -r .
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "blank and comment lines cannot clear pending pipe provenance",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
cat "/etc/pim/commented-pipe.json" |

  # the right-hand command is intentionally separated
  jq -r .
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "leading alternate input before direct jq is rejected precisely",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
< "/etc/pim/prefix-direct.json" jq -r .
''',
            False,
            ["alternate config read: /etc/pim/prefix-direct.json"],
        ),
        (
            "leading unknown content before direct jq fails closed",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
<<<"$UNKNOWN_JSON" jq -r .
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "leading alternate input composes with command jq",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
< "/etc/pim/prefix-command.json" command -- jq -r .
''',
            False,
            ["alternate config read: /etc/pim/prefix-command.json"],
        ),
        (
            "leading unknown content composes with command jq",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
<<<"$UNKNOWN_JSON" command -- jq -r .
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "leading alternate input composes with absolute jq",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
< "/etc/pim/prefix-absolute.json" /usr/bin/jq -r .
''',
            False,
            ["alternate config read: /etc/pim/prefix-absolute.json"],
        ),
        (
            "leading unknown content composes with absolute jq",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
<<<"$UNKNOWN_JSON" /usr/bin/jq -r .
''',
            False,
            ["unproven config reader operand"],
        ),
        (
            "leading output redirects stay separate from jq file inputs",
            f'''\
PIM_CAMERA_RUNTIME_JSON="{RUNTIME_PATH}"
>"/tmp/jq.out" jq -r . "/etc/pim/after-output-prefix.json"
''',
            False,
            ["alternate config read: /etc/pim/after-output-prefix.json"],
        ),
    )
    for label, fixture, allow_source, expected in provenance_reject_cases:
        check(
            shell_reader_violations(fixture, allow_source=allow_source) == expected,
            label,
            failures,
        )

    reviewer_shell_oracles = (
        (
            "Bash preserves reviewer nested single-quoted reader bytes",
            reviewer_direct_assignment,
            b"\\\n/etc/pim/direct-data.json",
        ),
        (
            "Bash resolves reviewer nested substitution to the alternate path",
            reviewer_nested_assignment,
            b"/var/lib/pim/reviewed-nested.json",
        ),
    )
    for label, assignment, expected_stdout in reviewer_shell_oracles:
        oracle = subprocess.run(
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-c",
                assignment + 'printf %s "$REVIEWED_INPUT"\n',
            ],
            capture_output=True,
            timeout=5,
            env={"BASH_ENV": "/dev/null", "PATH": "/usr/bin:/bin"},
            check=False,
        )
        check(
            oracle.returncode == 0
            and oracle.stdout == expected_stdout
            and oracle.stderr == b"",
            label,
            failures,
        )

    nested_single_quoted_fixture = f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
{nested_single_quoted_assignment}jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
'''
    check(
        not any(
            item.startswith("alternate config read:")
            for item in runtime_boundary_violations(
                nested_single_quoted_fixture,
                "PIM_CAMERA_RUNTIME_JSON",
                RUNTIME_PATH,
            )
        ),
        "nested single-quoted continuation remains data, not an alternate read",
        failures,
    )

    for label, assignment in (
        (
            "escaped command-substitution opener remains literal data",
            escaped_substitution_assignment,
        ),
        (
            "commented command-substitution opener remains non-executable",
            commented_substitution_assignment,
        ),
    ):
        fixture = f'''\
PIM_CAMERA_RUNTIME_JSON="${{PIM_CAMERA_RUNTIME_JSON:-{RUNTIME_PATH}}}"
{assignment}jq -r '.VHL_CAM.app' "$ACTUAL_CONFIG"
'''
        check(
            not any(
                item.startswith("alternate config read:")
                for item in runtime_boundary_violations(
                    fixture,
                    "PIM_CAMERA_RUNTIME_JSON",
                    RUNTIME_PATH,
                )
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

    double_quoted_bash_result = subprocess.run(
        [
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-c",
            double_quoted_continued_assignment
            + 'printf "%s\\n" "$ACTUAL_CONFIG"\n'
            + double_quoted_direct_assignment
            + 'printf "%s\\n" "$ACTUAL_CONFIG"\n',
        ],
        capture_output=True,
        text=True,
        timeout=5,
        env={"BASH_ENV": "/dev/null", "PATH": "/usr/bin:/bin"},
        check=False,
    )
    check(
        double_quoted_bash_result.returncode == 0
        and double_quoted_bash_result.stdout
        == "/etc/pim/camera.json\n/etc/pim/camera.json\n"
        and double_quoted_bash_result.stderr == "",
        "Bash evaluates both double-quoted continuations to alternate paths",
        failures,
    )

    nested_shell_oracles = (
        (
            "Bash preserves the nested single-quoted backslash and newline",
            nested_single_quoted_assignment,
            "\\\n/etc/pim/camera.json",
        ),
        (
            "Bash removes an inner double-quoted continuation",
            inner_double_quoted_assignment,
            "/etc/pim/inner-double.json",
        ),
        (
            "Bash removes a continuation in a nested command substitution",
            nested_continued_assignment,
            "/etc/pim/nested.json",
        ),
        (
            "Bash keeps an escaped command-substitution opener literal",
            escaped_substitution_assignment,
            "$(command printf -- %s /etc/pim/escaped.json)",
        ),
        (
            "Bash ignores a commented command-substitution opener",
            commented_substitution_assignment,
            RUNTIME_PATH,
        ),
    )
    for label, assignment, expected_stdout in nested_shell_oracles:
        oracle = subprocess.run(
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-c",
                assignment + 'printf %s "$ACTUAL_CONFIG"\n',
            ],
            capture_output=True,
            text=True,
            timeout=5,
            env={"BASH_ENV": "/dev/null", "PATH": "/usr/bin:/bin"},
            check=False,
        )
        check(
            oracle.returncode == 0
            and oracle.stdout == expected_stdout
            and oracle.stderr == "",
            label,
            failures,
        )

    path_open_mode_cases = (
        ("default", "", True),
        ("positional read", '"r"', True),
        ("keyword read", 'mode="r"', True),
        ("read-write", '"w+"', True),
        ("pure write", '"w"', False),
        ("pure append", '"a"', False),
        ("pure create", '"x"', False),
    )
    for index, (label, arguments, expected_read) in enumerate(
        path_open_mode_cases
    ):
        alternate_path = f"/etc/pim/inline-{index}.json"
        fixture = f'''\
from pathlib import Path
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
Path("{alternate_path}").open({arguments}).close()
'''
        violation = f"alternate config read: {alternate_path}"
        violations = runtime_boundary_violations(
            fixture,
            "PIM_CAMERA_RUNTIME_JSON",
            RUNTIME_PATH,
        )
        check(
            (violation in violations) == expected_read,
            f"inline Path.open {label} mode has callable-specific read semantics",
            failures,
        )

    builtin_open_mode_cases = (
        ("default", "", True),
        ("positional read", ', "r"', True),
        ("keyword read", ', mode="r"', True),
        ("read-write r+", ', "r+"', True),
        ("read-write w+", ', "w+"', True),
        ("pure write", ', "w"', False),
        ("pure append", ', "a"', False),
        ("pure create", ', "x"', False),
    )
    for index, (label, suffix, expected_read) in enumerate(
        builtin_open_mode_cases
    ):
        alternate_path = f"/etc/pim/builtin-{index}.json"
        fixture = f'''\
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
open("{alternate_path}"{suffix}).close()
'''
        violation = f"alternate config read: {alternate_path}"
        violations = runtime_boundary_violations(
            fixture,
            "PIM_CAMERA_RUNTIME_JSON",
            RUNTIME_PATH,
        )
        check(
            (violation in violations) == expected_read,
            f"built-in open {label} mode retains read semantics",
            failures,
        )

    path_open_write_fixture = f'''\
from pathlib import Path
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
Path("/etc/pim/camera.json").open("w").close()
'''
    check(
        not any(
            item.startswith("alternate config read:")
            for item in runtime_boundary_violations(
                path_open_write_fixture,
                "PIM_CAMERA_RUNTIME_JSON",
                RUNTIME_PATH,
            )
        ),
        "Path.open positional write mode is not classified as a read",
        failures,
    )

    builtin_open_write_fixture = f'''\
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
open("/etc/pim/camera.json", "w").close()
'''
    check(
        not any(
            item.startswith("alternate config read:")
            for item in runtime_boundary_violations(
                builtin_open_write_fixture,
                "PIM_CAMERA_RUNTIME_JSON",
                RUNTIME_PATH,
            )
        ),
        "built-in open positional write mode remains write-only",
        failures,
    )

    path_read_text_fixture = f'''\
from pathlib import Path
PIM_CAMERA_RUNTIME_JSON = "{RUNTIME_PATH}"
Path("/etc/pim/camera.json").read_text(encoding="utf-8")
'''
    check(
        any(
            item.startswith("alternate config read:")
            for item in runtime_boundary_violations(
                path_read_text_fixture,
                "PIM_CAMERA_RUNTIME_JSON",
                RUNTIME_PATH,
            )
        ),
        "Path.read_text remains a read regardless of encoding",
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
