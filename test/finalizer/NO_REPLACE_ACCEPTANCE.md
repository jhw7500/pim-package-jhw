# Finalizer no-replace publication — Draft PR #229

This note describes the **unmerged, uninstalled** change to
`dist/pim/opt/pim/bin/chk_cam_operate.sh::MovePartFile`.
It does not authorize SD-card access, service restart, deployment, or deletion.

## Safety objective

The old finalizer moved files with a normal `mv`, which can replace an already
finalized recording (MP4/TS) or SRT of the same basename. The former RAM-to-SD
`cp` could also replace an existing staged file. A session marker or output
file existing after the fact cannot prove the prior bytes were preserved.

The Draft change applies two *no-replace* stages:

1. **RAM to SD staging:** copy the input to an unpredictable private file
   within `sd_tmp_path`, preserve source metadata (`cp -p`), sync, then
   claim `sd_tmp_path/<original name>` with a hardlink (`ln`). If the
   staging basename already exists, the claim fails, the temporary file is
   removed, and the original RAM file is retained. The RAM input is removed
   only after a staged copy has been linked.
2. **SD staging to final:** hardlink the staged inode to the final basename.
   An existing final file or symlink causes the link to fail atomically;
   neither file is overwritten. Only after a successful claim/sync is the
   staging pathname unlinked. A failure retains the session marker for
   inspection.

The hash/inode and all original-file bytes are never intentionally replaced.
`ln(2)` gives atomic *name creation without overwrite* on the **same
filesystem**. This is not a transactional multi-file commit and does not by
itself prove the recorder's write FD has closed.

## Critical deployment compatibility gate

The product supports SD cards mounted as **FAT32, ext4, or exFAT** (see
`docs/RELEASE_NOTES_version_0.5.4-0.5.7.md`). FAT-style filesystems generally
do **not** provide Unix hardlinks. If hardlinks are unsupported or if
`sd_tmp_path` and `final_path` cross filesystem boundaries, the finalizer
**fails closed** instead of falling back to a replacing `mv` or exposing a
partial destination. The application may then be unable to finalize recordings.

**Do not merge/deploy this implementation until the installed filesystem,
mount options, toolchain and all configured fallback modes have been checked
under the official board safety procedure.** For unsupported filesystems a
separate reviewed publish method (such as a target-verified
`renameat2(RENAME_NOREPLACE)` helper) is required. No such helper has been
installed or verified here.

## Crash/recovery contract (conservative)

- Crash during RAM-to-SD copy: a hidden `.finalizer-stage1.*` temporary
  file may remain. Never interpret it as a completed recording or delete it
  automatically without a separately reviewed recovery policy.
- Crash after a stage hardlink but before unlink: two paths may refer to the
  same inode. The next publish attempt fails on the existing basename rather
  than replacing it. Inspect the source/stage/final paths under approved
  recovery; do **not** automatically consume `.all_done`.
- Collision involving a different prior final: retain old final bytes,
  preserve the new staged source, return failure and retain the marker.
- A live recorder still writing through an existing FD can continue
  modifying the inode after `ln`. Writer lifecycle **must be verified
  independently** before any production finalization or retention action.

## Offline evidence in this PR

`test/finalizer/test_move_part_no_replace.py` extracts and executes the
**actual** shell `MovePartFile` with private temporary directories. Tests
cover an existing video/SRT destination, Stage-1 collision, partial copy,
link failure, symlink input/destination, concurrent winner selection,
source-unlink failure, same-inode crash recovery, and cross-filesystem
fail-closed behavior. No user recordings or board paths are used.

`test/finalizer/test_completed_session_marker.py` separately exercises
required channel/video/SRT marker retention. All isolated successes are
native Linux proof only; they do not attest to an installed SD filesystem,
GStreamer EOS/fragment closure, VCM SRT contents, or real-board recovery.

Until the above is satisfied, keep **PR #229 Draft/unmerged**.
