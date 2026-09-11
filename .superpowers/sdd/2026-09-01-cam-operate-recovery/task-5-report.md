# Task 5 implementation report

## Scope

Implemented bounded single-owner liveness and ordered shutdown at base
`d2533fba9b8bb91cac57db0657a4d132fc51f827`. The daemon remains the only
long-running owner. Liveness reads only the fixed runtime, makes one bounded
pass, and serializes gstApp recovery through the existing request protocol.

`restart_app.sh` was already the finite deprecated one-shot shim required by
the brief, so it was not changed. Its one-call/no-loop behavior is exercised by
`cam_liveness_test.sh`.

Two supporting library edits were required by executable RED tests:

- `cam_recovery_actions.sh`: the STOPPING executor must stop both exact app
  names after the daemon PID has exited while retaining the complete immutable
  owner tuple and STOPPING checks.
- `cam_operate_control.sh`: a failed liveness-origin gstApp action must finish
  its request/counter and use the existing legal `RECOVERING -> ACTIVE`
  transition so repeated failures can reach the persistent escalation
  threshold. Other sources and camera-health failures remain terminal
  `DEGRADED`.

No protocol/state schema, systemd unit, second owner, monitor, source search,
or runtime rewrite was added.

## TDD evidence

Initial tests were created and registered before production edits.

```text
rtk bash test/camera_health/cam_liveness_test.sh
exit 1: FAIL: Task 5 liveness library is missing: .../cam_liveness.sh

rtk bash test/camera_health/cam_stop_order_test.sh
exit 1: FAIL: Task 5 liveness library is missing: .../cam_liveness.sh
```

Additional review-driven RED evidence was retained or captured before each
production correction:

- immediate VCM exit: `expected rc=1 got=0: cam_liveness_tick`;
- invalid-runtime/foreign-owner/external signal ordering matrix failed before
  owner-context and ordered-stop corrections;
- removing the STOP executor live-PID exception reproduced exact RC69 after
  daemon exit; restoring the narrow exception passed;
- ORD `failed` state: `failed ORD was not restarted exactly once`;
- real liveness gstApp execution: `liveness failure 1 made the owner terminal`;
- before-finish boundary: `expected rc=70 got=23` before the failpoint was
  implemented;
- managed stop phase status: `expected rc=69 got=1` before exact rc capture.

The final tests prove:

- five real liveness gstApp action failures each produce an exact terminal
  history/state counter pair, leave no lease, and legally return the owner to
  ACTIVE; the next tick requests `module_reload`;
- the special failure path validates exact source/type/reason, owner,
  history/state terminal pair, request id, status, and rc before any request
  finish;
- its before-finish failpoint leaves a recoverable RUNNING request with a
  terminal failed action, never a nonterminal FAILED request;
- mismatched history rc returns RC70 with active request, owner, counters,
  history, and result fingerprints unchanged;
- legacy gstApp and non-gst liveness failures remain DEGRADED;
- foreign-owner/BUSY exit preserves the current owner/processes byte-for-byte;
- external TERM removes the daemon proc entry before exact gstApp/PIMCAM/BG
  cleanup; owner removal remains last;
- stop script and managed stop phases propagate exact 0/69/70/75-compatible
  status rather than hiding or collapsing it.

Final focused results:

```text
rtk bash test/camera_health/cam_liveness_test.sh        exit 0, cam liveness: PASS
rtk bash test/camera_health/cam_stop_order_test.sh      exit 0, cam stop order: PASS
rtk bash test/camera_health/cam_operate_control_test.sh exit 0, cam operate control: PASS
rtk bash test/camera_health/recovery_protocol_test.sh   exit 0, recovery protocol: PASS
rtk bash test/cam_link/recovery_actions_test.sh         exit 0, recovery actions: PASS
rtk bash test/cam_link/recovery_actions_safety_test.sh  exit 0, recovery actions safety: PASS
rtk bash test/cam_link/recovery_launch_safety_test.sh   exit 0, recovery launch safety: PASS
rtk bash test/cam_link/escalation_test.sh               exit 0, 7 passed / 0 failed
```

