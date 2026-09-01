# Task 4 report: transactional cam-operate control

## Scope and outcome

Implemented Task 4 from base `d0f7956226521841436f49765c5270ccb339644c` in the six approved implementation/test files. `cam-operate` now owns startup source staging, restart classification, apply-config transactions, one-request-per-iteration dispatch, durable service state, and serialized recovery requests. No Task 5 liveness/child ownership, systemd/package consumer work, or later-task scope was added.

The new control library exposes all ten required entry points:

- `cam_daemon_startup`
- `cam_stage_source_candidate`
- `cam_plan_startup_action`
- `cam_apply_config_transaction`
- `cam_poll_pending_request`
- `cam_execute_pending_request`
- `cam_reload_policy`
- `cam_mark_degraded`
- `cam_daemon_begin_stop`
- `cam_daemon_finish_stop`

## TDD evidence

The control test was created before the production library and exercised real owner/request protocol state while stubbing staging-side hardware/process effects.

### RED

1. Initial missing implementation:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: Task 4 control library is missing: .../cam_operate_control.sh`

2. Concrete restart transaction assertion after the first production slice:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: projection_changed did not hard reset`
   - Cause/fix: projection comparison used `jq -e` without input; changed to `jq -ne` so the actual and persisted projections are compared.

3. No-change apply return contract:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure point: `=== no-change apply behavior ===` terminated without PASS.
   - Cause/fix: `_coc_quiesce_steps` leaked the final absent-`grep` status; each optional branch now has an explicit conditional and the function returns `0` after no work.

4. Interrupted same-boot classification:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: interrupted_history did not hard reset`
   - Cause/fix: startup now reads service state after interrupted-request reconciliation marks it dirty.

5. Apply executor/quiescence ordering:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: nonzero (`69` at the valid union boundary).
   - Cause/fix: the immutable apply executor context is established before quiescence, with owner lifecycle `APPLYING_CONFIG`.

6. Dirty-before-hardware contract:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: automatic recovery did not use current runtime` (the action stub returned `93` because dirty was still false).
   - Cause/fix: module/hard-reset recovery sets durable dirty state before the public action. Dirty is cleared only after action success, final readiness verification, projection calculation, and durable service-state persistence.

