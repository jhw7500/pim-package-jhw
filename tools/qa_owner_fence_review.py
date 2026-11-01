#!/usr/bin/env python3
"""Crash-safe Owner QUIESCING/QUIESCED **OFFLINE CONTRACT**, not a device API.

Only a 0700 temporary fixture with a 0600 .offline-only sentinel is accepted.
No service commands, network, board access, process signals, or recording I/O.
A caller-supplied lease/Writer report is never trusted as an authoritative
PIM admission token. All results return execution_authorized=False and
writer_fence_session=None, even if a synthetic transition succeeds.

This protects protocol semantics while the missing installed Owner/Writer,
official lease-generation verifier and independent restorer are implemented.
"""
from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import stat

MAGIC = b"PIM_QA_OFFLINE_SANDBOX_V1\n"
NAME = "owner-quiesce-review.json"
MAX_SIZE = 16384
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
SHA64 = re.compile(r"[0-9a-f]{64}\Z")
IDENTITY = re.compile(r"[A-Za-z0-9._:-]{1,128}\Z")
PHASES = frozenset(("QUIESCING", "QUIESCED_REVIEW",
                   "RESTORE_PENDING", "FINAL_ATTESTATION_PENDING"))


class FenceDenied(RuntimeError):
    """Unknown process, changed lease, corrupted state, or missing evidence."""


def _digest(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True,
                                     separators=(",", ":")).encode()).hexdigest()


def _text(value):
    return type(value) is str and IDENTITY.fullmatch(value) is not None


def _identity(owner, lease, baseline):
    if type(owner) is not dict or set(owner) != {
        "boot_id", "invocation_id", "proc_start_time", "source_sha"
    }:
        raise FenceDenied("OWNER_IDENTITY_UNTRUSTED")
    if not all(_text(owner[k]) for k in ("boot_id", "invocation_id", "proc_start_time")):
        raise FenceDenied("OWNER_IDENTITY_INVALID")
    if not (type(owner["source_sha"]) is str and SHA40.fullmatch(owner["source_sha"])):
        raise FenceDenied("OWNER_SOURCE_UNPINNED")
    if type(lease) is not dict or set(lease) != {
        "board_id", "holder_id", "session", "generation", "mode", "live", "expired"
    }:
        raise FenceDenied("LEASE_SCHEMA_UNTRUSTED")
    if (lease["board_id"] != "pim" or lease["mode"] != "exclusive"
            or type(lease["live"]) is not bool or lease["live"] is not True
            or type(lease["expired"]) is not bool or lease["expired"] is not False
            or type(lease["generation"]) is not int or lease["generation"] <= 0
            or not _text(lease["holder_id"]) or not _text(lease["session"])):
        raise FenceDenied("OFFICIAL_LEASE_NOT_PROVEN")
    if not (type(baseline) is str and SHA64.fullmatch(baseline)):
        raise FenceDenied("IMMUTABLE_BASELINE_MISSING")


def _status(journal):
    return {
        "phase": journal["phase"],
        "revision": journal["revision"],
        "decision": "BLOCK",
        "writer_fence_session": None,
        "writer_closed": False,
        "writer_cannot_reopen": False,
        "hardware_execution_authorized": False,
        "reason_code": "REVIEW_ONLY_NO_TRUSTED_OWNER_ATTESTATION",
    }


def _open(root):
    root = Path(root)
    # Deliberately refuse production state, recording and package paths even
    # if somebody puts the sentinel there. No paths are used for real I/O.
    raw = str(root)
    if not root.is_absolute() or root.is_symlink() or root.resolve() != root:
        raise FenceDenied("OFFLINE_SANDBOX_PATH_REQUIRED")
    if any(raw == base or raw.startswith(base + "/")
           for base in ("/var", "/run", "/root", "/mnt", "/opt", "/dev", "/sys", "/proc")):
        raise FenceDenied("PRODUCTION_PATH_FORBIDDEN")
    try:
        dfd = os.open(raw, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        info = os.fstat(dfd)
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o700):
            raise FenceDenied("OFFLINE_SANDBOX_UNTRUSTED")
        fd = os.open(".offline-only", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                     dir_fd=dfd)
        try:
            st = os.fstat(fd)
            if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1
                    or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600
                    or os.read(fd, len(MAGIC) + 1) != MAGIC):
                raise FenceDenied("OFFLINE_SANDBOX_SENTINEL_INVALID")
        finally:
            os.close(fd)
        return dfd
    except (OSError, FenceDenied) as exc:
        if "dfd" in locals():
            os.close(dfd)
        raise FenceDenied("OFFLINE_SANDBOX_UNTRUSTED") from exc


