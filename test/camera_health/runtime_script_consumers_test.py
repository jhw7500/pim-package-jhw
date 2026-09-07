#!/usr/bin/env python3
"""Hermetic executable tests for deployed camera runtime consumers."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Mapping, Sequence


ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "dist/pim/opt/pim/bin"


def runtime_document(**vhl: object) -> dict[str, object]:
    return {"VHL_CAM": dict(vhl), "ORD": {}, "VCM": {}, "ETC": {}}


class Tests:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0
        jq = shutil.which("jq")
        if jq is None:
            raise RuntimeError("jq is required for the executable fixtures")
        self.real_jq = jq

    def check(self, condition: bool, label: str) -> None:
        if condition:
            self.passed += 1
            print(f"  OK   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}", file=sys.stderr)

    @staticmethod
    def write_json(path: Path, document: Mapping[str, object]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document, indent=2), encoding="utf-8")

    def fake_bin(self, root: Path) -> Path:
        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        dispatcher = fake_bin / "dispatcher"
        dispatcher.write_text(
            """#!/usr/bin/env bash
cmd=${0##*/}
{
    printf '%s' "$cmd"
    for arg in "$@"; do printf ' <%s>' "$arg"; done
    printf '\n'
} >> "$PIM_TEST_EVENT_LOG"
case "$cmd" in
    logger|flock)
        exit 0
        ;;
    sleep)
        if [ "${1:-}" = 60 ] && [ "${PIM_TEST_REMOVE_DURING_BACKOFF:-0}" = 1 ]; then
            rm -rf -- "$PIM_SD_PRESENT_PATH"
            : > "${PIM_SD_PRESENT_PATH}.removed"
        elif [ "${1:-}" = 3 ] && [ -f "${PIM_SD_PRESENT_PATH:-}.removed" ]; then
            mkdir -p "$PIM_SD_PRESENT_PATH"
            rm -f -- "${PIM_SD_PRESENT_PATH}.removed"
        elif [ "${PIM_TEST_PRESENT_AFTER_SLEEP:-0}" = 1 ] && [ -n "${PIM_SD_PRESENT_PATH:-}" ]; then
            mkdir -p "$PIM_SD_PRESENT_PATH"
        fi
        /bin/sleep "${PIM_TEST_SLEEP_SEC:-0.02}"
        exit 0
        ;;
    systemctl)
        case "${1:-}" in
            is-active) printf '%s\n' "${PIM_TEST_CAM_ACTIVE:-active}"; exit 0 ;;
            is-enabled) printf '%s\n' "${PIM_TEST_CAM_ENABLED:-enabled}"; exit 0 ;;
            stop) exit "${PIM_TEST_STOP_RC:-0}" ;;
            start|restart) exit 0 ;;
        esac
        exit 0
        ;;
    umount)
        if [ -n "${PIM_SD_PROC_MOUNTS:-}" ]; then : > "$PIM_SD_PROC_MOUNTS"; fi
        exit "${PIM_TEST_UMOUNT_RC:-0}"
        ;;
    mount)
        mount_rc=${PIM_TEST_MOUNT_RC:-0}
        if [ "$mount_rc" -ne 0 ]; then exit "$mount_rc"; fi
        printf '%s %s ext4 %s 0 0\n' \
            "$PIM_SD_DEVICE" "$PIM_SD_MOUNT_DIR" "${PIM_TEST_MOUNT_MODE:-rw}" \
            > "$PIM_SD_PROC_MOUNTS"
        if [ "${PIM_TEST_SEED_MOUNT:-0}" = 1 ]; then
            mkdir -p "$PIM_SD_MOUNT_DIR/tmp"
            printf stale > "$PIM_SD_MOUNT_DIR/tmp/stale.part"
            printf keep > "$PIM_SD_MOUNT_DIR/tmp/keep.bin"
            printf keep > "$PIM_SD_MOUNT_DIR/keep-root.bin"
        fi
        exit 0
        ;;
    blkid|lsblk)
        printf '%s\n' "${PIM_TEST_FSTYPE:-ext4}"
        exit 0
        ;;
    date)
        printf '%s\n' "${PIM_TEST_DATE_RESULT:-20260907_120000}"
        exit 0
        ;;
    df)
        printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
        if [ "${PIM_TEST_DF_MOUNTED:-0}" = 1 ]; then
            printf '%s 1 1 0 100%% %s\n' "$PIM_SD_DEVICE" "$PIM_SD_MOUNT_DIR"
        fi
        exit 0
        ;;
    pgrep)
        if [ -n "${PIM_TEST_PID:-}" ]; then printf '%s\n' "$PIM_TEST_PID"; exit 0; fi
        exit 1
        ;;
    cpulimit|i2ctransfer|ncftpput)
        exit 0
        ;;
    fuser)
        exit 1
        ;;