The brief names `actions_safety_test.sh` and `launch_safety_test.sh`; the
repository's actual preserved gates are the two `recovery_*_safety_test.sh`
commands above.

## Aggregate and static gates

```text
rtk bash test/camera_health/run_all.sh  exit 0
  includes recovery protocol, control, new liveness, new stop-order, and all
  existing camera-health package/producer/aggregator/bootstrap checks

rtk bash test/cam_link/run_all.sh -v    exit 0, all 14 scripts passed

rtk bash -n <all eight changed shell files>       exit 0
rtk shellcheck -S error <all eight shell files>   exit 0
rtk git diff --check                              exit 0
```

After the aggregates, no `restart_app.sh`, `chk_cam_operate.sh`,
`cam_operate_stop.sh`, or liveness process remained.

## Ordering and lifecycle invariants

The external coordinator validates and captures the live owner, persists
STOPPING, closes intake, quiesces liveness, signals and bounded-waits for the
daemon, waits for request/child work, stops exact gstApp/PIMCAM/BG then ORD and
VCM, records the terminal stop event, and removes `owner.json` last. An internal
trap that observes an existing STOPPING coordinator returns without adopting or
reordering its work.

Every liveness launch is revalidated under the recovery lock against the live
full owner identity, ACTIVE lifecycle, quiesce flag, absent leases, and valid
fixed runtime. Inspection errors remain absence-closed. ORD `inactive` and
`failed` are restartable absence states; `unknown`/query errors remain
fail-closed. VCM readiness is checked after launch so an immediate exit records
only VCM degradation.

## Graph and diff self-review

The graph was used before shell exploration and rebuilt incrementally at the
expected base. It recognized only `test/camera_health/run_all.sh` as a changed
node and reported zero changed functions, affected flows, or test gaps for the
eight Bash files. `detect_changes`, `get_affected_flows`, `get_impact_radius`,
and `get_review_context` therefore cannot model these top-level Bash paths; the
full isolated diff plus executable focused/aggregate gates are authoritative.

The final isolated diff was reviewed for owner adoption, STOPPING ordering,
exact process names, post-daemon executor context, request provenance,
counter/history pairing, legal lifecycle transitions, launch readiness,
inspection-error handling, and exact rc propagation. No unresolved in-scope
concern remains.

## Fix round 1

Base/head before this fix was
`ebc78bf54ab86ef8caba878204553dfaddf109c3`. The fix stays within the existing
owner, lock, pending/active/history/result/counter, runtime, and service-state
paths; it adds no persistent path, schema, queue, owner, monitor, or Task 6+
script migration.

### RED/GREEN evidence for the ten Important findings

