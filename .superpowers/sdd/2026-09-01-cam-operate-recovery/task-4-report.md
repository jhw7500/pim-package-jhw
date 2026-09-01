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
