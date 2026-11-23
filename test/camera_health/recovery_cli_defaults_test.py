#!/usr/bin/env python3
"""Exercise the real recovery CLI with a recording library; no board actions."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get(
    "RECOVERYCTL_TEST_CLI", ROOT / "dist/pim/opt/pim/bin/cam-recoveryctl"
))
REQUEST_ID = "11111111-2222-3333-4444-555555555555"
STUB = r'''
_cr_request_type() {
    case "$1" in
        gstapp_restart|gstapp_stop|module_reload|camera_hard_reset|reboot_fallback|apply_config) return 0;;
        *) return 1;;
    esac
}
cam_request_submit() {
    printf '%s\0' "$@" >> "$REQUEST_LOG"
    [ "$SUBMIT_RC" -eq 0 ] || return "$SUBMIT_RC"
    printf '%s\n' "$REQUEST_ID"
}
cam_recovery_status_json() {
    printf '%s\0' "$@" >> "$STATUS_LOG"
    case "$STATUS_MODE" in
        success) printf '{"status":"SUCCEEDED","rc":0}\n';;
        failure) printf '{"status":"FAILED","rc":70}\n';;
        pending) return 69;;
        error) return 70;;
    esac
}
'''


class RecoveryCliDefaultsTest(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix="pim-recovery-cli-")
        self.addCleanup(work.cleanup)
        self.work = Path(work.name)
        (self.work / "cam_recovery.sh").write_text(STUB)
        self.request_log = self.work / "request"
        self.status_log = self.work / "status"

    def drive(self, *args, status="success", submit_rc=0):
        self.request_log.write_bytes(b"")
        self.status_log.write_bytes(b"")
        return subprocess.run(
            ["bash", str(CLI), *args], capture_output=True, timeout=5,
            env={
                "PATH": os.environ["PATH"], "PIM_LIB": str(self.work),
                "REQUEST_LOG": str(self.request_log),
                "STATUS_LOG": str(self.status_log),
                "REQUEST_ID": REQUEST_ID, "STATUS_MODE": status,
                "SUBMIT_RC": str(submit_rc),
            },
        )

    def assert_request(self, action, source="operator", reason=None):
        if reason is None:
            reason = f"manual {action}"
        self.assertEqual(
            self.request_log.read_bytes(),
            b"\0".join(value.encode() for value in (action, source, reason)) + b"\0",
        )

    def assert_no_wait(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{REQUEST_ID}\n".encode())
        self.assertEqual(result.stderr, b"")
        self.assertEqual(self.status_log.read_bytes(), b"")

    def test_default_restart(self):
        result = self.drive("request", "restart")
        self.assert_no_wait(result)
        self.assert_request("gstapp_restart")

    def test_canonical_actions_aliases_and_apply_config(self):
        aliases = {
            "restart": "gstapp_restart", "stop": "gstapp_stop",
            "module": "module_reload", "hard": "camera_hard_reset",
            "reboot": "reboot_fallback",
        }
        for alias, action in aliases.items():
            for given in (alias, action):
                with self.subTest(action=given):
                    self.assert_no_wait(self.drive("request", given))
                    self.assert_request(action)
        self.assert_no_wait(self.drive("apply-config"))
        self.assert_request("apply_config")

    def test_each_metadata_option_can_be_omitted(self):
        for args, action in ((["request", "restart"], "gstapp_restart"),
                             (["apply-config"], "apply_config")):
            with self.subTest(command=args):
                self.assert_no_wait(self.drive(*args, "--source", "maintenance"))
                self.assert_request(action, source="maintenance")
                self.assert_no_wait(self.drive(*args, "--reason", "operator requested"))
                self.assert_request(action, reason="operator requested")

    def test_explicit_values_preserved_exactly(self):
        for source, reason in (("liveness", "gstapp process absent"),
                               (" ops \n", "capture check\nsecond line\n")):
            for args, action in ((["request", "restart"], "gstapp_restart"),
                                 (["apply-config"], "apply_config")):
                with self.subTest(command=args, source=source):
                    self.assert_no_wait(self.drive(
                        *args, "--reason", reason, "--source", source,
                    ))
                    self.assert_request(action, source, reason)

    def test_invalid_arguments_do_not_submit(self):
        for args in ([], ["request"], ["request", "unknown"],
                     ["request", "reboot\n"], ["request", "apply_config"]):
            with self.subTest(args=args):
                result = self.drive(*args)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(self.request_log.read_bytes(), b"")
        for command in (["request", "restart"], ["apply-config"]):
            for options in (["--source", ""], ["--reason", ""], ["--source"],
                            ["--reason"], ["--wait"], ["--wait", "invalid"],
                            ["--wait", "-1"], ["--unknown"]):
                with self.subTest(command=command, options=options):
                    result = self.drive(*command, *options)
                    self.assertEqual(result.returncode, 64)
                    self.assertEqual(result.stdout, b"")
                    self.assertIn(b"usage:", result.stderr)
                    self.assertEqual(self.request_log.read_bytes(), b"")
                    self.assertEqual(self.status_log.read_bytes(), b"")

    def test_wait_result_and_timeout_contract(self):
        for args, action in ((["request", "restart"], "gstapp_restart"),
                             (["apply-config"], "apply_config")):
            for mode, rc in (("success", 0), ("failure", 70),
                             ("pending", 124), ("error", 70)):
                with self.subTest(command=args, mode=mode):
                    result = self.drive(*args, "--wait", "0", status=mode)
                    self.assertEqual(result.returncode, rc, result.stderr)
                    self.assert_request(action)
                    self.assertEqual(self.status_log.read_bytes(), REQUEST_ID.encode() + b"\0")
                    self.assertEqual(result.stderr, (
                        f"CAM_RECOVERY_SUBMITTED id={REQUEST_ID} type={action} "
                        "(waiting up to 0s)\n"
                    ).encode())
                    expected = b""
                    if mode in ("success", "failure"):
                        state = "SUCCEEDED" if mode == "success" else "FAILED"
                        expected = (
                            f"CAM_RECOVERY_RESULT id={REQUEST_ID} type={action} "
                            f"status={state} rc={rc}\n"
                        ).encode()
                    self.assertEqual(result.stdout, expected)

    def test_submission_errors_do_not_wait(self):
        for rc in (64, 69, 70, 75):
            for wait in ([], ["--wait", "0"]):
                with self.subTest(rc=rc, wait=wait):
                    result = self.drive("request", "restart", *wait, submit_rc=rc)
                    self.assertEqual(result.returncode, rc)
                    self.assert_request("gstapp_restart")
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(result.stderr, b"")
                    self.assertEqual(self.status_log.read_bytes(), b"")


if __name__ == "__main__":
    unittest.main()
