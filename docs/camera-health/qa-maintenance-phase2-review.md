# QA maintenance — Phase 2 review candidate (not approved for board)

This branch is intentionally layered on the **Draft** Phase 1 Owner restart
barrier in PR #231. It is not a deployable four-channel QA transaction.

## What was implemented

1. `cam-operate.service`, `ord-operate.service`, and `vsd-operate.service` have an
   `ExecCondition=/bin/sh /opt/pim/bin/qa_maintenance_exec_condition.sh`.
   It rejects an existing `/var/lib/pim-camera/qa-maintenance.json` marker,
   including broken symlinks and corrupt content, and missing/linked state
   directories. A denied systemd start does not create a new Owner or Writer.
   This is defense in depth: direct execution outside systemd still needs
   an Owner-backed fence and must not be mistaken for an authorized QA session.
   `vsd/tcpsvr.cc:cmd_set_config` writes edgeconf, so VSD must not restart
   while a restore marker is present. Its unit also creates the same
   StateDirectory. This prevents **new systemd starts only**: an already
   running VSD or a direct binary launch still requires a real Owner
   quiesce/no-reopen fence, which is not implemented here.
2. `tools/qa_restore_worker.py` is an **OFFLINE-ONLY** restartable,
   owner-locked restore kernel. It can restore exactly four private **sandbox**
   files (edgeconf, ORD/VCM, merged runtime and LED-off fixture) from
   individually SHA-pinned immutable baseline bytes. Each replacement is
   atomic with file and parent-directory fsync. The persistent intent marker
   is never deleted; success is only
   `FINAL_ATTESTATION_PENDING`, not permission to run physical QA.
3. `assess_writer_fence` checks the *shape* of an intended lease-bound
   EOS, finalizer fsync, writable-FD and no-reopen proof but **never**
   issues `writer_fence_session` or authorizes hardware: caller-provided
   booleans are not independent proof of a live product Owner.
4. New offline tests cover the service-start contract and crash-after-fsync
   replay, idempotency, corruption, symlinks/hardlinks, concurrent owners,
   file modes, LED-off baseline and untrusted Writer evidence.

## Deliberate restrictions

- The restore worker refuses every root without a private `0700` sandbox,
  `0600` marker and exact `.offline-only` sentinel; it cannot be pointed
  at `/var/lib/pim-camera`, `/root/shared_v`, `/mnt/sd_cam` or a live
  target. It is in the repository `tools/` path, **not** a packaged service.
- The marker's SHA digest detects accidental corruption, **not** forgery
  by a privileged actor. No trust is derived from operator-supplied evidence.
- An apparent EOS, process exit, zero writable FDs or successful restore
  in a sandbox does not prove `writer_cannot_reopen`. Only the installed
  Owner can bind its state to the current official board lease generation
  and enforce no-reopen across crashes and systemd transitions.
- No independent installed hardware restorer, signed owner attestations,
  installation parity or real Finalizer/EOS wiring has been implemented.
  Neither Phase 1 nor this candidate releases a fence or changes board
  settings. The service condition is protective but not a complete Writer
  Fence.
- No manual deletion of recordings, SD cleanup, reboot, writer kill or
  hardware test is authorized by this branch.

## Must be completed before real board testing

1. Reviewed product Owner API for `QUIESCING → QUIESCED`, bound to live
   official exclusive lease holder/generation, boot and Owner invocation;
   persist a restore intent *before* a mutating side effect.
2. Independent installed Writer/Finalizer EOS, fsync, writable-FD closure
   and no-reopen evidence from actual processes and systemd/Owner behavior.
3. Production exact-path restore adapter and **installed independently
   supervised systemd restorer** surviving host disconnect/SIGKILL/reboot,
   including all camera/ORD/VCM/merged runtime bytes and every LED OFF;
   verify restored source and installed binary SHA after restart.
4. Owner-reviewed fixed host command profile/one-use chat approval and
   fresh SD root-file limit, ORD eligible rotation, free space and Finalizer
   state evidence. A short bounded 4ch trial precedes the distinct 45-minute
   campaign.

Tracking: product issue #230; pim-check issue #192; QA PR #191 remains
review-only. Do not merge this branch to the installed board until the
independent Owner review and physical admission requirements above are met.

## CI integration scope

