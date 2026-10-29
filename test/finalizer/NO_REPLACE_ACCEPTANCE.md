# Finalizer atomic no-replace: target compatibility & acceptance

Draft only: [PIM Finalizer PR #229](https://github.com/jhw7500/pim-package-jhw/pull/229).
No merged product package, installed target binary, SD change or board test is implied by this document.

## Product problem and supported publication contract

The old finalizer used a plain mv into a final video/SRT path, which could replace an existing finalized recording with the same basename. Its RAM-to-SD staging also used a replacing cp. New source rejects symlink/zero-byte inputs and publishes without silently replacing a stage or final entry.

The Draft release must ship a small native C program at
`/opt/pim/bin/finalizer_noreplace`. Source:
`tools/finalizer_noreplace.c`. It invokes Linux
`renameat2(AT_FDCWD, from, AT_FDCWD, to, RENAME_NOREPLACE)`.
It requires two distinct absolute paths; invalid or missing/empty/symlink source fails. **Existing destination, including symlink, is never replaced**. An unsupported flag, cross-device rename, or missing executable is a hard failure; no unsafe fallback to plain mv/cp is permitted.

Publication steps in the actual `MovePartFile()`:

1. RAM-to-SD: create a unique **private temporary directory** under the SD staging directory and copy the RAM fragment into a **new file** there (not an existing `mktemp` file). Use `cp --preserve=timestamps` with a scoped `umask 022` so ordinary source read modes (`0644`, `0640`, `0600`) survive on ext4 while FAT32/exFAT does not require Unix ownership/mode syscalls. Sync, atomically rename the new file to the intended staged basename using RENAME_NOREPLACE, remove the now-empty private directory, and only then remove the RAM copy. If staging already exists, preserve the RAM source and reject this attempt.
2. Staging-to-final: rename the staged pathname to the final pathname using RENAME_NOREPLACE. A successful syscall atomically removes the staged directory entry and creates the final entry. Neither a destination symlink nor a colliding finalized MP4/SRT is overwritten. Sync the destination and directory, then update the final arrival heartbeat.

The move is *per file*, not a multi-channel transaction. It does not prove that the writer closed its FD, that SRT is complete, or that power loss cannot affect directory durability.

### Durability and storage-error fail-closed contract

A successful `renameat2(RENAME_NOREPLACE)` guarantees one atomic pathname
transition, **not** persistence across power failure. Every required
file/directory `sync -f` falls back to the product's global `sync` for older
coreutils; **if both attempts fail**, the finalizer must return failure or
increase the session's failure count, retain the `.all_done` marker and
not falsely report a successful final arrival.

- Stage1 copied temp data sync fails: remove the scratch copy and private
  staging directory, retain the RAM source. No final heartbeat.
- Stage1 staged-directory sync fails *after* the atomic rename: retain RAM
  source and staged pathname for explicit recovery, do not publish a final
  pathname or heartbeat.
- Stage2 final-file or final-directory sync fails *after* successful rename:
  the final pathname may already exist and the staged source may be gone.
  Return failure, retain the session completion marker, and do not write
  the final-arrival heartbeat. Never replay a destructive move blindly.
- Session-level final directory sync fails after all individual files:
  record a failure and retain the marker even if every expected artifact
  currently exists. Reconcile the marker and file provenance separately.

These paths are exercised in **synthetic storage-fault injection** using the
real `MovePartFile()`/`ProcessCompletedSessions()` functions in scratch
directories. They do **not** establish physical SD-card power-loss durability,
nor that an installed kernel handles all writeback errors correctly.


## Filesystem compatibility

Linux `renameat2(RENAME_NOREPLACE)` is supported by ext4 and by vfat since Linux 4.9. Linux 5.10 exFAT source handles RENAME_NOREPLACE too, via VFS existence checks:
- https://man7.org/linux/man-pages/man2/renameat2.2.html
- https://fossies.org/linux/kernel/v5.10/linux-5.10.266.tar.xz/linux-5.10.266/fs/exfat/namei.c

But **the actual board kernel, filesystem driver, mount options and configured SD/RAM/fallback paths remain unverified**. The PIM package supports ext4, FAT32 and exFAT in source/release notes; the presence of a driver alone does not attest that this exact deployed system accepts the syscall. The finalizer must fail closed on ENOSYS, EINVAL, EOPNOTSUPP and EXDEV. A target-safe test is required before any release.

### Isolated Linux filesystem-matrix evidence

`test/finalizer/run_filesystem_matrix.sh` creates disposable **loopback image files**, never touches a production SD card, and uses the actual compiled C publisher to validate collision protection of video/SRT, one successful publish, and EXDEV fail-closed behavior. Ubuntu 22.04 Azure kernel 6.8 passed ext4/vfat but lacked an exFAT kernel mount driver (therefore exFAT was not tested there). Ubuntu 24.04 Azure kernel 7.0 **successfully mounted and tested ext4, FAT32(vfat) and exFAT** in GitHub Actions run `40876215485`, all three PASS. This demonstrates behavior on that hosted Linux kernel only; it does **not** attest to the i.MX8MP's deployed kernel, actual SD-card mount, or live recorder state.

## Build and packaging gate

Full product builds via `docker/build.sh` use the Ubuntu 20.04 ARM64 build environment, then invoke `build.sh`. That full-release path must run
`tools/build_finalizer_noreplace.sh`, produce the ARM64 helper into `dist/pim/opt/pim/bin/` before release is copied, and validate that its ELF machine is **AArch64** and its versioned GLIBC requirements do not exceed the target rootfs **GLIBC 2.31** using `tools/check_glibc.sh`. The generated target executable is gitignored, not committed.

If the helper cannot be compiled or compatibility-checked, **do not create a release DEB**. Any handoff packaging path that bypasses the full builder must check for the target executable and refuse missing helpers. A dedicated GitHub Ubuntu 20.04 **ARM64** container workflow also compiles and executes the target C helper using QEMU, verifies the AArch64 ELF machine, strict GLIBC 2.31 gate and no-replace collision behavior. Artifact SHA256: `94853e6287dfafcab9d6b3682b239d23e7da5c12ff42b68074382a9d6ca0cfe6`. The native publish/test suite additionally verifies the process `umask 077` does not turn source file modes `0644`, `0640`, `0600` into unconditionally `0600` at final destination. Both normal packaging and external handoff forcibly set strict GLIBC 2.31 limits even if inherited environment variables would disable the gate. These CI results are **not** installed DEB or actual device compatibility proof. Record target helper/source hashes and installed package manifest under an owner-approved release.

## Crash/recovery and operational safety

- During RAM-to-SD private copy: failure removes the incomplete file and its private directory; process crash might leave a hidden `.finalizer-stage1.*` **directory** containing an incomplete recording. Such orphans require controlled reconciliation; never silently treat them as finalized.
- After Stage1 rename but before RAM unlink: both RAM input and SD staged copy can coexist; restart refuses to overwrite the existing stage. Investigate under an owner-approved recovery process.
- Before Stage2 rename: staged source still owns the bytes. After a successful Stage2 rename: only the final pathname exists, even if the process crashes before heartbeat or marker removal.
- On restart after the successful final rename: a still-present `.all_done` marker with no discoverable staged fragments remains pending for controlled reconciliation, not automatically consumed.
- Existing final from a prior recording: new staged source and old final both survive; marker remains pending.
- Simultaneous workers targeting the same final path: RENAME_NOREPLACE allows at most one successful rename, retaining the losing source.
- A still-open recorder writer FD may continue writing to the inode after rename. **Independent close/EOS and writer ownership attestation remains mandatory** before finalization and ORD retention.
- A malicious process with directory write access could swap path components between `lstat` and rename; installed directory ownership/mount/permissions are additional requirements. This Draft is not a hardened untrusted-directory sandbox.

No automatic orphan cleanup, retry of uncertain COPY packets, unlink of existing finalized recordings, or device mount changes are authorized by this change.

## Offline regression scope

`test/finalizer/test_move_part_no_replace.py` extracts the exact shell `MovePartFile` and compiles the actual C source into an isolated native-test executable. Tempfile-only tests cover colliding existing MP4/SRT, SD stage collision, symlinks, partial copies, concurrent claims, unsupported helper/error simulation, cross-filesystem failure, Stage1 RAM unlink failure and post-rename crash/marker recovery. `test/finalizer/test_completed_session_marker.py` separately covers session/channel/SRT completeness checks.

Acceptance beyond offline tests: full ARM64 package build and SHA, filesystem-specific normal/collision/cross-device observations on a disposable **test directory** with an actual owner-controlled board lease, read-only mount/runtime evidence, validated writer FD closure, rollback, independent human review, then explicit merge/deploy approval. Do not test in live recording directories.

**This PR remains Draft/unmerged/uninstalled until the above is satisfied.**
