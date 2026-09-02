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