7. Same-boot public-action attribution:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: same-boot public action was not attributed to a request history`
   - Cause/fix: same-boot startup uses the existing lifecycle/request protocol and `cam_execute_action_step`; no request-submit bypass or new public action type was added.

8. Pre-quiesced action trust boundary:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: nonzero (`94` at the valid union boundary).
   - Failure: `cam_consumers_prequiesced: command not found`
   - Cause/fix: the action library now skips its internal quiesce only when the flag is present *and* the immutable owner tuple, active request id/type=`apply_config`, and `APPLYING_CONFIG` lifecycle all validate. Otherwise the existing action quiesce path runs.

### GREEN

- Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
- Exit: `0`
- Result: `cam operate control: PASS`

The final control run covered new-boot startup, source failure, same-boot restart, hard-reset classification, apply validation and owner/lease continuity, valid apply union/order/persistence/no rollback, no-change repair behavior, manual-edit-preserving automatic recovery, and lifecycle intake guards.

## Mandatory-contract review

1. New boot: owner remains the single daemon owner; source is staged once, runtime published, initial modules/consumers started, readiness checked, actual projection persisted, dirty cleared, lifecycle becomes `ACTIVE`.
2. Startup source failure: returns `64`, publishes nothing, starts no consumer, records `CONFIG_INVALID` degraded state.
3. Same boot: source is always re-staged; runtime is never used as source/fallback; equal projection still requests a countered `module_reload`.
4. Restart hard reset: projection difference/absence/corruption, dirty state, and interrupted history all select `camera_hard_reset`.
5. Apply lease: only claimed `apply_config` from `ACTIVE`/`DEGRADED` is accepted; the daemon PID/invocation/token owner tuple is never replaced.
6. Invalid apply: completes `rc=64` before quiesce/publish/action and preserves runtime/processes.
7. Valid apply: semantic plan is calculated once, actions are unioned, consumers quiesced, candidate atomically published, steps executed once in precedence order, then verified and persisted before `ACTIVE`.
8. Post-publish failure: keeps the published runtime, records degraded reason/target and appropriate dirty state, and never rolls back.
9. Active no-change: validates/publishes and creates no public action-counter entry.
10. Degraded no-change: repairs only recorded `ord`/`vcm`/gstApp-process/camera-health target; dirty overrides with one hard reset.
11. Runtime edit semantics: automatic recovery uses the current runtime unchanged; startup/apply staging intentionally replaces manual edits.
12. Lifecycle determinism: startup/apply transitions use the existing owner/request protocol; one pending request is polled per monitor iteration; no liveness or child-owner mechanism was introduced.

Persistent state is value-oriented only (`schema`, boot id, last successful hardware projection, dirty, degraded reason/target, invocation id). No SHA, generation id, second runtime copy, queue, autonomous fallback, source glob, direct cam-operate service control, or new public action-counter type was introduced. ORD/VCM/policy steps are stored in request history as `countered:false`.

## Daemon integration review

- Startup transaction executes before monitor configuration load.
- `FILE_JSON` and `FILE_JSON_` both point at `$PIM_CAMERA_RUNTIME_JSON`.
- Source globbing, runtime mutation, direct camera module load, direct reset scripts, direct camera reboot paths, and direct gstApp startup were removed from `chk_cam_operate.sh`.
- Health evidence submits the existing public request types under the same owner; the next loop iteration claims and executes at most one pending request.
- A successful apply reloads in-memory monitor configuration; invalid runtime records `CONFIG_INVALID` and does not enter the hardware ladder.
- Existing storage, recording, disconnect, cooldown, and file-health calculations remain in the monitor.
- Anchored static scan found zero executable direct reboot/module/reset/service-control paths. A deliberately broad scan matched only legacy explanatory comments; those comments were not counted as executable paths.

## Verification evidence

Fresh final-head gates:

| Command | Exit/result |
| --- | --- |
| `rtk bash -n dist/pim/opt/pim/lib/cam_operate_control.sh dist/pim/opt/pim/bin/chk_cam_operate.sh dist/pim/opt/pim/lib/cam_recovery_actions.sh` | `0` |
| `rtk bash test/camera_health/cam_operate_control_test.sh` | `0`, `cam operate control: PASS` |
| `rtk bash test/cam_link/escalation_test.sh` | `0`, `7 passed / 0 failed` |
| `rtk bash test/camera_health/run_all.sh` | `0`, including control PASS |
| `rtk bash test/cam_link/run_all.sh -v` | `0`, `all passed (14)` |
| `rtk bash test/camera_health/recovery_protocol_test.sh` | `0`, `recovery protocol: PASS` |
| `rtk bash test/cam_link/recovery_actions_test.sh` | `0`, `recovery actions: PASS` |
| `rtk bash test/cam_link/recovery_actions_safety_test.sh` | `0`, `recovery actions safety: PASS` |
| `rtk bash test/cam_link/recovery_launch_safety_test.sh` | `0`, `recovery launch safety: PASS` |
| `rtk shellcheck -x -S error` on the five changed shell implementation/test files | `0` |
| `rtk git diff --cached --check` before adding this report | `0` |

The baseline also passed before implementation: camera-health exited `0`; cam-link passed all 14 suites.

## Graph and diff review

The project graph was incrementally updated with all six code/test paths and reported 6 changed files, 28 parsed functions, risk `0.50`, and no affected indexed flow. Its Bash parser did not index the new production control file (`file_summary`/`tests_for` explicitly returned `target not indexed`), so its zero-flow/test-gap output was treated as a tooling limitation rather than coverage evidence. Dynamic focused and aggregate suites above provide the coverage evidence.

Before this report, the staged scope contained exactly the six brief-approved code/test files (`834 insertions`, `90 deletions`) and `git diff --cached --check` was clean. The final staged scope adds only this Task 4 report.

## Remaining concerns

- Verification is host/stub based. Real target-board process timing, device readiness, and reboot behavior remain acceptance work for the later system/board task.
- Task 5 liveness, child ownership, ordered signal shutdown, and later systemd/package consumers are intentionally absent.
- The code-review graph currently has incomplete Bash production-file indexing; review relied on complete staged diff inspection plus focused/aggregate executable gates.

No Task 4 implementation blocker remains.

## Fix round 1

Base: `5fa7d79827493e389c96cf7b38313adc9a49434d`. This round addresses only the four Important review findings in `task-4-fix-round-1-brief.md`; it does not add Task 5 liveness, a queue, service control, or later package/systemd work.

### RED evidence

1. Live-owner acquisition was destructive:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: expected rc=75 got=0: cam_daemon_startup 4242`
   - The regression now checks byte preservation for owner, service state, runtime, pending lease, existing history/result/counter sentinels, and checks that staging, publishing, consumers, history, results, and counters for the accepted request are untouched.