This Draft pull request targets `master` to exercise the repository's
existing `pull_request.branches: [master]` Camera Tests, ShellCheck and
Commitlint workflows. Accordingly its aggregate diff includes the unmerged
Phase 1 baseline from PR #231; the Phase 2-only delta starts at
`3eda4e40eec7415014eb0ecd08d0fc3a5d97e82e`. This does not change
the two-phase review or authorize release.

## Read-only maintenance status

`cam-recoveryctl maintenance-status` now reports whether the **presence**
of the persistent marker prevents recovery. It deliberately does not inspect
or trust a marker's contents, does not require the Owner to be alive, and
never returns a fence token or permission to run a test. Its JSON
`decision` is **always** `BLOCK`, including when no marker exists.
`NO_OWNER_WRITER_FENCE` is **not** an affirmative board health check.
`RESTORE_PENDING_UNVERIFIED` includes malformed, symlinked, or directory
markers; `STATE_DIRECTORY_UNTRUSTED` includes absent or symlinked storage; in that
case `marker_present` is `null` (unknown), never a misleading `false`.
It performs no write, process signal, or service control.

## Offline Owner phase protocol (next integration milestone)

`tools/qa_owner_fence_review.py` is an **isolated, non-packaged, offline**
crash-safe review state machine. It persists `QUIESCING`,
`QUIESCED_REVIEW`, `RESTORE_PENDING` and
`FINAL_ATTESTATION_PENDING` under a private 0700 sandbox, using an
exclusive lock, 0600 journal, SHA-256 integrity digest and fsync+rename.

It binds the reviewed owner tuple (boot, invocation, proc-start and source
SHA) to an exclusive lease holder, session and **generation**. Changing boot,
invocation, holder, generation or expired lease turns a prior synthetic
QUIESCED review into `RESTORE_PENDING`. EOS, media fsync, Finalizer close,
zero writable FDs and no-reopen are **distinct** requirements for a reviewed
transition. A changed original SHA, enabled LED or wrong ch0-only/15fps
restoration prevents the final review phase.

**Crucial limitation:** All parameters to this prototype are
caller-supplied and therefore not authenticated independent facts about
the real PIM board. The synthetic `QUIESCED_REVIEW` state is **not**
production `QUIESCED`: every result remains `decision=BLOCK`,
`writer_fence_session=null` and
`hardware_execution_authorized=false`. No release API is available.
The journal never deletes the persistent production maintenance marker,
starts a service, contacts a board, or alters recordings. A real Owner
must provide privileged trusted receipt collection bound to actual process
lifetimes and authoritative board lease generation, and independent
systemd restoration before any production acquisition/release can ship.

These tests exist to prevent accidental regression while that real adapter
and independently supervised restoration service are developed; do not
interpret green CI as installed Writer-Fence or physical QA acceptance.

## Boot config guard preservation (Phase 2 follow-up)

The normal `pim-config-guard.service` is another **configuration writer**:
its `config_guard.sh` can restore edgeconf and ORD/VCM from backup/seed
and can refresh both backups on an ordinary boot. That conflicts with an
unfinished QA restore transaction even when gstApp/ORD processes are stopped.

This review branch now creates the same `StateDirectory=pim-camera` for
the early boot config guard and applies the existing
`qa_maintenance_exec_condition.sh` *before* its `ExecStart`.
The direct `config_guard.sh` entrypoint additionally checks an existing
maintenance marker (including malformed contents and dangling symlinks)
before touching config/backup files and exits 75 while it is present.
A symlinked state directory is also rejected. Normal no-marker boot logic
is unchanged; unit creation ensures the persistent directory exists for
a clean first boot.

To close the **config-guard/marker creation** race once a production Owner
acquisition exists, the config guard now holds an exclusive
`/var/lib/pim-camera/qa-maintenance.lock` while reading/restoring/
refreshing configs and checks the marker **under** that lock. It refuses
a contended, symlinked or multiply hard-linked lock. The production
Owner MUST take this same lock to persist its marker, verify live Writer
quiescence and only then issue any authenticated lease-bound token.
This branch does **not** implement the marker acquisition side of that
protocol; the lock is a prerequisite, not proof of completed fencing.

**The guard is not a restorer.** It deliberately *defers* restoration to an
independent future authorized service, which does not yet exist. Never
delete the marker just to make the boot guard run. No physical boot,
package installation, or user configuration has been modified by this PR.