| Finding | Deterministic RED | GREEN contract |
| --- | --- | --- |
| Exact liveness guard RC | `force_tick_guard_rc 69` failed `expected rc=69 got=0` (the same regression loops over 69/70/75). | Tick returns the exact 69, 70, or 75 and records zero restart/request/degraded effects. |
| Complete immutable owner authority | A `created_at` rollover at the ORD/VCM/request boundary failed `expected rc=69 got=0`; the initial all-field regression also reported `boot_id rollover hook did not mutate`. | All six fields (`boot_id`, `invocation_id`, `pid`, `proc_start_time`, `token`, `created_at`) are compared immediately before effects; each rollover returns 69 with runtime/state/lease fingerprints and effect log preserved. New owner creation refreshes the exported tuple, while later rollover remains rejected. |
| Atomic VCM launch | The close/exec race failed `VCM pre-exec boundary hook was not reached`. | The child closes its inherited lock descriptor, revalidates the full guard, and crosses readiness while the parent retains the recovery lock; competing STOPPING returns 75 until VCM has crossed the launch boundary. Immediate exit still fails VCM only. |
| Strict gstApp escalation evidence | Impossible `attempted=0, failed=0, consecutive_failures=5` failed `expected rc=70 got=0`. | The gate validates exact action arithmetic plus RUNNING/terminal history/result provenance; impossible evidence returns 70 byte-for-byte and creates no request. Five real failed gstApp attempts remain retryable and the sixth request is `module_reload`. |
| Existing/malformed/result-first finish evidence | A malformed pre-existing result failed `expected rc=70 got=23`. | Finish preflights active/history/result/attribution before writes. Malformed or conflicting evidence returns 70 unchanged; exact result-first and history-first partials converge without rewriting exact bytes or duplicating counters. |
| Finish-to-ACTIVE convergence | The post-finish failpoint first failed `expected rc=70 got=23`; after adding the boundary, the unrepaired loop failed `expected rc=0 got=1`. | After durable terminal finish leaves no lease and owner RECOVERING, the same process or a restarted/next loop validates the exact liveness gstApp failure evidence and performs the existing legal RECOVERING-to-ACTIVE transition once, without rewriting result/history/state. Cross-request or malformed evidence cannot authorize repair. |
| Exact pre-TERM PID/start identity | The absent-daemon regression reported `absent exact daemon was signaled`. | Missing exact PID is idempotent success with no kill; malformed/reused PID is 69 with no kill/cleanup; a live exact PID receives one TERM after a same-lock start-time revalidation. |
| Exact daemon/action timeout | The original stop path treated a still-live exact daemon as quiesced and continued cleanup. | Timeout zero returns 75, retains the durable STOPPING owner, and performs no managed cleanup. Unresolved pending/active/job work likewise returns 75 unless the already-dead owner qualifies for exact abandoned-lease reconciliation. |
| Abandoned lease reconciliation | A durable daemon-dead STOPPING owner failed `expected rc=0 got=69`. | External stop adopts only the exact schema-valid STOPPING tuple, then uses the existing abandoned-lease protocol to terminalize accepted pending/active evidence before owner removal. The next owner starts with no orphan lease or RC70. |
| Resumable/concurrent STOPPING | Partial managed cleanup previously could not be resumed safely, and a second coordinator could enter an incompatible path. | One recovery lock covers coordination. A failed cleanup retains STOPPING and a later external stop completes idempotently; a concurrent loser returns documented BUSY 75 while the winner removes the owner exactly once and last. |

Additional fail-closed REDs covered the effect-adjacent degraded mutation:
owner rollover failed `expected rc=69 got=23`, and malformed existing service
state failed `expected rc=70 got=23`. The locked GREEN path validates the full
owner tuple before the state write and lifecycle transition, refuses malformed
state without overwriting it, and preserves the legacy exact action failure rc.

### Failure-boundary invariants

- Result/history/state/active/owner are preflighted as one protocol operation;
  result-first, history-first, and already-complete evidence are idempotent.
- The VCM parent lock spans child close/guard/exec readiness without leaking the
  lock into the executable.
- TERM is preceded by exact `/proc/<pid>/stat` start-time revalidation. A live
  timeout or unresolved work stops the sequence before managed cleanup.
- Once the exact daemon is absent, accepted leases are terminalized with the
  existing abandoned-owner reconciler. Owner removal is refused while a lease
  exists and remains the final durable stop event.
- A STOPPING tuple may be adopted even after its daemon dies, but no immutable
  field may change and non-STOPPING owners still require the exact live PID.

### Final GREEN gates

```text
rtk bash test/camera_health/cam_liveness_test.sh        exit 0, cam liveness: PASS
rtk bash test/camera_health/cam_stop_order_test.sh      exit 0, cam stop order: PASS
rtk bash test/camera_health/cam_operate_control_test.sh exit 0, cam operate control: PASS
rtk bash test/camera_health/recovery_protocol_test.sh   exit 0, recovery protocol: PASS
rtk bash test/cam_link/recovery_actions_test.sh         exit 0, recovery actions: PASS
rtk bash test/cam_link/recovery_actions_safety_test.sh  exit 0, recovery actions safety: PASS
rtk bash test/cam_link/recovery_launch_safety_test.sh   exit 0, recovery launch safety: PASS
rtk bash test/cam_link/escalation_test.sh               exit 0, 7 passed / 0 failed

rtk bash test/camera_health/run_all.sh                  exit 0
rtk bash test/cam_link/run_all.sh -v                    exit 0, all 14 scripts passed
rtk bash -n <required production/test shell files>      exit 0
rtk shellcheck --severity=error <all changed shell>     exit 0
rtk git diff --check                                    exit 0
```