def _read(dfd):
    fd = None
    try:
        fd = os.open(NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dfd)
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1
                or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600
                or not 0 < st.st_size <= MAX_SIZE):
            raise FenceDenied("JOURNAL_FILE_UNTRUSTED")
        body = os.read(fd, MAX_SIZE + 1)
        if len(body) != st.st_size:
            raise FenceDenied("JOURNAL_READ_INCOMPLETE")
        rec = json.loads(body.decode("utf-8"))
        if (type(rec) is not dict or set(rec) != {
            "schema", "phase", "revision", "owner", "lease", "baseline", "digest"
        } or rec["schema"] != 1 or type(rec["revision"]) is not int
                or rec["revision"] < 0 or rec["phase"] not in PHASES):
            raise FenceDenied("JOURNAL_SCHEMA_UNTRUSTED")
        _identity(rec["owner"], rec["lease"], rec["baseline"])
        signed = {k: v for k, v in rec.items() if k != "digest"}
        if (type(rec["digest"]) is not str
                or not hmac.compare_digest(rec["digest"], _digest(signed))):
            raise FenceDenied("JOURNAL_DIGEST_INVALID")
        return rec
    except (OSError, UnicodeError, ValueError, TypeError, KeyError) as exc:
        raise FenceDenied("JOURNAL_UNAVAILABLE_OR_CORRUPT") from exc
    finally:
        if fd is not None:
            os.close(fd)


