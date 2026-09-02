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