The code-review graph was used before file exploration and updated
incrementally at the exact base. `detect_changes` saw five changed files and
reported risk 0.40; it found no affected flow or dependent file. It models
only a small subset of these top-level Bash functions (six changed entities and
many apparent test gaps), so the isolated full diff and the executable focused
and aggregate gates above are authoritative. The final diff was reviewed for
the ten findings, exact rc/provenance, byte preservation, legal lifecycle
transitions, lock inheritance, timeout stop conditions, lease reconciliation,
and owner-last removal. No residual in-scope concern remains.

## Fix round 2

Base/head before this fix is
`63b332f5c32a6d281c8a766af6dcd733efc39cd9`. Before any production edit, the
two executable regressions produced these exact RED results:

```text
rtk bash test/camera_health/cam_liveness_test.sh
exit 1
test/camera_health/cam_liveness_test.sh: line 29: cam_monitor_control_iteration: command not found
FAIL: expected rc=0 got=127: cam_monitor_control_iteration monitor_config_reload

rtk bash test/camera_health/recovery_protocol_test.sh
exit 1
ROUND2_RED: normal finish expected rc=70 got=0
ROUND2_RED: result_first finish expected rc=70 got=0
ROUND2_RED: history_first finish expected rc=70 got=0
FAIL: 3 finish arithmetic variants accepted impossible attempted count
```

The first regression executes the wished-for production monitor control
iteration rather than calling `cam_poll_pending_request` directly. It will
catch a pending-file gate around the only reconciliation call. The second
uses a real RUNNING public-action request whose last-action tuple remains
valid while only cumulative `attempted` changes from 1 to 2; all three finish
storage orderings currently publish/remove instead of failing before writes.

### Production fix and GREEN behavior

- `cam_monitor_control_iteration` is now the daemon's bounded control decision
  sequence on every monitor iteration. It calls poll/reconciliation even with
  no pending lease, treats only RC1 as benign no-work, returns every other
  nonzero control RC before liveness, and makes ACTIVE liveness eligible after
  an exact repair. Its apply-config callback is selected only from an existing
  successful `apply_config` request, so repair-only success cannot call
  `GetConfig` or reload configuration.
- The exact post-finish liveness regression drives a real gstApp request to
  the injected RC70 boundary, then runs that production sequence in both the
  same exported context and a freshly exported context. Both runs restore
  only `owner.lifecycle` to ACTIVE: state/history/result fingerprints remain
  exact, no pending/active lease appears, no action/config-reload is logged,
  and the real ACTIVE liveness path runs.
- `_cr_finish_locked` now preflights persistent counter state and strict public
  history/state arithmetic before its first result/history/active mutation.
  The invalid normal, result-first, and history-first variants all return 70
  byte-for-byte. Restoring `attempted=1`, `failed=1`, and
  `consecutive_failures=1` makes all three paths converge while preserving
  exact pre-existing result/history bytes and all unrelated fingerprints.
  Histories without a public action retain the prior counter-free path.

The first camera-health aggregate exposed a test-oracle timing assumption,
not a production failure: normal finish sampled `_cr_now` once in the fixture
and the implementation sampled it again at commit, so equality depended on
both calls occurring in the same wall-clock second. A forced public-API
boundary probe demonstrated the distinction while preserving the real
invariant:

```text
pre_sample=1788753212 actual_result=1788753215 actual_history=1788753215 delta=3
```