def _write(dfd, data):
    try:
        st = os.stat(NAME, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        st = None
    if st is not None and (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1
                           or st.st_uid != os.getuid()
                           or stat.S_IMODE(st.st_mode) != 0o600):
        raise FenceDenied("EXISTING_JOURNAL_UNTRUSTED")
    body = dict(data)
    body["digest"] = _digest(data)
    raw = (json.dumps(body, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(raw) > MAX_SIZE:
        raise FenceDenied("JOURNAL_TOO_LARGE")
    temp = ".owner-review-" + secrets.token_hex(12)
    fd = None
    created = False
    try:
        fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
                     | os.O_CLOEXEC, 0o600, dir_fd=dfd)
        created = True
        view = memoryview(raw)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise FenceDenied("JOURNAL_SHORT_WRITE")
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.rename(temp, NAME, src_dir_fd=dfd, dst_dir_fd=dfd)
        created = False
        os.fsync(dfd)
    except OSError as exc:
        raise FenceDenied("JOURNAL_WRITE_FAILED") from exc
    finally:
        if fd is not None:
            os.close(fd)
        if created:
            os.unlink(temp, dir_fd=dfd)


class OwnerFenceReview:
    """Offline durable state machine; never controls a real Owner or Writer."""

    def __init__(self, root):
        self.root = Path(root)
        fd = _open(self.root)
        os.close(fd)

    def _transaction(self, operation):
        dfd = _open(self.root)
        lock = None
        try:
            lock = os.open(".owner-review.lock", os.O_CREAT | os.O_RDWR
                           | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dfd)
            s = os.fstat(lock)
            if (not stat.S_ISREG(s.st_mode) or s.st_nlink != 1
                    or s.st_uid != os.getuid() or stat.S_IMODE(s.st_mode) != 0o600):
                raise FenceDenied("OWNER_REVIEW_LOCK_UNTRUSTED")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise FenceDenied("OWNER_REVIEW_ALREADY_ACTIVE") from exc
            return operation(dfd)
        finally:
            if lock is not None:
                os.close(lock)
            os.close(dfd)

    def begin(self, owner, lease, baseline):
        """Persist review intent before simulating any quiesce transition."""
        _identity(owner, lease, baseline)

        def op(fd):
            try:
                os.stat(NAME, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise FenceDenied("PREVIOUS_RESTORE_NOT_ATTESTED")
            record = dict(schema=1, phase="QUIESCING", revision=0,
                          owner=dict(owner), lease=dict(lease), baseline=baseline)
            _write(fd, record)
            return _status(record)
        return self._transaction(op)

    def status(self):
        return self._transaction(lambda fd: _status(_read(fd)))

    def _advance(self, current, expected_revision, next_phase, predicate):
        if type(expected_revision) is not int or current["revision"] != expected_revision:
            raise FenceDenied("STALE_OWNER_REVISION")
        if not predicate(current):
            raise FenceDenied("TRANSITION_PRECONDITION_MISSING")
        return dict(current, phase=next_phase, revision=current["revision"] + 1)

    def confirm_quiesced(self, owner, lease, evidence, expected_revision):
        """Review only; caller booleans cannot create a trusted fence token."""
        _identity(owner, lease, "0" * 64)
        if type(evidence) is not dict or set(evidence) != {
            "boot_id", "owner_invocation", "lease_generation", "eos",
            "file_fsync", "finalizer_closed", "writable_fd_count",
            "restart_inhibited", "writer_cannot_reopen"
        }:
            raise FenceDenied("WRITER_PROOF_SCHEMA_INVALID")

        def op(fd):
            c = _read(fd)
            if c["owner"] != owner or c["lease"] != lease:
                raise FenceDenied("OWNER_OR_LEASE_GENERATION_CHANGED")
            good = (evidence["boot_id"] == owner["boot_id"]
                    and evidence["owner_invocation"] == owner["invocation_id"]
                    and type(evidence["lease_generation"]) is int
                    and evidence["lease_generation"] == lease["generation"]
                    and all(type(evidence[k]) is bool and evidence[k]
                            for k in ("eos", "file_fsync", "finalizer_closed",
                                      "restart_inhibited", "writer_cannot_reopen"))
                    and type(evidence["writable_fd_count"]) is int
                    and evidence["writable_fd_count"] == 0)
            next_record = self._advance(
                c, expected_revision, "QUIESCED_REVIEW",
                lambda x: x["phase"] == "QUIESCING" and good)
            _write(fd, next_record)
            return _status(next_record)
        return self._transaction(op)

    def reconcile(self, owner, lease):
        """Revoked/changed Owner or lease always preserves restore obligation."""
        def op(fd):
            c = _read(fd)
            same = c["owner"] == owner and c["lease"] == lease
            if same:
                try:
                    _identity(owner, lease, c["baseline"])
                except FenceDenied:
                    same = False
            if not same and c["phase"] != "RESTORE_PENDING":
                c = dict(c, phase="RESTORE_PENDING", revision=c["revision"] + 1)
                _write(fd, c)
            return _status(c)
        return self._transaction(op)

    def restore_review(self, receipt, expected_revision):
        """A synthetic restore receipt is NOT a real board attestation."""
        if type(receipt) is not dict or set(receipt) != {
            "baseline_sha256", "channel_zero_only", "fps", "all_leds_off",
            "camera_ready", "ord_ready", "vcm_ready"
        }:
            raise FenceDenied("RESTORE_RECEIPT_SCHEMA_INVALID")

        def op(fd):
            c = _read(fd)
            good = (receipt["baseline_sha256"] == c["baseline"]
                    and all(type(receipt[k]) is bool and receipt[k]
                            for k in ("channel_zero_only", "all_leds_off",
                                      "camera_ready", "ord_ready", "vcm_ready"))
                    and type(receipt["fps"]) is int and receipt["fps"] == 15)
            n = self._advance(c, expected_revision, "FINAL_ATTESTATION_PENDING",
                              lambda x: x["phase"] == "RESTORE_PENDING" and good)
            _write(fd, n)
            return _status(n)
        return self._transaction(op)
