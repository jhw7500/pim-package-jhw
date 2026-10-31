# QA maintenance — Phase 2 review candidate (not approved for board)

This branch is intentionally layered on the **Draft** Phase 1 Owner restart
barrier in PR #231. It is not a deployable four-channel QA transaction.

## What was implemented

1. Both `cam-operate.service` and `ord-operate.service` have an
   `ExecCondition=/bin/sh /opt/pim/bin/qa_maintenance_exec_condition.sh`.
   It rejects an existing `/var/lib/pim-camera/qa-maintenance.json` marker,
   including broken symlinks and corrupt content, and missing/linked state
   directories. A denied systemd start does not create a new Owner or Writer.
   This is defense in depth: direct execution outside systemd still needs
   an Owner-backed fence and must not be mistaken for an authorized QA session.
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
