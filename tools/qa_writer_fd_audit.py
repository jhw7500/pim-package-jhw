#!/usr/bin/env python3
"""PIM writer lifecycle read-only probe (review evidence only).

It never kills a process, touches recording media, or grants a Writer Fence.
A single /proc observation cannot prove EOS/fsync, prevent a subsequent
reopen, or establish the official board lease. Hardware QA remains BLOCKED.

The command's production defaults are /proc and /mnt/sd_cam. Tests inject
private fake /proc and private recording directories.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import time

# Names are from product cam recovery and gstApp/ORD/VCM. Finalizer may be
# a thread inside gstApp, so any *other* process with a writable FD into
# the recorded-media tree is also treated as a writer.
WRITERS = frozenset(("gstApp", "PIMCAM", "streamApp", "ord", "vcm"))
MAX_PIDS = 131072
MAX_FDS_PER_PID = 65536
MAX_RECORDING_WALK = 50000


class AuditBlocked(RuntimeError):
    pass


def _proc_start(stat_line: str) -> str:
    # PID (name with spaces) state ppid ... starttime is field 22.
    # After the closing ')', field 3 is index 0, field 22 is index 19.
    if ") " not in stat_line:
        raise AuditBlocked("bad proc stat framing")
    fields = stat_line.rsplit(") ", 1)[1].split()
    if len(fields) <= 19 or not fields[19].isdigit():
        raise AuditBlocked("missing process starttime")
    return fields[19]


def _read_text(path: Path, limit: int = 65536) -> str:
    try:
        with path.open("rb") as reader:
            data = reader.read(limit + 1)
        if len(data) > limit or b"\0" in data:
            raise AuditBlocked("untrusted proc text")
        return data.decode("utf-8").strip()
    except (OSError, UnicodeError) as exc:
        raise AuditBlocked("proc observation unavailable") from exc


def _writable_flags(path: Path) -> bool:
    # fdinfo flags are octal and include O_ACCMODE. Unknown is never clean.
    data = _read_text(path, 8192)
    entries = [line.partition(":")[2].strip() for line in data.splitlines()
               if line.startswith("flags:")]
    if len(entries) != 1 or not re.fullmatch(r"[0-7]+", entries[0]):
        raise AuditBlocked("unknown FD open mode")
    return (int(entries[0], 8) & os.O_ACCMODE) != os.O_RDONLY


def _is_under(path: str, root: str) -> bool:
    if path.endswith(" (deleted)"):
        path = path[:-10]
    if not path.startswith("/"):
        return False
    normalized = os.path.normpath(path)
    return os.path.commonpath((normalized, root)) == root


def _pid_snapshot(proc_root: Path) -> dict:
    if proc_root.is_symlink() or not proc_root.is_dir():
        raise AuditBlocked("proc root invalid")
    out = {}
    try:
        entries = list(proc_root.iterdir())
    except OSError as exc:
        raise AuditBlocked("proc enumeration unavailable") from exc
    numeric = [p for p in entries if p.name.isdigit()]
    if len(numeric) > MAX_PIDS:
        raise AuditBlocked("proc entry bound exceeded")
    for entry in numeric:
        if entry.is_symlink():
            raise AuditBlocked("PID directory alias")
        # Process races must block; no "process went away so we are clean".
        stat_text = _read_text(entry / "stat")
        start = _proc_start(stat_text)
        comm = _read_text(entry / "comm")
        if not comm or len(comm) > 15:
            raise AuditBlocked("untrusted process name")
        out[entry.name] = (comm, start)
    return out


def _scan_part_files(recording_root: Path) -> int:
    count = 0
    scanned = 0
    stack = [recording_root]
    while stack:
        folder = stack.pop()
        try:
            with os.scandir(folder) as iterator:
                entries = list(iterator)
        except OSError as exc:
            raise AuditBlocked("recording traversal unavailable") from exc
        for ent in entries:
            scanned += 1
            if scanned > MAX_RECORDING_WALK:
                raise AuditBlocked("recording walk bound exceeded")
            # Unknown alias inside mounted media cannot establish closure.
            if ent.is_symlink():
                raise AuditBlocked("recording path symlink encountered")
            if ent.is_dir(follow_symlinks=False):
                stack.append(Path(ent.path))
            elif ent.is_file(follow_symlinks=False):
                if ent.name.endswith((".part", ".tmp", ".pending")):
                    count += 1
            else:
                raise AuditBlocked("unknown recording file type")
    return count


def audit(proc_root: Path = Path("/proc"),
          recording_root: Path = Path("/mnt/sd_cam"),
          *, inspect_partial_files: bool = True) -> dict:
    """One bounded read-only snapshot; deliberately never grants admission."""
    results = {
        "schema": 1, "observed_at_unix": int(time.time()),
        "decision": "BLOCK", "hardware_execution_authorized": False,
        "writer_fence_session": None, "eos_verified": False,
        "fsync_verified": False, "writer_cannot_reopen": False,
        "official_lease_verified": False, "finalizer_verified": False,
        "reason_codes": [],
        "active_writer_pids": [], "recording_write_fds": [],
        "partial_recording_files": None,
    }
    reasons = results["reason_codes"]
    root = Path(recording_root)
    proc = Path(proc_root)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        reasons.append("RECORDING_ROOT_UNTRUSTED")
        return results
    # No mutation and no claim of mount identity. A separate authoritative
    # board-side mount + dev and boot sample is still required.
    normalized = os.path.normpath(str(root))
    try:
        before = _pid_snapshot(proc)
        for pid, (comm, start) in before.items():
            if comm in WRITERS:
                results["active_writer_pids"].append(int(pid))
            fd_dir = proc / pid / "fd"
            try:
                handles = list(fd_dir.iterdir())
            except OSError as exc:
                raise AuditBlocked("FD enumeration unavailable") from exc
            if len(handles) > MAX_FDS_PER_PID:
                raise AuditBlocked("FD scan bound exceeded")
            for f in handles:
                if not f.name.isdigit():
                    raise AuditBlocked("unexpected FD entry")
                try:
                    link = os.readlink(f)
                except OSError as exc:
                    raise AuditBlocked("FD target unavailable") from exc
                if not _is_under(link, normalized):
                    continue
                if _writable_flags(proc / pid / "fdinfo" / f.name):
                    results["recording_write_fds"].append({"pid": int(pid),
                                                          "fd": int(f.name)})
            # Recheck every visited process, not just active writer names.
            # A changed identity invalidates the entire recording FD snapshot.
            if _proc_start(_read_text(proc / pid / "stat")) != start:
                raise AuditBlocked("PID changed during observation")
        after = _pid_snapshot(proc)
        if before != after:
            raise AuditBlocked("PID set changed during observation")
        if inspect_partial_files:
            results["partial_recording_files"] = _scan_part_files(root)
    except AuditBlocked as exc:
        reasons.append("READ_ONLY_OBSERVATION_INCOMPLETE")
        results["inspection_error"] = str(exc)
        return results
    except (OSError, ValueError) as exc:
        reasons.append("READ_ONLY_OBSERVATION_INCOMPLETE")
        results["inspection_error"] = type(exc).__name__
        return results
    if results["active_writer_pids"]:
        reasons.append("ACTIVE_WRITER_PROCESS")
    if results["recording_write_fds"]:
        reasons.append("RECORDING_WRITABLE_FD_OPEN")
    if results["partial_recording_files"]:
        reasons.append("RECORDING_PARTIAL_FILES_PRESENT")
    # Absence only at two observation instants is not persistent fencing.
    reasons.extend(("EOS_FSYNC_NOT_ATTESTED",
                    "OWNER_NO_REOPEN_FENCE_NOT_ATTESTED",
                    "FINALIZER_CLOSE_NOT_ATTESTED",
                    "OFFICIAL_LEASE_NOT_ATTESTED",
                    "INSTALLED_SOURCE_AND_MOUNT_NOT_ATTESTED"))
    return results


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Read-only PIM writer FD probe")
    parser.add_argument("--proc-root", type=Path, default=Path("/proc"))
    parser.add_argument("--recording-root", type=Path, default=Path("/mnt/sd_cam"))
    args = parser.parse_args(argv)
    # This tool is evidence only. Non-zero does NOT mean a failed probe:
    # 2 means it cannot prove safe hardware execution, as designed.
    output = audit(args.proc_root, args.recording_root)
    print(json.dumps(output, sort_keys=True))
    return 2


if __name__ == "__main__":
    sys.exit(main())
