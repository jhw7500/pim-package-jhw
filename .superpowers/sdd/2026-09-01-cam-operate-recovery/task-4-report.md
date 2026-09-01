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