esac
exit 97
""",
            encoding="utf-8",
        )
        dispatcher.chmod(0o755)
        for name in (
            "logger",
            "flock",
            "sleep",
            "systemctl",
            "umount",
            "mount",
            "blkid",
            "lsblk",
            "date",
            "df",
            "pgrep",
            "cpulimit",
            "i2ctransfer",
            "ncftpput",
            "fuser",
        ):
            (fake_bin / name).symlink_to("dispatcher")
        jq = fake_bin / "jq"
        jq.write_text(
            "#!/usr/bin/env bash\n"
            "printf 'jq' >> \"$PIM_TEST_EVENT_LOG\"\n"
            "for arg in \"$@\"; do printf ' <%s>' \"$arg\" >> \"$PIM_TEST_EVENT_LOG\"; done\n"
            "printf '\\n' >> \"$PIM_TEST_EVENT_LOG\"\n"
            f"exec {self.real_jq} \"$@\"\n",
            encoding="utf-8",
        )
        jq.chmod(0o755)
        return fake_bin

    def base_env(self, root: Path) -> dict[str, str]:
        event_log = root / "events.log"
        event_log.write_text("", encoding="utf-8")
        mounts = root / "proc-mounts"
        mounts.write_text("", encoding="utf-8")
        present = root / "sd-present"
        present.mkdir()
        sys_ro = root / "sd-ro"
        sys_ro.write_text("0\n", encoding="utf-8")
        fake_bin = self.fake_bin(root)
        return {
            **os.environ,
            "PATH": f"{fake_bin}:/usr/bin:/bin",
            "PIM_TEST_EVENT_LOG": str(event_log),
            "PIM_CAMERA_TEST_MODE": "1",
            "PIM_CAMERA_RUNTIME_JSON": str(root / "runtime.json"),
            "PIM_SD_DEVICE": str(root / "device-p1"),
            "PIM_SD_MOUNT_DIR": str(root / "sd-mount"),
            "PIM_SD_MOUNT_FLAG": str(root / "sd-mount.flag"),
            "PIM_SD_PROC_MOUNTS": str(mounts),
            "PIM_SD_PRESENT_PATH": str(present),
            "PIM_SD_SYS_RO_PATH": str(sys_ro),
            "PIM_SD_RO_RECOVERY_FLAG": str(root / "sd-ro-recovered"),
            "PIM_SD_LOCKFILE": str(root / "automount.lock"),
            "PIM_CAMERA_SESSION_DIR": str(root / "sessions"),
            "PIM_AUTOMOUNT_MAX_ITERATIONS": "1",
            "PIM_CPU_LIMIT_MAX_ITERATIONS": "1",
            "PIM_NCSFTP_MAX_ITERATIONS": "1",
            "PIM_CAMERA_ROTATE_DELAY_SEC": "0",
            "PIM_NCSFTP_FILE_CHECK": str(root / "file-check"),
            "PIM_NCSFTP_TRANSFER_PATH": str(root / "sd-mount"),
            "PIM_TEST_CAM_ACTIVE": "active",
            "PIM_TEST_CAM_ENABLED": "enabled",
        }

    @staticmethod
    def events(env: Mapping[str, str]) -> str:
        return Path(env["PIM_TEST_EVENT_LOG"]).read_text(encoding="utf-8")

    @staticmethod
    def clear_events(env: Mapping[str, str]) -> None:
        Path(env["PIM_TEST_EVENT_LOG"]).write_text("", encoding="utf-8")

    @staticmethod
    def command_lines(env: Mapping[str, str], command: str) -> list[str]:
        prefix = f"{command} "
        return [
            line
            for line in Tests.events(env).splitlines()
            if line == command or line.startswith(prefix)
        ]

    @staticmethod
    def event_index(env: Mapping[str, str], event: str) -> int:
        try:
            return Tests.events(env).splitlines().index(event)
        except ValueError:
            return -1

    def run_script(
        self,
        source: Path,
        root: Path,
        env: Mapping[str, str],
        args: Sequence[str] = (),
        timeout: float = 1.5,
    ) -> subprocess.CompletedProcess[str]:
        script = source
        try:
            return subprocess.run(
                [str(script), *args],
                env=dict(env),
                text=True,
                capture_output=True,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            stdout = exc.stdout.decode() if isinstance(exc.stdout, bytes) else exc.stdout
            stderr = exc.stderr.decode() if isinstance(exc.stderr, bytes) else exc.stderr
            return subprocess.CompletedProcess(
                [str(script), *args], 124, stdout or "", stderr or ""
            )

    def sd_mount_stop_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-sd-stop.") as raw:
            root = Path(raw)
            env = self.base_env(root)
            source = root / "source/edgeconf_new.json"
            self.write_json(source, runtime_document(tmp_path="/dev/shm"))
            Path(env["PIM_SD_MOUNT_FLAG"]).write_text("1\n", encoding="utf-8")
            result = self.run_script(BIN / "sd_mount_stop.sh", root, env)
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            self.check(
                result.returncode == 0
                and stop_at >= 0
                and unmount_at > stop_at,
                "missing runtime conservatively stops active cam-operate before unmount",
            )

            self.clear_events(env)
            Path(env["PIM_CAMERA_RUNTIME_JSON"]).write_text("{broken", encoding="utf-8")
            Path(env["PIM_SD_MOUNT_FLAG"]).write_text("1\n", encoding="utf-8")
            result = self.run_script(BIN / "sd_mount_stop.sh", root, env)
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            self.check(
                result.returncode == 0 and stop_at >= 0 and unmount_at > stop_at,
                "invalid runtime also preserves conservative stop-before-unmount",
            )

            self.clear_events(env)
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(tmp_path="/dev/shm"),
            )
            result = self.run_script(BIN / "sd_mount_stop.sh", root, env)
            self.check(
                result.returncode == 0
                and "systemctl <stop> <cam-operate>" not in self.events(env)
                and self.command_lines(env, "umount")
                == [f"umount <{env['PIM_SD_DEVICE']}>"]
                and not Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "valid non-SD runtime avoids an unnecessary camera stop",
            )

            self.clear_events(env)
            Path(env["PIM_SD_MOUNT_FLAG"]).write_text("1\n", encoding="utf-8")
            inactive_env = {**env, "PIM_TEST_CAM_ACTIVE": "inactive"}
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, inactive_env
            )
            self.check(
                result.returncode == 0
                and "systemctl <stop> <cam-operate>" not in self.events(env)
                and self.command_lines(env, "umount")
                == [f"umount <{env['PIM_SD_DEVICE']}>"]
                and not Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "inactive cam-operate does not receive a redundant stop",
            )

            self.clear_events(env)
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(tmp_path=env["PIM_SD_MOUNT_DIR"]),
            )
            result = self.run_script(BIN / "sd_mount_stop.sh", root, env)
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            self.check(
                result.returncode == 0
                and stop_at >= 0
                and unmount_at > stop_at
                and not Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "next invocation sees a direct runtime edit requiring quiescence",
            )

            self.clear_events(env)
            Path(env["PIM_SD_MOUNT_FLAG"]).write_text("1\n", encoding="utf-8")
            failed_env = {**env, "PIM_TEST_STOP_RC": "42"}
            result = self.run_script(BIN / "sd_mount_stop.sh", root, failed_env)
            self.check(
                result.returncode == 42
                and not self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "camera stop failure propagates exactly and blocks unmount",
            )

            self.clear_events(env)
            Path(env["PIM_SD_MOUNT_FLAG"]).write_text("1\n", encoding="utf-8")
            mounted_env = {**env, "PIM_TEST_DF_MOUNTED": "1"}
            result = self.run_script(BIN / "sd_mount_stop.sh", root, mounted_env)
            self.check(
                result.returncode == 1
                and self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "mount flag remains published until unmount is confirmed",
            )

    def file_manager_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-file-manager.") as raw:
            root = Path(raw)
            env = self.base_env(root)
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(vhl_name="runtime"),
            )
            self.write_json(
                root / "source/edgeconf_new.json",
                runtime_document(vhl_name="source"),
            )
            recording = root / "recording"
            recording.mkdir()
            then = time.time() - 60
            for index in range(3):
                for prefix in ("runtime", "source"):
                    path = recording / f"{prefix}_{index}.mp4"
                    path.write_text(prefix, encoding="utf-8")
                    os.utime(path, (then + index, then + index))
            unrelated = recording / "unrelated.mp4"
            unrelated.write_text("unrelated", encoding="utf-8")
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(recording), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 0
                and len(list(recording.glob("runtime_*"))) == 2
                and len(list(recording.glob("source_*"))) == 3
                and unrelated.read_text(encoding="utf-8") == "unrelated",
                "file manager deletes only the fixed-runtime VHL prefix in a disposable directory",
            )

            direct_dir = root / "direct-edit-recording"
            direct_dir.mkdir()
            for index in range(3):
                for prefix in ("runtime-a", "runtime-b"):
                    path = direct_dir / f"{prefix}_{index}.mp4"
                    path.write_text(prefix, encoding="utf-8")
                    os.utime(path, (then + index, then + index))
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(vhl_name="runtime-a"),
            )
            first = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(direct_dir), "2", "100", "caller"),
            )
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(vhl_name="runtime-b"),
            )
            second = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(direct_dir), "2", "100", "caller"),
            )
            self.check(
                first.returncode == 0
                and second.returncode == 0
                and len(list(direct_dir.glob("runtime-a_*"))) == 2
                and len(list(direct_dir.glob("runtime-b_*"))) == 2,
                "direct runtime A-to-B edit selects the new prefix on the next invocation",
            )

            fallback_dir = root / "fallback-recording"
            fallback_dir.mkdir()
            for index in range(3):
                path = fallback_dir / f"caller_{index}.mp4"
                path.write_text("caller", encoding="utf-8")
                os.utime(path, (then + index, then + index))
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]), runtime_document(vhl_name="")
            )
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(fallback_dir), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 0
                and len(list(fallback_dir.glob("caller_*"))) == 2,
                "valid runtime without a usable VHL name retains caller KEY fallback",
            )

            empty_key_dir = root / "empty-key-recording"
            empty_key_dir.mkdir()
            for index in range(3):
                (empty_key_dir / f"unrelated_{index}.mp4").write_text(
                    f"unrelated-{index}", encoding="utf-8"
                )
            empty_key_before = {
                path.name: path.read_bytes() for path in empty_key_dir.iterdir()
            }
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(empty_key_dir), "2", "100", ""),
            )
            empty_key_after = {
                path.name: path.read_bytes() for path in empty_key_dir.iterdir()
            }
            self.check(
                result.returncode == 64 and empty_key_after == empty_key_before,
                "empty effective KEY fails closed instead of widening deletion scope",
            )

            invalid_dir = root / "invalid-recording"
            invalid_dir.mkdir()
            for index in range(3):
                (invalid_dir / f"source_{index}.mp4").write_text(
                    "source", encoding="utf-8"
                )
            Path(env["PIM_CAMERA_RUNTIME_JSON"]).write_text("[]\n", encoding="utf-8")
            before = sorted(path.name for path in invalid_dir.iterdir())
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(invalid_dir), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 64
                and sorted(path.name for path in invalid_dir.iterdir()) == before,
                "invalid runtime fails closed before file deletion",
            )

            missing_dir = root / "missing-runtime-recording"
            missing_dir.mkdir()
            for index in range(3):
                (missing_dir / f"caller_{index}.mp4").write_text(
                    f"caller-{index}", encoding="utf-8"
                )
            Path(env["PIM_CAMERA_RUNTIME_JSON"]).unlink()
            before_missing = {
                path.name: path.read_bytes() for path in missing_dir.iterdir()
            }
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(missing_dir), "2", "100", "caller"),
            )
            after_missing = {
                path.name: path.read_bytes() for path in missing_dir.iterdir()
            }
            self.check(
                result.returncode == 64 and after_missing == before_missing,
                "missing runtime fails closed with zero file deletion",
            )

    def cpu_limit_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-cpu-limit.") as raw:
            root = Path(raw)
            env = self.base_env(root)
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(app="runtime-app"),
            )
            self.write_json(
                root / "source/edgeconf_new.json", runtime_document(app="source-app")
            )
            run_env = {**env, "PIM_TEST_PID": "4242"}
            result = self.run_script(BIN / "cpu_limit.sh", root, run_env, ("50",))
            events = self.events(env)
            self.check(
                result.returncode == 0
                and self.command_lines(env, "pgrep")
                == ["pgrep <-f> <--> <runtime-app>"]
                and self.command_lines(env, "cpulimit")
                == ["cpulimit <-p> <4242> <-l> <50>"],
                "CPU limiter applies one exact limit to the runtime-selected app",
            )

            self.clear_events(env)
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(app="next-runtime-app"),
            )
            result = self.run_script(BIN / "cpu_limit.sh", root, run_env, ("50",))
            events = self.events(env)
            self.check(
                result.returncode == 0
                and self.command_lines(env, "pgrep")
                == ["pgrep <-f> <--> <next-runtime-app>"]
                and self.command_lines(env, "cpulimit")
                == ["cpulimit <-p> <4242> <-l> <50>"],
                "CPU limiter sees a direct runtime app edit on the next invocation",
            )

            invalid_cases: tuple[tuple[str, object], ...] = (
                ("malformed runtime", "{broken"),
                ("missing runtime", None),
                ("wrong-type app", runtime_document(app=7)),
                ("empty app", runtime_document(app="")),
            )
            runtime_path = Path(env["PIM_CAMERA_RUNTIME_JSON"])
            for label, document in invalid_cases:
                self.clear_events(env)
                if document is None:
                    runtime_path.unlink(missing_ok=True)
                elif isinstance(document, str):
                    runtime_path.write_text(document, encoding="utf-8")
                else:
                    assert isinstance(document, dict)
                    self.write_json(runtime_path, document)
                result = self.run_script(
                    BIN / "cpu_limit.sh", root, run_env, ("50",)
                )
                self.check(
                    result.returncode == 64
                    and not self.command_lines(env, "pgrep")
                    and not self.command_lines(env, "cpulimit"),
                    f"{label} causes no CPU-limit process side effect",
                )

    def cam_rotate_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-rotate.") as raw:
            root = Path(raw)
            env = self.base_env(root)
            runtime = runtime_document(
                cam_ch0=True,
                cam_ch0_rotate=True,
                cam_ch1=True,
                cam_ch1_rotate=False,
                cam_ch2=True,
                cam_ch2_rotate=True,
                cam_ch3=True,
                cam_ch3_rotate=False,
            )
            source = runtime_document(
                cam_ch0=False,
                cam_ch0_rotate=False,
                cam_ch1=True,
                cam_ch1_rotate=False,
                cam_ch2=False,
                cam_ch2_rotate=False,
                cam_ch3=False,
                cam_ch3_rotate=False,
            )
            self.write_json(Path(env["PIM_CAMERA_RUNTIME_JSON"]), runtime)
            self.write_json(root / "source/edgeconf_new.json", source)
            result = self.run_script(BIN / "cam_rotate_setting.sh", root, env)
            writes = [
                line
                for line in self.events(env).splitlines()
                if line.startswith("i2ctransfer")
            ]
            expected = [
                "i2ctransfer <-f> <-y> <-a> <2> <w4@0x11> <0x10> <0x0c> <0x00> <0x03>",
                "i2ctransfer <-f> <-y> <-a> <2> <w4@0x12> <0x10> <0x0c> <0x00> <0x00>",
                "i2ctransfer <-f> <-y> <-a> <1> <w4@0x11> <0x10> <0x0c> <0x00> <0x03>",
                "i2ctransfer <-f> <-y> <-a> <1> <w4@0x12> <0x10> <0x0c> <0x00> <0x00>",
            ]
            self.check(
                result.returncode == 0 and writes == expected,
                "rotation preserves all four channel/address/register mappings",
            )

            self.clear_events(env)
            disabled = runtime_document(
                cam_ch0=False,
                cam_ch0_rotate=True,
                cam_ch1=False,
                cam_ch1_rotate=True,
                cam_ch2=False,
                cam_ch2_rotate=True,
                cam_ch3=False,
                cam_ch3_rotate=True,
            )
            self.write_json(Path(env["PIM_CAMERA_RUNTIME_JSON"]), disabled)
            result = self.run_script(BIN / "cam_rotate_setting.sh", root, env)
            self.check(
                result.returncode == 0
                and not self.command_lines(env, "i2ctransfer"),
                "disabled channels produce no hardware writes",
            )

            invalid_cases: tuple[tuple[str, object], ...] = (
                (
                    "string boolean",
                    runtime_document(
                        cam_ch0=True,
                        cam_ch0_rotate=True,
                        cam_ch1=True,
                        cam_ch1_rotate=False,
                        cam_ch2=True,
                        cam_ch2_rotate="true",
                        cam_ch3=True,
                        cam_ch3_rotate=False,
                    ),
                ),
                ("malformed runtime", "{broken"),
                ("missing runtime", None),
            )
            runtime_path = Path(env["PIM_CAMERA_RUNTIME_JSON"])
            for label, document in invalid_cases:
                self.clear_events(env)
                if document is None:
                    runtime_path.unlink(missing_ok=True)
                elif isinstance(document, str):
                    runtime_path.write_text(document, encoding="utf-8")
                else:
                    assert isinstance(document, dict)
                    self.write_json(runtime_path, document)
                result = self.run_script(BIN / "cam_rotate_setting.sh", root, env)
                self.check(
                    result.returncode == 64
                    and not self.command_lines(env, "i2ctransfer"),
                    f"{label} produces zero hardware writes",
                )

    def ncsftp_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-ncsftp.") as raw:
            root = Path(raw)
            env = self.base_env(root)
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(recording_time=7, vhl_name="runtime"),
            )
            self.write_json(
                root / "source/edgeconf_new.json",
                runtime_document(recording_time=3, vhl_name="source"),
            )
            Path(env["PIM_NCSFTP_FILE_CHECK"]).write_text("ready\n", encoding="utf-8")
            result = self.run_script(BIN / "ncsftp.sh", root, env)
            events = self.events(env)
            transfer = next(
                (line for line in events.splitlines() if line.startswith("ncftpput")),
                "",
            )
            expected_transfer = (
                "ncftpput <-u> <jhw> <-p> <jhw> <192.168.1.129> "
                "</opt/sda/Downloads> "
                f"<{env['PIM_NCSFTP_TRANSFER_PATH']}/runtime_20260907_120000*>"
            )
            self.check(
                result.returncode == 0
                and self.command_lines(env, "date")
                == ["date <+%Y%m%d_%H%M00> <-d> <7 min ago>"]
                and transfer == expected_transfer,
                "FTP consumer uses exact runtime time/name inputs for one bounded transfer",
            )

            self.clear_events(env)
            Path(env["PIM_NCSFTP_FILE_CHECK"]).write_text("ready\n", encoding="utf-8")
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(recording_time=9, vhl_name="next-runtime"),
            )
            result = self.run_script(BIN / "ncsftp.sh", root, env)
            self.check(
                result.returncode == 0
                and self.command_lines(env, "date")
                == ["date <+%Y%m%d_%H%M00> <-d> <9 min ago>"]
                and self.command_lines(env, "ncftpput")
                == [
                    "ncftpput <-u> <jhw> <-p> <jhw> <192.168.1.129> "
                    "</opt/sda/Downloads> "
                    f"<{env['PIM_NCSFTP_TRANSFER_PATH']}/next-runtime_20260907_120000*>"
                ],
                "FTP consumer sees direct runtime edits on the next invocation",
            )

            invalid_cases: tuple[tuple[str, object], ...] = (
                ("malformed runtime", "{broken"),
                ("missing runtime", None),
                (
                    "wrong-type fields",
                    runtime_document(recording_time="7", vhl_name=42),
                ),
            )
            runtime_path = Path(env["PIM_CAMERA_RUNTIME_JSON"])
            for label, document in invalid_cases:
                self.clear_events(env)
                Path(env["PIM_NCSFTP_FILE_CHECK"]).write_text(
                    "ready\n", encoding="utf-8"
                )
                if document is None:
                    runtime_path.unlink(missing_ok=True)
                elif isinstance(document, str):
                    runtime_path.write_text(document, encoding="utf-8")
                else:
                    assert isinstance(document, dict)
                    self.write_json(runtime_path, document)
                result = self.run_script(BIN / "ncsftp.sh", root, env)
                self.check(
                    result.returncode == 64
                    and not self.command_lines(env, "date")
                    and not self.command_lines(env, "ncftpput"),
                    f"{label} causes no date or network transfer side effect",
                )

            self.clear_events(env)
            self.write_json(
                runtime_path,
                runtime_document(recording_time=7, vhl_name="runtime"),
            )
            Path(env["PIM_NCSFTP_FILE_CHECK"]).write_text("", encoding="utf-8")
            result = self.run_script(BIN / "ncsftp.sh", root, env)
            self.check(
                result.returncode == 0
                and not self.command_lines(env, "date")
                and not self.command_lines(env, "ncftpput"),
                "empty file-check exits its bounded iteration without transfer",
            )

    def automount_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-automount.") as raw:
            root = Path(raw)
            env = {
                **self.base_env(root),
                "PIM_TEST_CAM_ACTIVE": "inactive",
                "PIM_TEST_SEED_MOUNT": "1",
            }
            (root / "source").mkdir()
            source = root / "source/edgeconf_sentinel.json"
            runtime = Path(env["PIM_CAMERA_RUNTIME_JSON"])
            source.write_bytes(b"SOURCE-SENTINEL\n")
            runtime.write_bytes(b"RUNTIME-SENTINEL\n")
            outside = root / "outside.part"
            outside.write_bytes(b"outside")
            source_before = source.read_bytes()
            runtime_before = runtime.read_bytes()
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh", root, env, timeout=2.0
            )
            events = self.events(env)
            flag = Path(env["PIM_SD_MOUNT_FLAG"])
            expected_mount = (
                "mount <-t> <ext4> <-o> "
                "<noatime,nodiratime,commit=60,data=ordered,barrier=1,errors=remount-ro> "
                f"<{env['PIM_SD_DEVICE']}> <{env['PIM_SD_MOUNT_DIR']}>"
            )
            self.check(
                result.returncode == 0
                and flag.read_text(encoding="utf-8").strip() == "1"
                and self.command_lines(env, "mount") == [expected_mount]
                and self.command_lines(env, "systemctl").count(
                    "systemctl <start> <cam-operate>"
                )
                == 1
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before
                and not (Path(env["PIM_SD_MOUNT_DIR"]) / "tmp/stale.part").exists()
                and (Path(env["PIM_SD_MOUNT_DIR"]) / "tmp/keep.bin").read_bytes()
                == b"keep"
                and (Path(env["PIM_SD_MOUNT_DIR"]) / "keep-root.bin").read_bytes()
                == b"keep"
                and outside.read_bytes() == b"outside",
                "pre-cam automount succeeds via mount flag without source or runtime mutation",
            )

            self.clear_events(env)
            Path(env["PIM_SD_PROC_MOUNTS"]).write_text("", encoding="utf-8")
            active_env = {**env, "PIM_TEST_CAM_ACTIVE": "active"}
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh", root, active_env, timeout=2.0
            )
            events = self.events(env)
            self.check(
                result.returncode == 0
                and "systemctl <start> <cam-operate>" not in events
                and "systemctl <restart> <cam-operate>" not in events
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "successful mount does not restart an already-active cam-operate",
            )

            self.clear_events(env)
            Path(env["PIM_SD_PROC_MOUNTS"]).write_text("", encoding="utf-8")
            ro_env = {
                **env,
                "PIM_TEST_CAM_ACTIVE": "inactive",
                "PIM_TEST_MOUNT_MODE": "ro",
            }
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh", root, ro_env, timeout=2.0
            )
            events = self.events(env)
            self.check(
                result.returncode == 0
                and Path(env["PIM_SD_MOUNT_FLAG"]).read_text(encoding="utf-8").strip()
                == "0"
                and "umount" in events
                and "systemctl <start> <cam-operate>" not in events
                and "systemctl <restart> <cam-operate>" not in events
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "read-only mount publishes unavailable without config mutation or camera start",
            )

            self.clear_events(env)
            Path(env["PIM_SD_PROC_MOUNTS"]).write_text("", encoding="utf-8")
            mount_failure_env = {
                **env,
                "PIM_TEST_CAM_ACTIVE": "inactive",
                "PIM_TEST_MOUNT_RC": "5",
                "PIM_TEST_SEED_MOUNT": "0",
            }
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh",
                root,
                mount_failure_env,
                timeout=2.0,
            )
            self.check(
                result.returncode == 0
                and flag.read_text(encoding="utf-8").strip() == "0"
                and len(self.command_lines(env, "mount")) == 1
                and "systemctl <start> <cam-operate>" not in self.events(env)
                and "systemctl <restart> <cam-operate>" not in self.events(env)
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "mount failure publishes unavailable without config mutation or camera start",
            )

            self.clear_events(env)
            Path(env["PIM_SD_PROC_MOUNTS"]).write_text("", encoding="utf-8")
            shutil.rmtree(env["PIM_SD_PRESENT_PATH"])
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh", root, env, timeout=2.0
            )
            self.check(
                result.returncode == 0
                and flag.read_text(encoding="utf-8").strip() == "0"
                and not self.command_lines(env, "mount")
                and "systemctl <start> <cam-operate>" not in self.events(env)
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "physically absent SD publishes unavailable without config access",
            )

            self.clear_events(env)
            reinsert_env = {
                **env,
                "PIM_AUTOMOUNT_MAX_ITERATIONS": "3",
                "PIM_TEST_PRESENT_AFTER_SLEEP": "1",
                "PIM_TEST_CAM_ACTIVE": "inactive",
                "PIM_TEST_MOUNT_MODE": "rw",
            }
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh", root, reinsert_env, timeout=2.0
            )
            self.check(
                result.returncode == 0
                and Path(env["PIM_SD_MOUNT_FLAG"]).read_text(encoding="utf-8").strip()
                == "1"
                and self.command_lines(env, "mount") == [expected_mount]
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "bounded reinsert transition returns to mounted/available state",
            )

    def automount_retry_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-automount-retry.") as raw:
            root = Path(raw)
            env = {
                **self.base_env(root),
                "PIM_AUTOMOUNT_MAX_ITERATIONS": "12",
                "PIM_TEST_CAM_ACTIVE": "inactive",
                "PIM_TEST_MOUNT_RC": "5",
                "PIM_TEST_SEED_MOUNT": "0",
            }
            source = root / "source.json"
            runtime = Path(env["PIM_CAMERA_RUNTIME_JSON"])
            source.write_bytes(b"SOURCE-RETRY-SENTINEL\n")
            runtime.write_bytes(b"RUNTIME-RETRY-SENTINEL\n")
            source_before = source.read_bytes()
            runtime_before = runtime.read_bytes()
            flag = Path(env["PIM_SD_MOUNT_FLAG"])

            known_env = {**env, "PIM_TEST_FSTYPE": "ext4"}
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh",
                root,
                known_env,
                timeout=3.0,
            )
            self.check(
                result.returncode == 0
                and len(self.command_lines(env, "mount")) == 6
                and "sleep <60>" not in self.command_lines(env, "sleep")
                and flag.read_text(encoding="utf-8").strip() == "0"
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "known-fstype failures keep retrying without unknown-fstype quarantine",
            )

            self.clear_events(env)
            Path(env["PIM_SD_PROC_MOUNTS"]).write_text("", encoding="utf-8")
            unknown_env = {**env, "PIM_TEST_FSTYPE": "unknown-fstype"}
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh",
                root,
                unknown_env,
                timeout=3.0,
            )
            self.check(
                result.returncode == 0
                and len(self.command_lines(env, "mount")) == 4
                and self.command_lines(env, "sleep").count("sleep <60>") == 1
                and flag.read_text(encoding="utf-8").strip() == "0"
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "unknown fstype counts once and backs off exactly on the fifth detection",
            )

            self.clear_events(env)
            Path(env["PIM_SD_PROC_MOUNTS"]).write_text("", encoding="utf-8")
            Path(env["PIM_SD_PRESENT_PATH"]).mkdir(exist_ok=True)
            reset_env = {
                **unknown_env,
                "PIM_TEST_REMOVE_DURING_BACKOFF": "1",
            }
            result = self.run_script(
                BIN / "automnt_sd_for_emmc_boot.sh",
                root,
                reset_env,
                timeout=3.0,
            )
            self.check(
                result.returncode == 0
                and len(self.command_lines(env, "mount")) == 5
                and self.command_lines(env, "sleep").count("sleep <60>") == 1
                and Path(env["PIM_SD_PRESENT_PATH"]).is_dir()
                and flag.read_text(encoding="utf-8").strip() == "0"
                and source.read_bytes() == source_before
                and runtime.read_bytes() == runtime_before,
                "physical removal resets unknown-fstype quarantine for reinsertion retry",
            )

    def run(self, selected: Sequence[str] = ()) -> int:
        print("=== deployed runtime script consumers ===")
        tests = {
            "sd_mount_stop": self.sd_mount_stop_test,
            "file_manager": self.file_manager_test,
            "cpu_limit": self.cpu_limit_test,
            "cam_rotate": self.cam_rotate_test,
            "ncsftp": self.ncsftp_test,
            "automount": self.automount_test,
            "automount_retry": self.automount_retry_test,
        }
        names = tuple(selected) or tuple(tests)
        unknown = sorted(set(names) - set(tests))
        if unknown:
            print(f"unknown consumer test(s): {', '.join(unknown)}", file=sys.stderr)
            return 2
        for name in names:
            tests[name]()
        print()
        print(f"runtime script consumers: {self.passed} passed / {self.failed} failed")
        return 1 if self.failed else 0


if __name__ == "__main__":
    raise SystemExit(Tests().run(sys.argv[1:]))