The final oracle remains strict: the committed timestamp must be a positive
integer no earlier than the fixture sample; terminal history and result must
have complete identity and the exact same committed timestamp. Result-first
and history-first additionally retain the precomputed timestamp and their
byte-for-byte fingerprints. The final focused and aggregate runs below use
this strengthened deterministic oracle.

### Final GREEN gates

```text
rtk bash test/camera_health/cam_liveness_test.sh        exit 0, cam liveness: PASS
rtk bash test/camera_health/recovery_protocol_test.sh   exit 0, recovery protocol: PASS
rtk bash test/camera_health/cam_operate_control_test.sh exit 0, cam operate control: PASS
rtk bash test/camera_health/cam_stop_order_test.sh      exit 0, cam stop order: PASS
rtk bash test/cam_link/recovery_actions_test.sh         exit 0, recovery actions: PASS
rtk bash test/cam_link/recovery_actions_safety_test.sh  exit 0, recovery actions safety: PASS
rtk bash test/cam_link/recovery_launch_safety_test.sh   exit 0, recovery launch safety: PASS
rtk bash test/cam_link/escalation_test.sh               exit 0, 7 passed / 0 failed

rtk bash test/camera_health/run_all.sh                  exit 0
rtk bash test/cam_link/run_all.sh -v                    exit 0, all 14 scripts passed
rtk bash -n <three production and two test shell files> exit 0
rtk shellcheck --severity=error <same five shell files> exit 0
rtk git diff --check                                    exit 0
```

### Files and self-review

The production changes are limited to
`dist/pim/opt/pim/bin/chk_cam_operate.sh`,
`dist/pim/opt/pim/lib/cam_operate_control.sh`, and
`dist/pim/opt/pim/lib/cam_recovery.sh`. The two executable regressions are in
`test/camera_health/cam_liveness_test.sh` and
`test/camera_health/recovery_protocol_test.sh`; this report is the sixth
changed file. No persistent path, schema, owner, queue, marker, hash,
generation, source rescan, or Task 6+ consumer migration was added.

The graph was used before file exploration and incrementally updated after
the final test edit. It reports 879 nodes and 11,302 edges across 105 files,
risk 0.40, no affected flow/dependent file within two hops, and three apparent
test gaps for the newly named shell helpers. It does not model the changed
top-level Bash functions/control loop as callable entities or discover their
executable shell coverage, so the complete diff and focused/aggregate gates
are authoritative. Final review checked unconditional loop reachability,
exact RC propagation, apply-only reload selection, real liveness eligibility,
same-process/re-export convergence, before-write arithmetic validation,
normal/result-first/history-first byte preservation, and the no-public-action
compatibility path. No residual in-scope concern remains.

## Fix round 3

Base/head before this fix is
`28aaa6f8a6cdd5fe0f9dcc197846ddde5358c6d7`. Before any production edit, the
two executable regressions produced these exact RED results:

```text
rtk bash test/camera_health/cam_liveness_test.sh
exit 1
ROUND3_RED: daemon_callsite_rc=127 lifecycle=RECOVERING
FAIL: actual daemon monitor callsite did not repair the no-pending partial

rtk bash test/camera_health/cam_operate_control_test.sh
exit 1
ROUND3_RED: executed_type=apply_config reload_calls=0
FAIL: actually executed apply request did not reload daemon configuration exactly once
```

The first RED executes the packaged `chk_cam_operate.sh` artifact in a wished-for
tightly gated single-iteration mode from the exact post-finish partial. At the
base it cannot select packaged libraries or reach a bounded loop callsite, so
the fresh process exits 127 and leaves the owner RECOVERING. The second enters
the monitor iteration with no pending lease, injects a real `apply_config`
immediately before the real poll/claim, and proves that the request executes
while the pre-poll empty snapshot suppresses its reload callback.

### Production fix and GREEN behavior

