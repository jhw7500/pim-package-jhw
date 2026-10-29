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

1. RAM-to-SD: make a unique temporary file in the SD staging directory; copy RAM fragment bytes and preserve only source timestamps (FAT32/exFAT cannot reliably preserve Unix ownership/mode), sync temp, atomically rename the temp to the intended staged basename using RENAME_NOREPLACE; only then remove the RAM copy. If the staged basename already exists, preserve the RAM source and reject this attempt.
2. Staging-to-final: rename the staged pathname to the final pathname using RENAME_NOREPLACE. A successful syscall atomically removes the staged directory entry and creates the final entry. Neither a destination symlink nor a colliding finalized MP4/SRT is overwritten. Sync the destination and directory, then update the final arrival heartbeat.

The move is *per file*, not a multi-channel transaction. It does not prove that the writer closed its FD, that SRT is complete, or that power loss cannot affect directory durability.

## Filesystem compatibility

Linux `renameat2(RENAME_NOREPLACE)` is supported by ext4 and by vfat since Linux 4.9. Linux 5.10 exFAT source handles RENAME_NOREPLACE too, via VFS existence checks:
- https://man7.org/linux/man-pages/man2/renameat2.2.html
- https://fossies.org/linux/kernel/v5.10/linux-5.10.266.tar.xz/linux-5.10.266/fs/exfat/namei.c

But **the actual board kernel, filesystem driver, mount options and configured SD/RAM/fallback paths remain unverified**. The PIM package supports ext4, FAT32 and exFAT in source/release notes; the presence of a driver alone does not attest that this exact deployed system accepts the syscall. The finalizer must fail closed on ENOSYS, EINVAL, EOPNOTSUPP and EXDEV. A target-safe test is required before any release.

## Build and packaging gate

Full product builds via `docker/build.sh` use the Ubuntu 20.04 ARM64 build environment, then invoke `build.sh`. That full-release path must run
`tools/build_finalizer_noreplace.sh`, produce the ARM64 helper into `dist/pim/opt/pim/bin/` before release is copied, and validate that its ELF machine is **AArch64** and its versioned GLIBC requirements do not exceed the target rootfs **GLIBC 2.31** using `tools/check_glibc.sh`. The generated target executable is gitignored, not committed.

If the helper cannot be compiled or compatibility-checked, **do not create a release DEB**. Any handoff packaging path that bypasses the full builder must check for the target executable and refuse missing helpers. The current GitHub Actions tests compile the C source on Ubuntu runners for native QA; this is NOT proof of ARM64 target helper compilation or installed DEB compatibility. Record the target ELF SHA256 and package manifest at official target release.

## Crash/recovery and operational safety

- During RAM-to-SD private copy: failure removes the incomplete private temp; process crash might leave a hidden `.finalizer-stage1.*` file for controlled reconciliation.
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
