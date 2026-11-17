#!/usr/bin/env python3
"""Offline, restartable multi-file QA restore worker and writer-fence proof gate.

The worker deliberately accepts only a private sandbox containing .offline-only.
It cannot operate on a mounted PIM board or issue a writer fence. Connecting it
to hardware requires an independently reviewed Owner/lease/Writer adapter.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import time

FILES = ("edgeconf.json", "ord_vcm.json", "merged_runtime.json", "led_state.json")
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
SHA64 = re.compile(r"[0-9a-f]{64}\Z")
IDENTITY = re.compile(r"[A-Za-z0-9._:-]{1,128}\Z")
MAX_BYTES = 1024 * 1024
SANDBOX_MAGIC = b"PIM_QA_OFFLINE_SANDBOX_V1\n"
MARKER = "qa-maintenance.json"
STATES = ("RESTORE_PENDING", "FINAL_ATTESTATION_PENDING")


class RestoreBlocked(RuntimeError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def assess_writer_fence(proof: dict) -> dict:
    """Review candidate only: input JSON is never an authenticated Owner token."""
    mandatory = {
        "lease_holder": str, "lease_generation": int, "boot_id": str,
        "owner_invocation": str, "installed_source_sha": str,
        "writer_eos": bool, "writer_fsync": bool, "finalizer_closed": bool,
        "writable_fd_count": int, "restart_inhibited": bool,
        "writer_cannot_reopen": bool, "lease_current": bool,
    }
    blockers = []
    if type(proof) is not dict or set(proof) != set(mandatory):
        blockers.append("PROOF_SCHEMA_UNTRUSTED")
    else:
        for key, kind in mandatory.items():
            if type(proof[key]) is not kind:
                blockers.append("PROOF_TYPE_" + key.upper())
        if not blockers:
            for key in ("lease_holder", "boot_id", "owner_invocation"):
                if not IDENTITY.fullmatch(proof[key]):
                    blockers.append("IDENTITY_" + key.upper())
            if proof["lease_generation"] < 1:
                blockers.append("LEASE_GENERATION_INVALID")
            if not SHA40.fullmatch(proof["installed_source_sha"]):
                blockers.append("SOURCE_SHA_INVALID")
            for key in ("writer_eos", "writer_fsync", "finalizer_closed",
                        "restart_inhibited", "writer_cannot_reopen", "lease_current"):
                if not proof[key]:
                    blockers.append(key.upper() + "_UNVERIFIED")
            if proof["writable_fd_count"] != 0:
                blockers.append("WRITER_FD_NOT_CLOSED")
    return {
        "decision": "BLOCK" if blockers else "REVIEW_REQUIRED",
        "reason_codes": blockers or ["INDEPENDENT_OWNER_ATTESTATION_REQUIRED"],
        "writer_fence_session": None,
        "writer_closed": False,
        "writer_cannot_reopen": False,
        "hardware_execution_authorized": False,
    }


def _open_dir(path: Path) -> int:
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
        s = os.fstat(fd)
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or stat.S_IMODE(s.st_mode) != 0o700:
            os.close(fd)
            raise RestoreBlocked("unsafe sandbox directory identity or mode")
        return fd
    except OSError as exc:
        raise RestoreBlocked("sandbox directory unavailable") from exc


def _safe_file(fd: int, name: str) -> bytes:
    if name not in (*FILES, MARKER, ".offline-only"):
        raise RestoreBlocked("file outside fixed allowlist")
    handle = None
    try:
        handle = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=fd)
        s = os.fstat(handle)
        if (not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.getuid()
                or stat.S_IMODE(s.st_mode) != 0o600 or not 0 < s.st_size <= MAX_BYTES):
            raise RestoreBlocked("untrusted file: " + name)
        chunks = bytearray()
        while len(chunks) <= MAX_BYTES:
            piece = os.read(handle, 65536)
            if not piece:
                break
            chunks.extend(piece)
        if len(chunks) != s.st_size:
            raise RestoreBlocked("file changed during read: " + name)
        return bytes(chunks)
    except OSError as exc:
        raise RestoreBlocked("file missing or unsafe: " + name) from exc
    finally:
        if handle is not None:
            os.close(handle)


def _write_exact(fd: int, name: str, data: bytes) -> None:
    # Refuse symlink/hardlink/missing live files instead of replacing a surprise.
    _safe_file(fd, name)
    tmp = ".qa-restore-" + secrets.token_hex(12)
    h = None
    made = False
    try:
        h = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600, dir_fd=fd)
        made = True
        view = memoryview(data)
        while view:
            n = os.write(h, view)
            if n <= 0:
                raise OSError("short write")
            view = view[n:]
        os.fsync(h)
        os.close(h)
        h = None
        os.replace(tmp, name, src_dir_fd=fd, dst_dir_fd=fd)
        made = False
        os.fsync(fd)
    except OSError as exc:
        raise RestoreBlocked("atomic restore failed: " + name) from exc
    finally:
        if h is not None:
            os.close(h)
        if made:
            try:
                os.unlink(tmp, dir_fd=fd)
            except OSError:
                pass


def _valid_record(data: bytes) -> dict:
    try:
        j = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise RestoreBlocked("corrupt restore marker") from exc
    expected = {"schema", "phase", "run_id", "source_sha", "boot_id",
                "owner_invocation", "lease_generation", "baseline", "digest"}
    if type(j) is not dict or set(j) != expected or type(j.get("schema")) is not int or j["schema"] != 1:
        raise RestoreBlocked("untrusted marker schema")
    if j["phase"] not in STATES or not all(
        type(j[k]) is str and IDENTITY.fullmatch(j[k])
        for k in ("run_id", "boot_id", "owner_invocation")
    ):
        raise RestoreBlocked("invalid marker identity or state")
    if (type(j["source_sha"]) is not str or not SHA40.fullmatch(j["source_sha"])
            or type(j["lease_generation"]) is not int or j["lease_generation"] < 1):
        raise RestoreBlocked("unverified pinned source or lease")
    if type(j["baseline"]) is not dict or set(j["baseline"]) != set(FILES):
        raise RestoreBlocked("baseline not complete")
    for name in FILES:
        b = j["baseline"][name]
        if (type(b) is not dict or set(b) != {"sha256", "size"}
                or type(b["sha256"]) is not str or not SHA64.fullmatch(b["sha256"])
                or type(b["size"]) is not int or not 0 < b["size"] <= MAX_BYTES):
            raise RestoreBlocked("invalid baseline entry: " + name)
    body = {k: v for k, v in j.items() if k != "digest"}
    digest = sha(json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    if type(j["digest"]) is not str or not secrets.compare_digest(j["digest"], digest):
        raise RestoreBlocked("restore marker digest mismatch")
    return j


class OfflineRestoreWorker:
    """Independent process, recoverable after termination, sandbox-only."""

    def __init__(self, root: Path):
        self.root = Path(root)
        if not self.root.is_absolute() or self.root.resolve(strict=True) != self.root:
            raise RestoreBlocked("canonical absolute sandbox root required")
        rootfd = _open_dir(self.root)
        try:
            if _safe_file(rootfd, ".offline-only") != SANDBOX_MAGIC:
                raise RestoreBlocked("not a designated offline sandbox")
        finally:
            os.close(rootfd)

    def _lock(self):
        fd = _open_dir(self.root)
        lockfd = None
        try:
            lockfd = os.open(".restore-worker.lock", os.O_RDWR | os.O_CREAT
                             | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
            s = os.fstat(lockfd)
            if (not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.getuid()
                    or stat.S_IMODE(s.st_mode) != 0o600):
                raise RestoreBlocked("untrusted restore lock")
            try:
                fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise RestoreBlocked("restore executor already active") from exc
            os.fsync(fd)
            return fd, lockfd
        except BaseException:
            if lockfd is not None:
                os.close(lockfd)
            os.close(fd)
            raise

    def restore_once(self, *, crash_after: int = 0) -> dict:
        """Restore four exact files, leaving marker for independent attestation."""
        fd, lockfd = self._lock()
        baseline = live = None
        try:
            marker = _valid_record(_safe_file(fd, MARKER))
            baseline = _open_dir(self.root / "baseline")
            live = _open_dir(self.root / "live")
            sources = {}
            for name in FILES:
                original = _safe_file(baseline, name)
                proof = marker["baseline"][name]
                if len(original) != proof["size"] or sha(original) != proof["sha256"]:
                    raise RestoreBlocked("baseline SHA mismatch: " + name)
                sources[name] = original
            # A static LED-OFF fixture is part of the tested baseline contract.
            try:
                led = json.loads(sources["led_state.json"].decode())
            except (ValueError, UnicodeDecodeError) as exc:
                raise RestoreBlocked("bad LED fixture") from exc
            if led != {"leds": [False, False, False, False]}:
                raise RestoreBlocked("LED-off baseline unverified")
            changed = 0
            for name in FILES:
                actual = _safe_file(live, name)
                if actual != sources[name]:
                    if marker["phase"] != "RESTORE_PENDING":
                        raise RestoreBlocked("final stage drift: " + name)
                    _write_exact(live, name, sources[name])
                    changed += 1
                    if crash_after and changed == crash_after:
                        raise RuntimeError("injected process termination after durable write")
            for name in FILES:
                if _safe_file(live, name) != sources[name]:
                    raise RestoreBlocked("restore postcondition mismatch: " + name)
            if marker["phase"] == "RESTORE_PENDING":
                marker["phase"] = "FINAL_ATTESTATION_PENDING"
                body = {k: v for k, v in marker.items() if k != "digest"}
                marker["digest"] = sha(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())
                _write_exact(fd, MARKER, (json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n").encode())
            return {"stage": "FINAL_ATTESTATION_PENDING", "files_repaired": changed,
                    "decision": "BLOCK", "writer_fence_session": None,
                    "hardware_execution_authorized": False,
                    "independent_hardware_attestation": False}
        finally:
            if live is not None:
                os.close(live)
            if baseline is not None:
                os.close(baseline)
            os.close(lockfd)
            os.close(fd)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Offline PIM QA restore executor - no board access")
    parser.add_argument("--sandbox-root", type=Path, required=True)
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--interval", type=float, default=5.0)
    args = parser.parse_args(argv)
    if args.interval < 0.2 or args.interval > 60:
        return 2
    try:
        worker = OfflineRestoreWorker(args.sandbox_root)
        while True:
            result = worker.restore_once()
            if not args.watch:
                print(json.dumps(result, sort_keys=True))
                return 0
            time.sleep(args.interval)
    except (RestoreBlocked, OSError, ValueError) as exc:
        print("QA RESTORE BLOCKED: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