- `chk_cam_operate.sh` has an exact `PIM_CAMERA_TEST_MONITOR_ONCE=1` gate that
  selects the packaged libraries, skips daemon startup and trap installation,
  and exits after the real loop callsite's control/liveness decision. With the
  gate unset, the absolute production libraries, traps, startup, and continuous
  loop are unchanged. The fresh-process post-finish regression now restores the
  exact owner to ACTIVE, keeps state/history/result byte-identical, creates no
  lease or action/config effect, and reaches normal ACTIVE liveness.
- `cam_poll_pending_request` clears its per-call work type before any work. It
  reports `repair` only for a successful liveness repair; after a successful
  claim it reads, schema-validates, and owner-validates the active lease and
  exposes that claimed type before execution. `cam_monitor_control_iteration`
  therefore invokes its reload callback exactly once only for the real
  `apply_config` request that returned success, rather than for a pre-poll
  pending snapshot. A following no-work call clears both poll and monitor type.

The daemon regression also passed the required mutation check. Temporarily
wrapping the production `cam_monitor_control_iteration` callsite in a
`pending.json` existence guard produced the following deterministic failure;
the mutation was then removed and the same focused test passed:

```text
rtk bash test/camera_health/cam_liveness_test.sh
exit 1
ROUND3_RED: daemon_callsite_rc=0 lifecycle=RECOVERING
FAIL: actual daemon monitor callsite did not repair the no-pending partial

rtk bash test/camera_health/cam_liveness_test.sh
exit 0, cam liveness: PASS
```

The arrival-race GREEN executes a real request submitted from an entry state
with no pending lease immediately before the real poll. Its terminal result is
`apply_config`/`SUCCEEDED`/RC0, the callback count is exactly one, and the
callback reads the newly committed runtime label `arrival-new`. The immediately
following no-work iteration returns RC1, performs no second reload, and exposes
no stale work type. The repair-only case likewise performs no reload.

### Final GREEN gates

```text
rtk bash test/camera_health/cam_liveness_test.sh        exit 0, cam liveness: PASS
rtk bash test/camera_health/recovery_protocol_test.sh   exit 0, recovery protocol: PASS
rtk bash test/camera_health/cam_operate_control_test.sh exit 0, cam operate control: PASS
rtk bash test/camera_health/cam_stop_order_test.sh      exit 0, cam stop order: PASS
rtk bash test/cam_link/recovery_actions_test.sh         exit 0, recovery actions: PASS
rtk bash test/cam_link/recovery_actions_safety_test.sh  exit 0, recovery actions safety: PASS
rtk bash test/cam_link/recovery_launch_safety_test.sh   exit 0, recovery launch safety: PASS
rtk bash test/cam_link/escalation_test.sh               exit 0, 7 passed / 0 failed

rtk bash test/camera_health/run_all.sh                  exit 0
rtk bash test/cam_link/run_all.sh -v                    exit 0, all 14 scripts passed
rtk bash -n <three production and three test files>     exit 0
rtk shellcheck --severity=error <same six files>        exit 0
rtk git diff --check                                    exit 0
```

### Files and self-review

Production changes are limited to
`dist/pim/opt/pim/bin/chk_cam_operate.sh` and
`dist/pim/opt/pim/lib/cam_operate_control.sh`. Executable regressions are in
`test/camera_health/cam_liveness_test.sh` and
`test/camera_health/cam_operate_control_test.sh`; this report is the fifth
changed file. No persistent path, schema field, owner, queue, marker, hash,
generation, source rescan, or Task 6+ consumer migration was added.

The code-review graph was queried before file exploration and updated after
the final edits. It reports risk 0.60, no affected flow or additional impacted
file within two hops, and apparent gaps for the newly named shell helpers. It
does not index the top-level daemon loop/callsite or recognize these executable
shell regressions, so the actual packaged-script mutation test plus the focused
and aggregate gates are the authoritative coverage. Final review checked the
test gate's unset production path, unconditional callsite reachability, exact
non-benign RC propagation, claimed-active type validation, apply-only exact-once
reload, repair/no-work stale-type clearing, fresh owner export, immutable
terminal evidence, lease/effect absence, and ACTIVE liveness eligibility. No
residual in-scope concern remains.
