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
        if [ -n "${PIM_TEST_KILL_PARENT_AFTER_SLEEPS:-}" ]; then
            sleep_count=0
            if [ -f "$PIM_TEST_SLEEP_COUNT_FILE" ]; then
                read -r sleep_count < "$PIM_TEST_SLEEP_COUNT_FILE"
            fi
            sleep_count=$((sleep_count + 1))
            printf '%s\n' "$sleep_count" > "$PIM_TEST_SLEEP_COUNT_FILE"
            if [ "$sleep_count" -ge "$PIM_TEST_KILL_PARENT_AFTER_SLEEPS" ]; then
                kill -TERM "$PPID"
                exit 0
            fi
        fi
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
            is-active)
                active_count=0
                if [ -n "${PIM_TEST_IS_ACTIVE_COUNT_FILE:-}" ] && [ -f "$PIM_TEST_IS_ACTIVE_COUNT_FILE" ]; then
                    read -r active_count < "$PIM_TEST_IS_ACTIVE_COUNT_FILE"
                fi
                active_count=$((active_count + 1))
                if [ -n "${PIM_TEST_IS_ACTIVE_COUNT_FILE:-}" ]; then
                    printf '%s\n' "$active_count" > "$PIM_TEST_IS_ACTIVE_COUNT_FILE"
                fi
                if [ "${PIM_TEST_IS_ACTIVE_FAIL_AT:-0}" -eq "$active_count" ]; then
                    exit "${PIM_TEST_IS_ACTIVE_FAIL_RC:-4}"
                fi
                if [ "${PIM_TEST_TRACK_CAM_STATE:-0}" = 1 ]; then
                    active_state=$(cat "$PIM_TEST_CAM_STATE_FILE")
                else
                    active_state=${PIM_TEST_CAM_ACTIVE-active}
                fi
                printf '%s\n' "$active_state"
                if [ -n "${PIM_TEST_IS_ACTIVE_RC:-}" ]; then
                    exit "$PIM_TEST_IS_ACTIVE_RC"
                fi
                if [ "$active_state" = inactive ]; then exit 3; fi
                exit 0
                ;;
            is-enabled) printf '%s\n' "${PIM_TEST_CAM_ENABLED:-enabled}"; exit 0 ;;
            stop)
                stop_rc=${PIM_TEST_STOP_RC:-0}
                if [ "$stop_rc" -eq 0 ] && [ "${PIM_TEST_TRACK_CAM_STATE:-0}" = 1 ] && [ "${2:-}" = cam-operate ]; then
                    printf '%s\n' "${PIM_TEST_STOP_STATE:-inactive}" > "$PIM_TEST_CAM_STATE_FILE"
                fi
                if [ "$stop_rc" -eq 0 ] && [ "${PIM_TEST_TRACK_WRITERS:-0}" = 1 ] && [ "${2:-}" = cam-operate ] && [ "${PIM_TEST_PRESERVE_WRITERS_AFTER_STOP:-0}" != 1 ]; then
                    : > "$PIM_TEST_WRITER_STATE_FILE"
                fi
                exit "$stop_rc"
                ;;
            start|restart) exit 0 ;;
        esac
        exit 0
        ;;
    umount)
        if [ "${PIM_TEST_ASSERT_QUIESCENT_AT_UMOUNT:-0}" = 1 ]; then
            boundary_state=$(cat "$PIM_TEST_CAM_STATE_FILE")
            if [ "$boundary_state" != inactive ]; then
                printf 'unit-not-inactive-at-unmount <%s>\n' "$boundary_state" >> "$PIM_TEST_EVENT_LOG"
                exit 91
            fi
            while IFS= read -r writer; do
                case "$writer" in
                    gstApp|PIMCAM)
                        printf 'writer-live-at-unmount <%s>\n' "$writer" >> "$PIM_TEST_EVENT_LOG"
                        exit 92
                        ;;
                esac
            done < "$PIM_TEST_WRITER_STATE_FILE"
            printf 'quiescent-at-unmount <inactive> <no-gstApp> <no-PIMCAM>\n' >> "$PIM_TEST_EVENT_LOG"
        fi
        if [ "${PIM_TEST_TRACK_CAM_STATE:-0}" = 1 ] && [ "$(cat "$PIM_TEST_CAM_STATE_FILE")" = active ]; then
            printf 'writer-active-at-unmount\n' >> "$PIM_TEST_EVENT_LOG"
        fi
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
        if [ "${1:-}" = -x ] && [ -n "${2:-}" ] && [ -f "${PIM_TEST_WRITER_STATE_FILE:-}" ]; then
            pgrep_count=0
            if [ -n "${PIM_TEST_PGREP_COUNT_FILE:-}" ] && [ -f "$PIM_TEST_PGREP_COUNT_FILE" ]; then
                read -r pgrep_count < "$PIM_TEST_PGREP_COUNT_FILE"
            fi
            pgrep_count=$((pgrep_count + 1))
            if [ -n "${PIM_TEST_PGREP_COUNT_FILE:-}" ]; then
                printf '%s\n' "$pgrep_count" > "$PIM_TEST_PGREP_COUNT_FILE"
            fi
            if [ "${PIM_TEST_PGREP_ALWAYS_FAIL:-0}" = 1 ]; then
                exit "${PIM_TEST_PGREP_FAIL_RC:-2}"
            fi
            if [ "${PIM_TEST_PGREP_FAIL_AT:-0}" -eq "$pgrep_count" ]; then
                exit "${PIM_TEST_PGREP_FAIL_RC:-2}"
            fi
            while IFS= read -r writer; do
                if [ "$writer" = "$2" ]; then
                    printf '4242\n'
                    exit 0
                fi
            done < "$PIM_TEST_WRITER_STATE_FILE"
            exit 1
        fi
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
            "if [ -z \"${PIM_TEST_JQ_SWAP_FILE:-}\" ]; then\n"
            f"    exec {self.real_jq} \"$@\"\n"
            "fi\n"
            f"{self.real_jq} \"$@\"\n"
            "jq_rc=$?\n"
            "swap_count=0\n"
            "if [ -f \"$PIM_TEST_JQ_SWAP_COUNT_FILE\" ]; then\n"
            "    read -r swap_count < \"$PIM_TEST_JQ_SWAP_COUNT_FILE\"\n"
            "fi\n"
            "swap_count=$((swap_count + 1))\n"
            "printf '%s\\n' \"$swap_count\" > \"$PIM_TEST_JQ_SWAP_COUNT_FILE\"\n"
            "if [ \"$swap_count\" -eq 1 ]; then\n"
            "    mv -f -- \"$PIM_TEST_JQ_SWAP_FILE\" \"$PIM_CAMERA_RUNTIME_JSON\"\n"
            "fi\n"
            "exit \"$jq_rc\"\n",
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
        cam_state = root / "cam-operate.state"
        cam_state.write_text("active\n", encoding="utf-8")
        writer_state = root / "camera-writers.state"
        writer_state.write_text("", encoding="utf-8")
        is_active_count = root / "is-active.count"
        is_active_count.write_text("0\n", encoding="utf-8")
        pgrep_count = root / "pgrep.count"
        pgrep_count.write_text("0\n", encoding="utf-8")
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
            "PIM_TEST_CAM_STATE_FILE": str(cam_state),
            "PIM_TEST_WRITER_STATE_FILE": str(writer_state),
            "PIM_TEST_IS_ACTIVE_COUNT_FILE": str(is_active_count),
            "PIM_TEST_PGREP_COUNT_FILE": str(pgrep_count),
        }

    def swap_env(
        self,
        root: Path,
        env: Mapping[str, str],
        name: str,
        replacement: Mapping[str, object],
    ) -> dict[str, str]:
        replacement_path = root / f"{name}.replacement.json"
        count_path = root / f"{name}.jq-count"
        self.write_json(replacement_path, replacement)
        count_path.unlink(missing_ok=True)
        return {
            **env,
            "PIM_TEST_JQ_SWAP_FILE": str(replacement_path),
            "PIM_TEST_JQ_SWAP_COUNT_FILE": str(count_path),
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
            cam_state = Path(env["PIM_TEST_CAM_STATE_FILE"])
            writer_state = Path(env["PIM_TEST_WRITER_STATE_FILE"])
            active_count = Path(env["PIM_TEST_IS_ACTIVE_COUNT_FILE"])
            pgrep_count = Path(env["PIM_TEST_PGREP_COUNT_FILE"])

            def quiescence_env(
                state: str,
                writers: Sequence[str] = (),
                **overrides: str,
            ) -> dict[str, str]:
                self.clear_events(env)
                cam_state.write_text(
                    f"{state}\n" if state else "", encoding="utf-8"
                )
                writer_state.write_text(
                    "".join(f"{writer}\n" for writer in writers),
                    encoding="utf-8",
                )
                active_count.write_text("0\n", encoding="utf-8")
                pgrep_count.write_text("0\n", encoding="utf-8")
                Path(env["PIM_SD_MOUNT_FLAG"]).write_text(
                    "1\n", encoding="utf-8"
                )
                return {
                    **env,
                    "PIM_TEST_TRACK_CAM_STATE": "1",
                    "PIM_TEST_TRACK_WRITERS": "1",
                    "PIM_TEST_ASSERT_QUIESCENT_AT_UMOUNT": "1",
                    **overrides,
                }

            missing_env = quiescence_env("active")
            result = self.run_script(BIN / "sd_mount_stop.sh", root, missing_env)
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            self.check(
                result.returncode == 0
                and stop_at >= 0
                and unmount_at > stop_at,
                "missing runtime conservatively stops active cam-operate before unmount",
            )

            Path(env["PIM_CAMERA_RUNTIME_JSON"]).write_text("{broken", encoding="utf-8")
            invalid_env = quiescence_env("active")
            result = self.run_script(BIN / "sd_mount_stop.sh", root, invalid_env)
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
            Path(env["PIM_TEST_CAM_STATE_FILE"]).write_text(
                "active\n", encoding="utf-8"
            )
            tracked_env = {**env, "PIM_TEST_TRACK_CAM_STATE": "1"}
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, tracked_env
            )
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            self.check(
                result.returncode == 0
                and stop_at >= 0
                and unmount_at > stop_at
                and "writer-active-at-unmount" not in self.events(env)
                and self.command_lines(env, "umount")
                == [f"umount <{env['PIM_SD_DEVICE']}>"]
                and not Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "active cached writer stops before unmount despite current non-SD runtime",
            )

            inactive_env = quiescence_env("inactive")
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, inactive_env
            )
            inactive_events = self.events(env)
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            boundary_at = self.event_index(
                env,
                "quiescent-at-unmount <inactive> <no-gstApp> <no-PIMCAM>",
            )
            self.check(
                result.returncode == 0
                and "systemctl <stop> <cam-operate>" not in inactive_events
                and self.command_lines(env, "pgrep")
                == ["pgrep <-x> <gstApp>", "pgrep <-x> <PIMCAM>"]
                and self.command_lines(env, "umount")
                == [f"umount <{env['PIM_SD_DEVICE']}>"]
                and boundary_at == unmount_at + 1
                and not Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "standard inactive rc=3 and writer-free state skips stop at an exact quiescent unmount boundary",
            )

            for state in (
                "activating",
                "reloading",
                "deactivating",
                "failed",
                "unknown",
                "",
            ):
                case_env = quiescence_env(state)
                result = self.run_script(BIN / "sd_mount_stop.sh", root, case_env)
                stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
                unmount_at = self.event_index(
                    env, f"umount <{env['PIM_SD_DEVICE']}>"
                )
                self.check(
                    result.returncode == 0
                    and stop_at >= 0
                    and unmount_at > stop_at
                    and "quiescent-at-unmount <inactive> <no-gstApp> <no-PIMCAM>"
                    in self.events(env),
                    f"{state or 'empty'} unit state stops conservatively before unmount",
                )

            query_failure_env = quiescence_env(
                "active",
                PIM_TEST_IS_ACTIVE_FAIL_AT="1",
                PIM_TEST_IS_ACTIVE_FAIL_RC="4",
            )
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, query_failure_env
            )
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            self.check(
                result.returncode == 0
                and stop_at >= 0
                and unmount_at > stop_at
                and "quiescent-at-unmount <inactive> <no-gstApp> <no-PIMCAM>"
                in self.events(env),
                "is-active query failure stops conservatively before unmount",
            )

            writer_query_failure_env = quiescence_env(
                "inactive",
                PIM_TEST_PGREP_ALWAYS_FAIL="1",
                PIM_TEST_PGREP_FAIL_RC="2",
            )
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, writer_query_failure_env
            )
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(env, f"umount <{env['PIM_SD_DEVICE']}>")
            self.check(
                result.returncode != 0
                and stop_at >= 0
                and unmount_at == -1
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "persistent exact-writer query failure stops then blocks unproven unmount",
            )

            ambiguous_stop_failure_env = quiescence_env(
                "activating", PIM_TEST_STOP_RC="42"
            )
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, ambiguous_stop_failure_env
            )
            self.check(
                result.returncode == 42
                and self.command_lines(env, "systemctl")
                == [
                    "systemctl <is-active> <cam-operate>",
                    "systemctl <stop> <cam-operate>",
                ]
                and not self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "ambiguous-state stop failure propagates exactly and blocks unmount",
            )

            for writer in ("gstApp", "PIMCAM"):
                orphan_env = quiescence_env("inactive", (writer,))
                result = self.run_script(BIN / "sd_mount_stop.sh", root, orphan_env)
                stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
                unmount_at = self.event_index(
                    env, f"umount <{env['PIM_SD_DEVICE']}>"
                )
                self.check(
                    result.returncode == 0
                    and stop_at >= 0
                    and unmount_at > stop_at
                    and "quiescent-at-unmount <inactive> <no-gstApp> <no-PIMCAM>"
                    in self.events(env),
                    f"inactive unit with orphan {writer} stops before unmount",
                )

            post_state_env = quiescence_env(
                "active", PIM_TEST_STOP_STATE="deactivating"
            )
            result = self.run_script(BIN / "sd_mount_stop.sh", root, post_state_env)
            self.check(
                result.returncode != 0
                and not self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "post-stop non-inactive unit state blocks unmount",
            )

            post_query_failure_env = quiescence_env(
                "active",
                PIM_TEST_IS_ACTIVE_FAIL_AT="2",
                PIM_TEST_IS_ACTIVE_FAIL_RC="4",
            )
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, post_query_failure_env
            )
            self.check(
                result.returncode != 0
                and not self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "post-stop is-active query failure blocks unmount",
            )

            post_writer_query_failure_env = quiescence_env(
                "active",
                PIM_TEST_PGREP_FAIL_AT="1",
                PIM_TEST_PGREP_FAIL_RC="2",
            )
            result = self.run_script(
                BIN / "sd_mount_stop.sh", root, post_writer_query_failure_env
            )
            self.check(
                result.returncode != 0
                and not self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "post-stop exact-writer query failure blocks unmount",
            )

            live_writer_env = quiescence_env(
                "active",
                ("gstApp",),
                PIM_TEST_PRESERVE_WRITERS_AFTER_STOP="1",
            )
            result = self.run_script(BIN / "sd_mount_stop.sh", root, live_writer_env)
            self.check(
                result.returncode != 0
                and not self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "post-stop live exact writer blocks unmount",
            )

            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(tmp_path=env["PIM_SD_MOUNT_DIR"]),
            )
            direct_env = quiescence_env("active")
            result = self.run_script(BIN / "sd_mount_stop.sh", root, direct_env)
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
            Path(env["PIM_TEST_CAM_STATE_FILE"]).write_text(
                "active\n", encoding="utf-8"
            )
            self.write_json(
                Path(env["PIM_CAMERA_RUNTIME_JSON"]),
                runtime_document(tmp_path="/dev/shm"),
            )
            failed_env = {
                **env,
                "PIM_TEST_TRACK_CAM_STATE": "1",
                "PIM_TEST_STOP_RC": "42",
            }
            result = self.run_script(BIN / "sd_mount_stop.sh", root, failed_env)
            self.check(
                result.returncode == 42
                and not self.command_lines(env, "umount")
                and Path(env["PIM_SD_MOUNT_FLAG"]).exists(),
                "cached-writer stop failure propagates exactly and blocks unmount",
            )

            mounted_env = quiescence_env("active", PIM_TEST_DF_MOUNTED="1")
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

            runtime_path = Path(env["PIM_CAMERA_RUNTIME_JSON"])
            runtime_path.write_text("{broken", encoding="utf-8")
            self.clear_events(env)
            malformed_before = {
                path.name: path.read_bytes() for path in invalid_dir.iterdir()
            }
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(invalid_dir), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 64
                and malformed_before
                == {path.name: path.read_bytes() for path in invalid_dir.iterdir()}
                and "CONFIG_INVALID:" in self.events(env),
                "malformed runtime remains CONFIG_INVALID with zero file deletion",
            )

            runtime_path.unlink()
            runtime_path.mkdir()
            self.clear_events(env)
            directory_before = {
                path.name: path.read_bytes() for path in invalid_dir.iterdir()
            }
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                env,
                (str(invalid_dir), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 64
                and runtime_path.is_dir()
                and directory_before
                == {path.name: path.read_bytes() for path in invalid_dir.iterdir()}
                and "CONFIG_INVALID:" in self.events(env),
                "runtime directory remains CONFIG_INVALID with zero file deletion",
            )
            runtime_path.rmdir()

            unreadable_runtime = Path("/proc/self/mem")
            unreadable_env = {
                **env,
                "PIM_CAMERA_RUNTIME_JSON": str(unreadable_runtime),
            }
            self.clear_events(env)
            unreadable_before = {
                path.name: path.read_bytes() for path in invalid_dir.iterdir()
            }
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                unreadable_env,
                (str(invalid_dir), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 64
                and unreadable_runtime.exists()
                and unreadable_before
                == {path.name: path.read_bytes() for path in invalid_dir.iterdir()}
                and "CONFIG_INVALID:" in self.events(env),
                "unreadable runtime remains CONFIG_INVALID independent of caller UID",
            )

            inaccessible_parent = root / "unresolvable-runtime-parent"
            inaccessible_parent.symlink_to(inaccessible_parent)
            inaccessible_runtime = inaccessible_parent / "runtime.json"
            inaccessible_env = {
                **env,
                "PIM_CAMERA_RUNTIME_JSON": str(inaccessible_runtime),
            }
            self.clear_events(env)
            inaccessible_before = {
                path.name: path.read_bytes() for path in invalid_dir.iterdir()
            }
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                inaccessible_env,
                (str(invalid_dir), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 64
                and inaccessible_parent.is_symlink()
                and inaccessible_before
                == {path.name: path.read_bytes() for path in invalid_dir.iterdir()}
                and "CONFIG_INVALID:" in self.events(env),
                "runtime beneath an unresolvable parent remains CONFIG_INVALID with zero file deletion",
            )

            self.write_json(runtime_path, runtime_document(vhl_name="runtime"))
            disappear_hook = root / "remove-runtime-before-read.sh"
            disappear_hook.write_text(
                "trap 'if [[ \"$BASH_COMMAND\" == VHL_NAME=* ]]; then "
                "trap - DEBUG; /usr/bin/rm -f -- \"$PIM_CAMERA_RUNTIME_JSON\"; "
                "fi' DEBUG\n",
                encoding="utf-8",
            )
            disappear_env = {**env, "BASH_ENV": str(disappear_hook)}
            self.clear_events(env)
            disappear_before = {
                path.name: path.read_bytes() for path in invalid_dir.iterdir()
            }
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                disappear_env,
                (str(invalid_dir), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 0
                and not runtime_path.exists()
                and disappear_before
                == {path.name: path.read_bytes() for path in invalid_dir.iterdir()}
                and "RUNTIME_UNAVAILABLE:" in self.events(env),
                "runtime disappearance immediately before read is unavailable and deletion-safe",
            )

            missing_dir = root / "missing-runtime-recording"
            missing_dir.mkdir()
            for index in range(3):
                (missing_dir / f"caller_{index}.mp4").write_text(
                    f"caller-{index}", encoding="utf-8"
                )
            runtime_path.unlink(missing_ok=True)
            self.clear_events(env)
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
                result.returncode == 0
                and after_missing == before_missing
                and "RUNTIME_UNAVAILABLE:" in self.events(env)
                and not self.command_lines(env, "jq")
                and result.stderr == "",
                "missing runtime is unavailable and cron-safe with zero file deletion",
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

    def runtime_atomic_swap_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-atomic-swap.") as raw:
            root = Path(raw)
            env = self.base_env(root)
            runtime_path = Path(env["PIM_CAMERA_RUNTIME_JSON"])

            bg_original = runtime_document(
                i2c2={"ch0": {"enable": True}, "ch1": {"enable": True}},
                i2c1={"ch2": {"enable": True}, "ch3": {"enable": True}},
                vhl_name="atomic-a",
                tmp_path="/dev/shm",
                muxer="mp4",
            )
            bg_replacement = runtime_document(
                i2c2={"ch0": {"enable": False}, "ch1": {"enable": False}},
                i2c1={"ch2": {"enable": False}, "ch3": {"enable": False}},
                vhl_name="atomic-b",
                tmp_path="/dev/shm",
                muxer="mkv",
            )
            self.write_json(runtime_path, bg_original)
            bg_env = self.swap_env(root, env, "bg", bg_replacement)
            bg_env_file = root / "bg-env.sh"
            bg_env_file.write_text(
                """source() {
    case "$1" in
        */cam_state.sh)
            cam_state_init() { :; }
            cam_channel_error() { :; }
            ;;
        */cam_start_policy.sh)
            cam_policy_camera_startup_grace_sec() { printf '25\\n'; }
            cam_in_startup_grace() { return 1; }
            ;;
        *) builtin source "$@" ;;
    esac
}
""",
                encoding="utf-8",
            )
            bg_bin = root / "bg-bin"
            bg_bin.mkdir()
            for command in ("rm", "touch"):
                stub = bg_bin / command
                stub.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
                stub.chmod(0o755)
            bg_env.update(
                {
                    "BASH_ENV": str(bg_env_file),
                    "PATH": f"{bg_bin}:{bg_env['PATH']}",
                    "PIM_TEST_KILL_PARENT_AFTER_SLEEPS": "2",
                    "PIM_TEST_SLEEP_COUNT_FILE": str(root / "bg-sleep-count"),
                }
            )
            self.clear_events(env)
            self.run_script(BIN / "BG_Check_for_pim.sh", root, bg_env, ("0",))
            self.check(
                "BG check loop start(ch0:1, ch1:1, ch2:1, ch3:1)"
                in self.events(env),
                "BG checker uses one immutable runtime snapshot across validation and extraction",
            )

            channel_original = runtime_document(
                i2c2={"ch0": {"enable": True}, "ch1": {"enable": True}},
                i2c1={"ch2": {"enable": False}, "ch3": {"enable": False}},
            )
            channel_replacement = runtime_document(
                i2c2={"ch0": {"enable": True}, "ch1": {"enable": False}},
                i2c1={"ch2": {"enable": False}, "ch3": {"enable": False}},
            )
            self.write_json(runtime_path, channel_original)
            channel_env = self.swap_env(
                root, env, "channel", channel_replacement
            )
            result = subprocess.run(
                [
                    "/usr/bin/bash",
                    "-c",
                    'source "$1"; resolve_channel_context 0; printf "%s %s %s\\n" "$MODE" "$AP_ADDR" "$RESOLVE_SOURCE"',
                    "atomic-channel",
                    str(BIN / "cam_channel_resolve.sh"),
                ],
                env=channel_env,
                text=True,
                capture_output=True,
                timeout=1.5,
                check=False,
            )
            self.check(
                result.returncode == 0
                and result.stdout.strip() == "dual 0x11 edgeconf",
                "channel resolver uses one immutable runtime snapshot per resolution",
            )

            self.write_json(runtime_path, channel_original)
            result = subprocess.run(
                [
                    "/usr/bin/bash",
                    "-c",
                    'die() { exit 70; }; source "$1"; '
                    'resolve_channel_context 0; first="$MODE $AP_ADDR $RESOLVE_SOURCE"; '
                    'resolve_channel_context 1; printf "%s|%s %s %s\\n" '
                    '"$first" "$MODE" "$AP_ADDR" "$RESOLVE_SOURCE"',
                    "atomic-channel-multiple",
                    str(BIN / "cam_channel_resolve.sh"),
                ],
                env=env,
                text=True,
                capture_output=True,
                timeout=1.5,
                check=False,
            )
            self.check(
                result.returncode == 0
                and result.stdout.strip()
                == "dual 0x11 edgeconf|dual 0x12 edgeconf",
                "channel snapshot survives multiple resolutions in one consumer invocation",
            )

            recording = root / "atomic-recording"
            recording.mkdir()
            then = time.time() - 60
            for index in range(3):
                for prefix in ("atomic-a", "atomic-b"):
                    path = recording / f"{prefix}_{index}.mp4"
                    path.write_text(prefix, encoding="utf-8")
                    os.utime(path, (then + index, then + index))
            self.write_json(
                runtime_path, runtime_document(vhl_name="atomic-a")
            )
            file_env = self.swap_env(
                root,
                env,
                "file-manager",
                runtime_document(vhl_name="atomic-b"),
            )
            result = self.run_script(
                BIN / "file_manager.sh",
                root,
                file_env,
                (str(recording), "2", "100", "caller"),
            )
            self.check(
                result.returncode == 0
                and len(list(recording.glob("atomic-a_*"))) == 2
                and len(list(recording.glob("atomic-b_*"))) == 3,
                "file manager retains one runtime VHL value for the invocation",
            )

            self.clear_events(env)
            self.write_json(runtime_path, runtime_document(app="atomic-app-a"))
            cpu_env = self.swap_env(
                root,
                {**env, "PIM_TEST_PID": "4242"},
                "cpu-limit",
                runtime_document(app="atomic-app-b"),
            )
            result = self.run_script(
                BIN / "cpu_limit.sh", root, cpu_env, ("50",)
            )
            self.check(
                result.returncode == 0
                and self.command_lines(env, "pgrep")
                == ["pgrep <-f> <--> <atomic-app-a>"]
                and self.command_lines(env, "cpulimit")
                == ["cpulimit <-p> <4242> <-l> <50>"],
                "CPU limiter retains one runtime app value for the invocation",
            )

            rotate_original = runtime_document(
                cam_ch0=True,
                cam_ch0_rotate=True,
                cam_ch1=True,
                cam_ch1_rotate=False,
                cam_ch2=True,
                cam_ch2_rotate=True,
                cam_ch3=True,
                cam_ch3_rotate=False,
            )
            rotate_replacement = runtime_document(
                cam_ch0=False,
                cam_ch0_rotate=False,
                cam_ch1=False,
                cam_ch1_rotate=False,
                cam_ch2=False,
                cam_ch2_rotate=False,
                cam_ch3=False,
                cam_ch3_rotate=False,
            )
            self.clear_events(env)
            self.write_json(runtime_path, rotate_original)
            rotate_env = self.swap_env(
                root, env, "rotate", rotate_replacement
            )
            result = self.run_script(
                BIN / "cam_rotate_setting.sh", root, rotate_env
            )
            expected_writes = [
                "i2ctransfer <-f> <-y> <-a> <2> <w4@0x11> <0x10> <0x0c> <0x00> <0x03>",
                "i2ctransfer <-f> <-y> <-a> <2> <w4@0x12> <0x10> <0x0c> <0x00> <0x00>",
                "i2ctransfer <-f> <-y> <-a> <1> <w4@0x11> <0x10> <0x0c> <0x00> <0x03>",
                "i2ctransfer <-f> <-y> <-a> <1> <w4@0x12> <0x10> <0x0c> <0x00> <0x00>",
            ]
            self.check(
                result.returncode == 0
                and self.command_lines(env, "i2ctransfer") == expected_writes,
                "rotation retains one runtime channel map for the invocation",
            )

            self.clear_events(env)
            Path(env["PIM_NCSFTP_FILE_CHECK"]).write_text(
                "ready\n", encoding="utf-8"
            )
            self.write_json(
                runtime_path,
                runtime_document(recording_time=7, vhl_name="atomic-a"),
            )
            ftp_env = self.swap_env(
                root,
                env,
                "ncsftp",
                runtime_document(recording_time=9, vhl_name="atomic-b"),
            )
            result = self.run_script(BIN / "ncsftp.sh", root, ftp_env)
            self.check(
                result.returncode == 0
                and self.command_lines(env, "date")
                == ["date <+%Y%m%d_%H%M00> <-d> <7 min ago>"]
                and self.command_lines(env, "ncftpput")
                == [
                    "ncftpput <-u> <jhw> <-p> <jhw> <192.168.1.129> "
                    "</opt/sda/Downloads> "
                    f"<{env['PIM_NCSFTP_TRANSFER_PATH']}/atomic-a_20260907_120000*>"
                ],
                "FTP consumer retains one runtime time/name pair for the invocation",
            )

            self.clear_events(env)
            Path(env["PIM_TEST_CAM_STATE_FILE"]).write_text(
                "active\n", encoding="utf-8"
            )
            Path(env["PIM_SD_MOUNT_FLAG"]).write_text("1\n", encoding="utf-8")
            self.write_json(
                runtime_path,
                runtime_document(tmp_path=env["PIM_SD_MOUNT_DIR"]),
            )
            stop_env = self.swap_env(
                root,
                {**env, "PIM_TEST_TRACK_CAM_STATE": "1"},
                "sd-stop",
                runtime_document(tmp_path="/dev/shm"),
            )
            result = self.run_script(BIN / "sd_mount_stop.sh", root, stop_env)
            stop_at = self.event_index(env, "systemctl <stop> <cam-operate>")
            unmount_at = self.event_index(
                env, f"umount <{env['PIM_SD_DEVICE']}>"
            )
            self.check(
                result.returncode == 0
                and stop_at >= 0
                and unmount_at > stop_at
                and "writer-active-at-unmount" not in self.events(env),
                "SD stop cannot change writer ownership after runtime validation",
            )

    def vhl_path_safety_test(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runtime-vhl-path-safety.") as raw:
            root = Path(raw)
            env = self.base_env(root)
            runtime_path = Path(env["PIM_CAMERA_RUNTIME_JSON"])
            then = time.time() - 60
            file_cases = (
                ("runtime traversal", "../escape-runtime", "caller", True),
                ("runtime wildcard", "wild*runtime", "caller", False),
                ("runtime control character", "bad\nname", "caller", False),
                ("caller traversal", "", "../escape-caller", True),
                ("caller wildcard", "", "call*wild", False),
                ("caller control character", "", "call\nname", False),
            )
            for index, (label, runtime_name, caller_key, escapes_root) in enumerate(
                file_cases
            ):
                recording = root / f"file-case-{index}"
                recording.mkdir()
                effective = runtime_name or caller_key
                prefix = effective[3:] if effective.startswith("../") else effective
                candidate_parent = root if escapes_root else recording
                candidates = []
                for file_index in range(3):
                    candidate = candidate_parent / f"{prefix}_{file_index}.mp4"
                    candidate.write_text(label, encoding="utf-8")
                    os.utime(
                        candidate,
                        (then + file_index, then + file_index),
                    )
                    candidates.append(candidate)
                before = {path: path.read_bytes() for path in candidates}
                self.write_json(
                    runtime_path,
                    runtime_document(vhl_name=runtime_name),
                )
                result = self.run_script(
                    BIN / "file_manager.sh",
                    root,
                    env,
                    (str(recording), "2", "100", caller_key),
                )
                after = {
                    path: path.read_bytes()
                    for path in candidates
                    if path.exists()
                }
                self.check(
                    result.returncode == 64 and after == before,
                    f"file manager rejects {label} with zero deletion",
                )

            transfer_root = Path(env["PIM_NCSFTP_TRANSFER_PATH"])
            transfer_root.mkdir(exist_ok=True)
            ftp_cases = (
                ("traversal VHL", "../escape-ftp", True),
                ("wildcard VHL", "ftp*wild", False),
                ("control-character VHL", "ftp\nname", False),
            )
            for index, (label, vhl_name, escapes_root) in enumerate(ftp_cases):
                prefix = vhl_name[3:] if vhl_name.startswith("../") else vhl_name
                candidate_parent = root if escapes_root else transfer_root
                candidate = (
                    candidate_parent
                    / f"{prefix}_20260907_120000_{index}.mp4"
                )
                candidate.write_text(label, encoding="utf-8")
                before = candidate.read_bytes()
                self.clear_events(env)
                Path(env["PIM_NCSFTP_FILE_CHECK"]).write_text(
                    "ready\n", encoding="utf-8"
                )
                self.write_json(
                    runtime_path,
                    runtime_document(recording_time=7, vhl_name=vhl_name),
                )
                result = self.run_script(BIN / "ncsftp.sh", root, env)
                self.check(
                    result.returncode == 64
                    and not self.command_lines(env, "date")
                    and not self.command_lines(env, "ncftpput")
                    and candidate.read_bytes() == before
                    and Path(env["PIM_NCSFTP_FILE_CHECK"]).read_text(
                        encoding="utf-8"
                    )
                    == "ready\n",
                    f"FTP consumer rejects {label} before date or network access",
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
            "runtime_atomic_swap": self.runtime_atomic_swap_test,
            "vhl_path_safety": self.vhl_path_safety_test,
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