2. Stale accepted leases were orphaned:

   - Command: `rtk bash test/camera_health/recovery_protocol_test.sh`
   - Exit: `1`
   - Failure: `jq: Could not open .../results/<old-id>.json` followed by `FAIL: stale pending waiter has no complete terminal result`
   - The final tests cover pending, an actual waiting `cam-recoveryctl apply-config --wait` client, active action history/counters, corrupt fail-closed input, and a retry after a durable-result failpoint.

3. STARTING exposed an ACTIVE intake window:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: external apply entered former ACTIVE-before-submit boundary rc=0`
   - The injection runs at the old lifecycle boundary and uses the normal public submit API, rather than a test-only lease shortcut.

4. Real module reload did not receive apply-level full quiescence:

   - Command: `rtk bash test/cam_link/recovery_actions_test.sh`
   - Exit: `1`
   - Failure: `FAIL: module apply did not invoke exactly one full quiesce`
   - The observed RED sequence began with module operations (`lsmod`, `rmmod`, `modprobe`) and contained no completed full-consumer quiesce before them.

5. Hard reset discarded the policy union:

   - Command: `rtk bash test/camera_health/cam_operate_control_test.sh`
   - Exit: `1`
   - Failure: `FAIL: hardware+ETC apply lost precedence union`
   - The RED action log was `quiesce:consumers`, `action:camera_hard_reset`, `verify:camera`, `verify:processes:1`, with no `policy_reload`.

### GREEN behavior and invariants

- Owner acquisition is one lock-held protocol. A schema-valid live boot/PID/start-time tuple returns `75` before any mutation. A malformed owner or unreconcilable lease fails closed. Only a stale tuple enters reconciliation, and the new immutable owner is written only after reconciliation completes.
- Stale lease commit order is persistent dirty state, terminal interrupted history (`FAILED`, `rc=70`), matching terminal result, durable lease removal, then the replacement STARTING owner. Pending history is created with `actions:[]`; active history replaces only `.request`, preserving its action array and the global action-counter bytes. The waiter consumes `CAM_RECOVERY_RESULT ... status=FAILED rc=70` and exits `70`.
- `owner_reconcile_after_result` proves idempotent recovery: the old owner and lease remain while terminal history/result exist; retry preserves both terminal file checksums, removes the lease, and only then publishes the new owner.
- Same-boot startup uses `cam_startup_request_reserve` under the recovery lock. It validates the live STARTING owner, checks the single empty lease, creates the normal public-action request/history and active lease, and changes lifecycle directly to RECOVERING. Public `cam_request_submit` rules are unchanged. External apply at the former ACTIVE gap returns `75`; the internal action retains the immutable owner tuple and completes normal history/counters. A failpoint after active reservation leaves STARTING/dirty state with an accepted lease; stale-owner retry terminalizes it and performs the dirty hard reset without opening intake.
- Apply `module_reload` now takes the same full-consumer pre-quiescence path as `camera_hard_reset`. The real action integration proves exactly one completed full quiesce before the first `rmmod`/`modprobe`, module work before consumer restart, and restart before final verify. Failed quiescence and a forged pre-quiesced environment produce no module effect; the action layer still revalidates the active `apply_config` lease and immutable owner context.
- Dirty override emits one `camera_hard_reset` and retains `policy_reload` when the semantic plan includes ETC. Policy is executed as an independent precedence stage after hardware/consumer work and before final verification. Hardware+ETC, dirty+ETC, and hardware-only cases pass exact count/order assertions. Post-publish policy failure retains the new runtime, records request `FAILED rc=1`, sets owner `DEGRADED`, persists `dirty=true`, `degraded_reason=hardware-policy-failure`, `degraded_target=policy`, and performs no final verify or rollback.

### Fresh final-head verification

| Command | Exit/result |
| --- | --- |
| `rtk bash -n dist/pim/opt/pim/lib/cam_recovery.sh dist/pim/opt/pim/lib/cam_operate_control.sh dist/pim/opt/pim/lib/cam_recovery_actions.sh dist/pim/opt/pim/bin/chk_cam_operate.sh` | `0` |
| `rtk bash test/camera_health/cam_operate_control_test.sh` | `0`, `cam operate control: PASS` |
| `rtk bash test/camera_health/recovery_protocol_test.sh` | `0`, `recovery protocol: PASS` |
| `rtk bash test/cam_link/recovery_actions_test.sh` | `0`, `recovery actions: PASS` |
| `rtk bash test/cam_link/recovery_actions_safety_test.sh` | `0`, `recovery actions safety: PASS` |
| `rtk bash test/cam_link/recovery_launch_safety_test.sh` | `0`, `recovery launch safety: PASS` |
| `rtk bash test/cam_link/escalation_test.sh` | `0`, `7 passed / 0 failed` |
| `rtk bash test/camera_health/run_all.sh` | `0`, including protocol/control PASS |
| `rtk bash test/cam_link/run_all.sh -v` | `0`, `all passed (14)` |
| `rtk shellcheck -S error` on all five changed production/test shell files | `0` |
| `rtk git diff --check` | `0` |

### Graph and diff review

The graph incremental update reported five changed paths, no parse errors, 50 updated nodes, and 925 updated edges. `detect_changes` reported nine changed indexed test helpers, risk `0.50`, and zero affected flows. Both changed production Bash files returned `target not indexed`, so the zero-flow/test-gap result is explicitly a graph parser limitation and was not treated as coverage evidence. Focused real-action tests and both complete aggregate suites provide the executable evidence.

The complete diff was reviewed against all four findings. An exact executable-command scan found zero direct `modprobe`, `rmmod`, `systemctl`, or `reboot` statements in the changed control/protocol production files, and an exact-word scan found zero SHA/generation state. A broader scan matched only the existing public `reboot_fallback` action name and source-root variable, not direct execution or source fallback. `git diff --check` and shellcheck error severity are clean.

### Remaining concerns

- Verification is host/stub based. Target-board timing, real device teardown/readiness, and reboot acceptance remain later board/system work.
- Multi-file durability is implemented as ordered idempotent records rather than a filesystem-wide atomic transaction; explicit failpoint retry covers the durable-result boundary, while corrupt or ambiguous records deliberately fail closed for operator recovery.
- The code-review graph still does not index the two production Bash files, so future structural review must continue to combine complete diff inspection with dynamic protocol/action suites until the parser limitation is fixed.

No Fix round 1 blocker remains.

## Fix round 2

Base: `aff9a3f4891684f698accbabb0d46b8cc7ef5a3a`. This round addresses only the two residual Important findings in `task-4-fix-round-2-brief.md`; it does not change public request types, add a queue, or enter Task 5/later service and package scope.

### RED evidence

1. Normal terminal active leases were misclassified as interrupted:

   - Command: `rtk bash test/camera_health/recovery_protocol_test.sh`
   - Exit: `1`
   - Failure: `FAIL: expected rc=0, got 70: cam_owner_create 4242`
   - The control request was produced through the real request/claim/action-counter/finish protocol and its waiter first consumed the exact success sentinel. The regression matrix then checks consistent result+history, result-only, history-only, identity/status/rc/finished-at conflicts, malformed terminal input, and preservation of terminal/action-counter/service-state bytes.

2. Public lifecycle code allowed `STARTING -> RECOVERING` without a reserved lease:

   - Command: `rtk bash test/camera_health/recovery_protocol_test.sh`
   - Exit: `1`
   - Failure: `FAIL: expected rc=64, got 0: cam_owner_set_lifecycle RECOVERING`
   - The regression checks that the owner bytes and lifecycle remain unchanged and that no pending, active, history, or result record is created.

### Terminal reconciliation matrix

| Recovery input | Required durable outcome | Final result |
| --- | --- | --- |
| Consistent terminal result + terminal history (`SUCCEEDED/0`) | Preserve result, history, counters/actions, and service-state bytes; remove only active lease | PASS |
| Consistent terminal result + terminal history (`FAILED/17`) | Preserve result, history, counters/actions, and service-state bytes; remove only active lease | PASS |
| Terminal result + nonterminal history | Copy only the exact terminal request fields into history; preserve result/actions/counters/service state | PASS |
| Terminal history + missing result | Generate the identity/status/rc/finished-at-equivalent result; preserve history/actions/counters/service state | PASS |
| Identity, status/rc, or finished-at conflict; malformed terminal time | Return `70` before mutation; preserve owner/lease/result/history/counter/service bytes | PASS |
| Genuine nonterminal stale request | Preserve the established round-1 interrupted path: dirty state and matching synthetic `FAILED/70` terminal records | PASS |

Terminal success accepts only `SUCCEEDED` with `rc=0`; terminal failure accepts only `FAILED` with an integral positive rc. Result/history identity, status, rc, and positive integral `finished_at` must agree. An active lease that is already terminal must also agree before removal. Normal terminal reconciliation never marks service state dirty and does not rewrite already-consistent terminal records, actions, or counters. Ordered result-only/history-only writes are idempotent across retry; the existing interrupted durable-result failpoint remains covered.

### Private startup transition

- `STARTING:RECOVERING` was removed from the public lifecycle table. `cam_owner_set_lifecycle RECOVERING` now returns `64` from STARTING without changing bytes.
- Startup first writes validated internal request history and active lease under the recovery lock. Only then a private lock-held helper revalidates the immutable STARTING owner, absence of pending work, exact active request bytes/type/status/embedded owner, and exact matching history before atomically publishing RECOVERING.
- The startup race hook observes RECOVERING only together with that accepted active lease. A normal external submit at the former gap returns BUSY and cannot replace the lease.
- The history-write and active-write failpoints remain recoverable without opening intake: the former leaves STARTING plus orphan internal history; the latter leaves STARTING plus the accepted active lease. Stale-owner retry terminalizes the interrupted request and performs the existing dirty hard reset exactly once.
- Public submit, claim, lifecycle, waiter sentinel, request result, BUSY, and action-counter contracts are unchanged.

### Fresh final-head verification

| Command | Exit/result |
| --- | --- |
| `rtk bash -n dist/pim/opt/pim/lib/cam_recovery.sh dist/pim/opt/pim/lib/cam_operate_control.sh dist/pim/opt/pim/lib/cam_recovery_actions.sh dist/pim/opt/pim/bin/chk_cam_operate.sh` | `0` |
| `rtk bash test/camera_health/recovery_protocol_test.sh` | `0`, `recovery protocol: PASS` |
| `rtk bash test/camera_health/cam_operate_control_test.sh` | `0`, `cam operate control: PASS` |
| `rtk bash test/cam_link/recovery_actions_test.sh` | `0`, `recovery actions: PASS` |
| `rtk bash test/cam_link/recovery_actions_safety_test.sh` | `0`, `recovery actions safety: PASS` |
| `rtk bash test/cam_link/recovery_launch_safety_test.sh` | `0`, `recovery launch safety: PASS` |
| `rtk bash test/cam_link/escalation_test.sh` | `0`, `7 passed / 0 failed` |
| `rtk bash test/camera_health/run_all.sh` | `0`, including protocol/control PASS |
| `rtk bash test/cam_link/run_all.sh -v` | `0`, `all passed (14)` |
| `rtk shellcheck -S error` on all three changed production/test shell files | `0` |
| `rtk git diff --check` | `0` |

### Graph and diff review

The graph incremental update reported three changed paths, two re-parsed files, 40 updated nodes, 922 updated edges, and no parse errors. `detect_changes` reported five indexed test helpers, risk `0.40`, and no affected flow. The changed production Bash file remains outside the graph's top-level function model, so zero affected flows/test gaps were treated as a parser limitation rather than coverage evidence. The complete production diff was manually reviewed, and the focused protocol/control suites plus both aggregate suites provide executable coverage.

The implementation contains no `STARTING:RECOVERING` public edge and no call to the public owner-lifecycle helper for that transition. Exact scans of changed production found no SHA/generation state or later service-control additions. The final staged review is limited to the brief-approved recovery protocol implementation, its protocol/control tests, and this report.

### Remaining concerns

- Multi-file recovery remains an ordered, idempotent durability protocol rather than a filesystem-wide atomic transaction. Both one-sided normal-terminal states and the established interrupted failpoint retry are explicitly exercised.
- Verification is host/stub based. Target-board timing and real device/process teardown remain later board/system acceptance work.
- The graph still does not model the changed production shell top-level, so executable test evidence and complete diff review remain necessary.

No Fix round 2 implementation blocker remains.

## Fix round 3

Base: `3a1e0e0e9de7e84960d50a34af9a2db1a3dfbafa`. This round fixes only normal-terminal action/history/global-counter attribution consistency and the timestamp writers required to produce that consistent evidence. It does not add Task 5 liveness, a queue, service control, or later package/systemd behavior.

### RED evidence

1. Action/counter/service mutations were accepted during normal-terminal takeover:

   - Command: `rtk bash test/camera_health/recovery_protocol_test.sh`
   - Exit: `1`
   - Failure: `FAIL: terminal action mutations accepted: history_running:0 counter_running:0 counter_wrong_rc:0 counter_wrong_request:0 counter_wrong_started:0 counter_wrong_finished:0 unknown_action:0 duplicate_public:0 action_wrong_request:0 action_invalid_status:0 action_invalid_rc:0 action_started_zero:0 action_finished_before:0 public_countered_false:0 missing_state:0 corrupt_state:0 malformed_service:0 success_interrupted:0 failed_interrupted:0`
   - The source fixture is a real `cam-recoveryctl` request completed through claim, transitions, public counter begin/finish, request finish, and waiter consumption. Each invalid case changes one attribution field (or removes/duplicates one record) before attempting stale-owner acquisition.

2. Normal counter writers used different timestamps for the same logical action transition:

   - Command: `rtk bash test/camera_health/recovery_protocol_test.sh`
   - Exit: `1`
   - Failure: `FAIL: split counter timestamps begin=2000000004/2000000005 finish=2000000006/2000000007 takeover=70`
   - An incrementing test clock proved that begin and finish each called the clock separately for history and global state, producing evidence the strict takeover validator correctly rejected.

3. The four partial-counter retry directions generated fresh timestamps instead of copying durable evidence:

   - Command: `rtk bash test/camera_health/recovery_protocol_test.sh`
   - Exit: `1`
   - Failure: `FAIL: counter retry timestamps diverged: begin-history-only:2000000013/2000000014 begin-history-only-takeover:70 begin-state-only:2000000023/2000000022 begin-state-only-takeover:70 finish-history-terminal:2000000032/2000000033 finish-history-terminal-takeover:70 finish-state-terminal:2000000042/2000000041 finish-state-terminal-takeover:70`
   - The history-first directions use the real begin/finish failpoints. The reciprocal directions retain one durable side, remove/restore the other side, and invoke the public counter API to exercise its existing idempotent convergence branches.

### GREEN mutation and reciprocal matrix

| Case | Expected result | Final result |
| --- | --- | --- |
| History action RUNNING with SUCCEEDED counter | RC70 before takeover mutation | PASS |
| Counter RUNNING, wrong rc/request/start/finish | RC70 before takeover mutation | PASS (5 cases) |
| Unknown action, duplicate public action, wrong action request | RC70 before takeover mutation | PASS (3 cases) |
| Invalid action status/rc/start/finish or contradictory public metadata | RC70 before takeover mutation | PASS (5 cases) |
| Missing/corrupt global recovery state with public action | RC70 before takeover mutation | PASS (2 cases) |
| Malformed service state | RC70 before takeover mutation | PASS |
| SUCCEEDED or ordinary FAILED/17 request marked interrupted | RC70 before takeover mutation | PASS (2 cases) |
| Real normal public action | Active-only removal; exact history/counter/service preservation | PASS |
| Real uncountered ord/vcm/policy actions | `countered:false`, terminal shapes; no global counter created | PASS |
| Real distinct module+gstapp public actions | Both exact counter attributions preserved | PASS |
| Synthetic owner-stale FAILED/70 with matching RUNNING public action/counter | Existing forensic evidence preserved across durable-result retry | PASS |
| Normal begin/finish and four partial retry directions under incrementing clock | Exact history/state timestamps and successful terminal takeover | PASS |

For every invalid case the test snapshots owner, active lease, history, result, recovery counter state (including absence), service state, runtime, and call log after the mutation. RC70 is accepted only when every fingerprint remains byte-identical.

### Production invariants

- Terminal takeover classifies interruption metadata before any persistent write. Interruption fields are absent for normal terminal requests; only exact `FAILED`, `rc=70`, `interrupted=true`, `interrupted_reason=owner_stale` enables the interrupted evidence shape.
- Public terminal actions have the exact generated six-field shape. The exact owner-stale interrupted form may instead retain the generated four-field RUNNING shape. Normal terminal requests cannot contain RUNNING actions.
- Uncountered `ord_restart`, `vcm_restart`, and `policy_reload` actions require their exact generated terminal shape with `countered:false`. Unknown actions, extra/contradictory metadata, duplicate names, request-id mismatches, invalid status/rc pairs, and invalid timestamps fail closed.
- Every public action requires the global recovery state file, strict `_cr_state_valid`, and exact matching `last_request_id`, `last_status`, `last_rc`, `last_started_at`, and `last_finished_at`. Validation never repairs or increments counters.
- Existing service state, when present, must parse as an object and is preserved byte-for-byte during normal-terminal takeover.
- The attribution preflight runs after in-memory terminal convergence is calculated but before dirty marking, history/result writes, lease removal, or replacement owner publication.
- Normal counter begin/finish uses one clock value for both durable records. Partial retries copy the existing history/state start or finish timestamp to the missing side, preserving attempted/success/failed counts and the established failpoint convergence behavior.

### Fresh final-head verification

| Command | Exit/result |
| --- | --- |
| `rtk bash -n dist/pim/opt/pim/lib/cam_recovery.sh dist/pim/opt/pim/lib/cam_operate_control.sh dist/pim/opt/pim/lib/cam_recovery_actions.sh dist/pim/opt/pim/bin/chk_cam_operate.sh` | `0` |
| `rtk bash test/camera_health/recovery_protocol_test.sh` | `0`, `recovery protocol: PASS` |
| `rtk bash test/camera_health/cam_operate_control_test.sh` | `0`, `cam operate control: PASS` |
| `rtk bash test/cam_link/recovery_actions_test.sh` | `0`, `recovery actions: PASS` |
| `rtk bash test/cam_link/recovery_actions_safety_test.sh` | `0`, `recovery actions safety: PASS` |
| `rtk bash test/cam_link/recovery_launch_safety_test.sh` | `0`, `recovery launch safety: PASS` |
| `rtk bash test/cam_link/escalation_test.sh` | `0`, `7 passed / 0 failed` |
| `rtk bash test/camera_health/run_all.sh` | `0`, including updated protocol/control PASS |
| `rtk bash test/cam_link/run_all.sh -v` | `0`, `all passed (14)` |
| `rtk shellcheck -S error` on the changed production and protocol-test shell files | `0` |
| `rtk git diff --check` | `0` |

### Graph and diff review

The graph incremental update reported two changed paths, one re-parsed file, 16 updated nodes, 725 updated edges, and no parse errors. `detect_changes` reported eight indexed protocol-test helpers, risk `0.40`, and zero affected flows. The changed production Bash top-level again returned `target not indexed`, so its zero-flow/test-gap output is a parser limitation rather than coverage evidence. The production diff and protocol-test diff were reviewed completely; the focused and aggregate executable gates above are the authoritative coverage evidence.

The final scope is limited to the recovery protocol implementation, its protocol regression test, and this Task 4 report. No public request/action type, lifecycle edge, queue, SHA/generation state, fallback, or service-control path was added.

### Remaining concerns

- Multi-file durability remains ordered and idempotent rather than filesystem-wide atomic. The four public-counter partial directions and terminal result/history partial directions are covered explicitly.
- Verification remains host/stub based; real target-board timing and device/process teardown remain later acceptance work.
- The code-review graph still cannot model the production shell top-level, requiring complete diff inspection plus executable protocol/action gates.

No Fix round 3 implementation blocker remains.
