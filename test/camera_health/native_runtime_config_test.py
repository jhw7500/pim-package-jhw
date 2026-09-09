#!/usr/bin/env python3
"""Guard the native consumers' fixed-file, validated, single-root contract.

These source-shape tests intentionally run without a host json-c/SDK dependency.
They reject discovery, extra opens, unsafe/misordered object guards, and missing
or duplicate releases. They do not claim to execute the target parsers.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = "/run/pim-camera/config/pim_runtime.json"
LEXICAL = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*.*?\*/', re.S)


def source(text):
    """Ignore comments without treating comment markers inside strings as code."""
    return LEXICAL.sub(lambda m: " " if m[0].startswith(("//", "/*")) else m[0], text)


def mask_strings(text):
    return LEXICAL.sub(lambda m: " " * len(m[0]), text)


def compact(text):
    return re.sub(r"\s+", "", text)


def closing(text, start, left="{", right="}"):
    masked = mask_strings(text)
    depth = 0
    for pos in range(start, len(text)):
        if masked[pos] == left:
            depth += 1
        elif masked[pos] == right:
            depth -= 1
            if depth == 0:
                return pos
    raise AssertionError("unbalanced C++ block in source contract")


def config_body(text):
    matches = list(re.finditer(r"\bint\s+CTCPServer::get_json_config\s*\(\s*\)\s*\{", text))
    if len(matches) != 1:
        raise AssertionError("expected exactly one get_json_config definition")
    start = matches[0].end() - 1
    return text[start + 1:closing(text, start)]


def guards(text):
    """Return complete top-level braced ifs, retaining positions for ordering."""
    result = []
    offset = 0
    while match := re.search(r"\bif\s*\(", mask_strings(text)[offset:]):
        start = offset + match.start()
        paren = offset + match.end() - 1
        end_condition = closing(text, paren, "(", ")")
        brace = end_condition + 1
        while brace < len(text) and text[brace].isspace():
            brace += 1
        if brace >= len(text) or text[brace] != "{":
            raise AssertionError("validation guard must be a braced early return")
        end = closing(text, brace)
        result.append((compact(text[paren + 1:end_condition]), text[brace + 1:end], start, end))
        offset = end + 1
    return result


def top_level_statements(text):
    """Split this contract's simple statements and opaque braced controls.

    This is a lexical boundary check, not a general C++ parser/preprocessor.
    Balanced parentheses/brackets are consumed whole (including for-header
    semicolons). An unbraced if/while/for stays attached to its governed
    statement regardless of whitespace. Strings/comments cannot add boundaries.
    """
    masked = mask_strings(text)
    result = []
    start = pos = 0
    while pos < len(text):
        char = masked[pos]
        if char in "([":
            pos = closing(text, pos, char, {"(": ")", "[": "]"}[char]) + 1
            continue
        if char == "{":
            pos = closing(text, pos) + 1
        elif char == ";":
            pos += 1
        else:
            pos += 1
            continue
        result.append(compact(text[start:pos]))
        start = pos
    if masked[start:].strip():
        raise AssertionError("incomplete statement in native source contract")
    return result


class NativeRuntimeContract:
    def setUp(self):
        self.header = source((ROOT / self.tree / "util.h").read_text())
        self.cpp = source((ROOT / self.tree / "tcpServer.cpp").read_text())
        self.body = config_body(self.cpp)

    def root(self):
        opens = re.findall(r"\b(\w+)\s*=\s*json_object_from_file\s*\(\s*PIM_RUNTIME_JSON_FILE\s*\)\s*;", self.body)
        self.assertEqual(len(opens), 1, "one assigned runtime open is required")
        return opens[0]

    def validation(self):
        field = re.search(r"\bjson_object_get_value\s*\(", self.body)
        self.assertIsNotNone(field, "existing field extraction must remain")
        prefix = self.body[:field.start()]
        # The first extraction can be in its own one-line if; only inspect
        # complete validation guards before the first hobj field-selection.
        selection = re.search(r"^\s*hobj\s*=\s*(\w+)\s*;", prefix, re.M)
        self.assertIsNotNone(selection, "select a validated object before reading fields")
        return prefix[:selection.start()], guards(prefix[:selection.start()])

    def test_fixed_runtime_macro(self):
        definitions = re.findall(r'^\s*#\s*define\s+PIM_RUNTIME_JSON_FILE\s+([^\n]+)', self.header, re.M)
        self.assertEqual(definitions, ['"' + RUNTIME + '"'])

    def test_no_legacy_config_access(self):
        for path in sorted((ROOT / self.tree).glob("*")):
            if path.suffix not in (".cpp", ".h"):
                continue
            code = source(path.read_text())
            for forbidden in ("/root/shared_v", "/tmp/shared_v", "EDGE_JSON_FILE", "ORD_VCM_JSON_FILE", "PATH_JSON_LOCAL"):
                with self.subTest(file=path.name, forbidden=forbidden):
                    self.assertFalse(forbidden in code, f"{path.name}: obsolete config reference {forbidden}")
            if path.name not in ("util.h", "util.cpp"):
                self.assertIsNone(re.search(r"\bsearch_json_file\s*\(", code), f"{path.name}: config discovery call remains")

    def test_opens_one_owned_root(self):
        root = self.root()
        self.assertEqual(len(re.findall(r"\bjson_object_from_file\s*\(", self.body)), 1)
        assignments = re.findall(r"\b" + re.escape(root) + r"\s*=(?!=)\s*([^;]+);", self.body)
        self.assertTrue(all(value.strip() in ("NULL", "nullptr", "json_object_from_file(PIM_RUNTIME_JSON_FILE)") for value in assignments), "owned root must not be reassigned or aliased")

    def test_unreadable_and_nonobject_root_fail_before_lookup(self):
        root = self.root()
        prefix, checks = self.validation()
        self.assertEqual(len(checks), 3, "null root, root type, required-member guards")
        self.assertEqual(checks[0][0], "!" + root)
        self.assertEqual(checks[1][0], f"!json_object_is_type({root},json_type_object)")
        opened = re.search(rf"\b{root}\s*=\s*json_object_from_file\s*\(\s*PIM_RUNTIME_JSON_FILE\s*\)\s*;", prefix)
        self.assertIsNotNone(opened, "runtime open must precede field selection")
        self.assertLess(opened.end(), checks[0][2], "runtime open must execute before the null guard")
        self.assertLess(checks[0][3], checks[1][2], "null guard must precede root-type validation")
        statements = top_level_statements(prefix)
        self.assertIn(compact(opened[0]), statements, "runtime open must be an unconditional statement")
        for _, _, start, end in checks:
            self.assertIn(compact(prefix[start:end + 1]), statements,
                          "validation guards must execute at function top level")
        first_lookup = prefix.find("json_object_object_get(")
        self.assertGreater(first_lookup, checks[1][3], "root validation must precede member lookup")

    def test_every_required_member_is_validated_before_fields(self):
        root = self.root()
        prefix, checks = self.validation()
        self.assertEqual(len(checks), 3)
        expected_terms = []
        for macro, name in (("JSON_HEADER_VHL", "VHL_CAM"), ("JSON_HEADER_ORD", "ORD"), ("JSON_HEADER_VCM", "VCM")):
            with self.subTest(member=name):
                self.assertRegex(self.header, rf'#define\s+{macro}\s+"{name}"')
                lookups = list(re.finditer(rf"\b(?:json_object\s*\*\s*)?(\w+)\s*=\s*json_object_object_get\s*\(\s*{root}\s*,\s*{macro}\s*\)\s*;", prefix))
                self.assertEqual(len(lookups), 1, f"{name} must be borrowed from the one root")
                self.assertGreater(lookups[0].start(), checks[1][3])
                self.assertLess(lookups[0].end(), checks[2][2])
                self.assertIn(compact(lookups[0][0]), top_level_statements(prefix),
                              f"{name} lookup must execute before its guard")
                child = lookups[0][1]
                expected_terms.extend(("!" + child, f"!json_object_is_type({child},json_type_object)"))
        # Exact OR terms catch a dropped object/null check, wrong type, AND,
        # negation reversal, and unrelated/comment-only validation.
        self.assertCountEqual(checks[2][0].split("||"), expected_terms)

    def test_each_failure_logs_path_and_releases_only_owned_root(self):
        root = self.root()
        _, checks = self.validation()
        self.assertEqual(len(checks), 3)
        for index, (_, block, _, _) in enumerate(checks):
            with self.subTest(failure=("unreadable", "root-type", "member-type")[index]):
                # No nested branch can bypass logging, cleanup or failure.
                expected = r'\s*__LOG\s*\([^;]*,\s*PIM_RUNTIME_JSON_FILE\s*\)\s*;\s*'
                if index:
                    expected += rf'json_object_put\s*\(\s*{root}\s*\)\s*;\s*'
                expected += r'return\s+-1\s*;\s*'
                self.assertRegex(block, "^" + expected + "$", "failure must log fixed path and release the root exactly once")
        puts = re.findall(r"\bjson_object_put\s*\(\s*(\w+)\s*\)", self.body)
        self.assertEqual(puts, [root, root, root], "two failure releases and one success release; no borrowed-child puts")
        self.assertEqual(re.findall(r"\breturn\s+([^;]+);", self.body), ["-1", "-1", "-1", "0"], "every return path must be covered")
        # Remove guarded failures and require the final release at top level.
        remainder = self.body
        for _, _, start, end in reversed(checks):
            remainder = remainder[:start] + remainder[end + 1:]
        self.assertEqual(top_level_statements(remainder)[-2:],
                         [f"json_object_put({root});", "return0;"],
                         "success cleanup and return must be unconditional top-level statements")
        self.assertNotRegex(remainder, r"\b(?:goto|throw)\b", "no unchecked exit bypasses root release")


class OrdRuntimeContract(NativeRuntimeContract, unittest.TestCase):
    tree = "ord"


class VcmRuntimeContract(NativeRuntimeContract, unittest.TestCase):
    tree = "vcm"

    def test_ip_string_is_copied_before_root_release(self):
        self.assertRegex(self.body, r'if\s*\(json_object_get_value\(hobj,\s*"ip_static",\s*&tmp_str\)\s*==\s*0\)\s*snprintf\(_TVcmConf.ip_addr,\s*sizeof\(_TVcmConf.ip_addr\),\s*"%s",\s*tmp_str\);', "ip_static must populate owned, terminated storage, not store a borrowed pointer in the char array")


class ControlFlowMutationRegressions(unittest.TestCase):
    """Exercise the real checker with broken bodies, never edit C++ fixtures."""

    def replace_once(self, body, pattern, replacement):
        mutated, count = re.subn(pattern, lambda match: replacement(match), body)
        self.assertEqual(count, 1, "the intended source mutation must apply exactly once")
        self.assertNotEqual(mutated, body, "the mutation must change the fixture")
        return mutated

    def rejected_by(self, contract, body):
        rejected = []
        for method in unittest.defaultTestLoader.getTestCaseNames(contract):
            case = contract(method)
            case.setUp()
            case.body = source(body)
            try:
                getattr(case, method)()
            except AssertionError:
                rejected.append(method)
        return rejected

    def test_success_cleanup_cannot_be_governed_by_unbraced_control(self):
        for contract in (OrdRuntimeContract, VcmRuntimeContract):
            case = contract()
            case.setUp()
            for control in ("if (false)", "while (false)", "for (; false;)"):
                for separator in (" ", "\n\t"):
                    with self.subTest(tree=case.tree, control=control, separator=repr(separator)):
                        body = self.replace_once(
                            case.body, r"json_object_put\(pJsonObject\);(?=\s*return 0;\s*$)",
                            lambda match: control + separator + match[0],
                        )
                        self.assertTrue(self.rejected_by(contract, body),
                                        f"{case.tree}: {control!r} success cleanup leaks the root but escaped every check")

    def test_runtime_open_cannot_follow_root_validation(self):
        for contract in (OrdRuntimeContract, VcmRuntimeContract):
            with self.subTest(tree=contract.tree):
                case = contract()
                case.setUp()
                assignment = "pJsonObject = json_object_from_file(PIM_RUNTIME_JSON_FILE);"
                body = self.replace_once(case.body, re.escape(assignment), lambda match: "")
                body = self.replace_once(body, r"\bjson_object\s*\*vhlObject\b",
                                         lambda match: assignment + "\n\t" + match[0])
                self.assertTrue(self.rejected_by(contract, body),
                                f"{case.tree}: open after root guards rejects every startup but escaped every check")

    def test_unconditional_cleanup_allows_comment_and_string_decoys(self):
        for contract in (OrdRuntimeContract, VcmRuntimeContract):
            with self.subTest(tree=contract.tree):
                case = contract()
                case.setUp()
                body = self.replace_once(
                    case.body, r"json_object_put\(pJsonObject\);(?=\s*return 0;\s*$)",
                    lambda match: 'const char* decoy = "if (false) { ; } while (false)";\n'
                    '/* for (; false;) */\n' + match[0],
                )
                self.assertEqual(self.rejected_by(contract, body), [],
                                 "comment/string control tokens must not govern a real unconditional release")


class SuiteWiring(unittest.TestCase):
    def test_runs_native_contract_once(self):
        lines = (ROOT / "test/camera_health/run_all.sh").read_text().splitlines()
        self.assertEqual(sum(line.strip() == "python3 native_runtime_config_test.py" for line in lines), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
