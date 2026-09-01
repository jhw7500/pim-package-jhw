# Cam-Operate Serialized Recovery Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Make one `cam-operate` invocation the sole owner of camera recovery, process liveness, and source-to-runtime config application while preserving manual runtime edits and dead-process auto-restart behavior.

**Architecture:** `cam-operate` creates one mutable merged JSON under `/run/pim-camera`, publishes an owner tuple, accepts file-backed non-queued control requests, and runs every camera side effect through one executor. Recovery requests never rescan `/root/shared_v`; only daemon startup/restart and `apply-config` stage a new candidate from source. Persistent counters and hardware projection values live under `/var/lib/pim-camera`, with no config SHA or immutable generation layer.

**Tech Stack:** Bash 4, Python 3 standard library, `jq`, `flock`, systemd 245, json-c C++, GStreamer/GLib C++, existing shell/Python host tests, Yocto i.MX8 cross-build tools.

## Repository and execution boundaries

| Role | Working directory | Commit ownership |
| --- | --- | --- |
| Package, daemon, ORD, VCM | `/home/jhw/ai/opencode/projects/pim-package-jhw` | This plan's primary commits |
| gstApp source | `/home/jhw/ai/opencode/projects/gstApp` | One upstream source commit before binary deployment |
| Target acceptance | Ubuntu 20.04 camera board | Evidence is recorded in the primary repository only after the checks pass |

Run every command below in the stated working directory. Every shell command is prefixed with `rtk` as required by the repository instructions. Keep unrelated dirty-tree changes untouched. Before each commit, inspect `rtk git status --short` and stage only the files named by that task.

## Frozen interface contract

| Interface | Exact contract |
| --- | --- |
| Runtime JSON | `/run/pim-camera/config/pim_runtime.json` |
| Compatibility aliases | `edgeconf_pim.json` and `ord_vcm_conf.json`, both relative symlinks to `pim_runtime.json` |
| Source root | `/root/shared_v`, overridden only by test/CLI injection into the daemon-owned builder |
| Source selection | Newest regular `edgeconf_*.json` by `mtime_ns` descending, then filesystem-byte path ascending; invalid newest file fails with no fallback |
| Merge | Entire `ord_vcm_conf.json`, then replace top-level `VHL_CAM` with the selected edgeconf value; require object-valued `VHL_CAM`, `ORD`, and `VCM` |
| Runtime rebuild boundary | New daemon invocation and `cam-recoveryctl apply-config` only |
| Source write-back | Never; runtime edits and apply results do not modify files under the source root |
| Recovery actions | `gstapp_restart`, `module_reload`, `camera_hard_reset`, `reboot_fallback` |
| Lifecycle | `STARTING`, `ACTIVE`, `APPLYING_CONFIG`, `RECOVERING`, `STOPPING`, `DEGRADED` |
| Request result codes | `0`, `64`, `69`, `70`, `75`, `124` as defined in the approved design |
| Busy policy | One pending or active lease; no queue; second request exits `75` |
| Persistent config identity | Normalized JSON value projection only; never SHA, digest, manifest, or generation ID |
| Binary integrity metadata | Existing `.github/binary-manifest.json` hashes remain build/deploy evidence only and never participate in runtime selection, comparison, or recovery |

Use this exact state layout:

```text
/run/pim-camera/
  owner.json
  recovery.lock
  recovery/
    pending.json
    active.json
    results/$request_id.json
    candidate-$request_id.json
  config/
    pim_runtime.json
    edgeconf_pim.json -> pim_runtime.json
    ord_vcm_conf.json -> pim_runtime.json

/var/lib/pim-camera/
  service-state.json
  recovery/
    state.json
    history/$request_id.json
```

The intended event flow is:

```text
/root/shared_v -- startup/apply only --> staged candidate --> pim_runtime.json
                                                            |
wrapper/guardian --> cam-recoveryctl --> pending lease --> cam-operate executor
                                                            |
                                            gstApp + ORD + VCM + camera hardware
```

Network-only scripts such as `chk_wifi.sh` and `chk_eth1.sh` remain source-config consumers because the camera runtime intentionally contains only edgeconf `VHL_CAM`, not `NETWORK`. Config writers and guards also retain source access. The runtime-consumer audit introduced below uses an explicit allowlist so it does not force unrelated configuration domains into the camera bundle.

### Task 1: Build and test the single mutable runtime config engine

**Files:**

- Create: `dist/pim/opt/pim/bin/camera_runtime_config.py`
- Create: `test/camera_health/runtime_config_test.py`
- Modify: `dist/pim/opt/pim/bin/camera_config_bootstrap.sh`
- Modify: `test/camera_health/config_bootstrap_test.sh`
- Modify: `test/camera_health/package_executable_test.py`
- Modify: `test/camera_health/run_all.sh`

**Step 1: Write the failing runtime builder tests**

Use `unittest` and import the package copy by absolute repository-relative path, matching the existing `config_expectation_test.py` pattern. Cover these exact cases in `runtime_config_test.py`:

- newest regular file selection by nanosecond mtime;
- same-mtime lexical tie-break (`edgeconf_a.json` wins over `edgeconf_b.json`);
- directories and symlinks named `edgeconf_*.json` are ignored;
- malformed newest JSON fails without selecting the older valid JSON;
- missing/non-object `VHL_CAM`, `ORD`, or `VCM` fails;
- the whole ORD document and additional keys survive, while edgeconf `VHL_CAM` wins;
- stage result records only source path and `mtime_ns`, not a digest;
- publish uses mode `0640`, leaves no temp file, and creates both relative aliases;
- replacing a manually edited runtime with a later source stage restores source values;
- staging, publishing, and apply planning never modify either selected source file;
- semantic equality ignores object key order and whitespace;
- hardware projection changes only for the centralized hardware fields;
- change planning returns the required union once for VHL, ORD, VCM, ETC, and script-only changes.

The test fixture helper should create complete documents, not permissive fragments:

```python
def edge(name: str, width: int = 1920) -> dict[str, object]:
    return {
        "VHL_CAM": {
            "vhl_name": name,
            "cam_width": width,
            "cam_height": 1080,
            "fps": 30,
            "i2c2": {"ch0": {"enable": True}, "ch1": {"enable": True}},
            "i2c1": {"ch2": {"enable": True}, "ch3": {"enable": True}},
        }
    }


def ord_document() -> dict[str, object]:
    return {
        "ORD": {"port_num": 10007},
        "VCM": {"port_num": 10009, "srt_enable": True},
        "ETC": {"camera_startup_grace_sec": 40},
        "SITE_NOTE": {"keep": True},
        "VHL_CAM": {"vhl_name": "must-be-overridden"},
    }
```

**Step 2: Run the focused tests and verify the red state**

Working directory: `/home/jhw/ai/opencode/projects/pim-package-jhw`

```bash
rtk python3 test/camera_health/runtime_config_test.py
```

Expected: import failure because `camera_runtime_config.py` does not exist.

**Step 3: Implement the config engine with explicit subcommands**

Expose pure Python functions and a small CLI:

```text
RUNTIME_NAME = pim_runtime.json
ALIAS_NAMES = edgeconf_pim.json, ord_vcm_conf.json
select_latest_edgeconf(source_root: Path) -> SourceRecord
merge_source_documents(source_root: Path) -> Candidate
validate_runtime(document: object) -> dict[str, object]
hardware_projection(document: Mapping[str, object]) -> dict[str, object]
classify_change(current: Mapping[str, object], candidate: Mapping[str, object]) -> ChangePlan
atomic_publish(candidate_path: Path, runtime_dir: Path) -> Path
```

The CLI contract is exact:

```text
camera_runtime_config.py stage --source-root ROOT --candidate FILE --result FILE
camera_runtime_config.py validate --file FILE
camera_runtime_config.py plan --current FILE --candidate FILE --output FILE
camera_runtime_config.py projection --file FILE --output FILE
camera_runtime_config.py publish --candidate FILE --runtime-dir DIR
```

`stage` performs selection, merge, and full validation before writing its candidate. `publish` reparses the candidate, writes a same-directory temporary, fsyncs the file, renames it, fsyncs the directory, and repairs the two relative symlinks. It must reject a runtime directory or final path that is a symlink supplied from outside the daemon-owned tree.

Use frozen dataclasses with these fields so the test and CLI layers share one vocabulary: `SourceRecord(path: Path, mtime_ns: int)`, `Candidate(document: dict[str, object], source: SourceRecord, ord_path: Path)`, and `ChangePlan(semantic_change: bool, hardware_change: bool, changed_sections: Sequence[str], steps: Sequence[str])`. Use `lstat` to admit only real regular files, excluding symlinks. Build the sort key with `(-stat.st_mtime_ns, os.fsencode(path))`; do not round mtimes to seconds or use locale collation.

Centralize the hardware projection as actual values for:

- `cam_width`, `cam_height`, and `fps`;
- `i2c2.ch0.enable`, `i2c2.ch1.enable`, `i2c1.ch2.enable`, and `i2c1.ch3.enable`;
- `i2c1.crop_enable`, `i2c2.crop_enable`, `i2c1.dz`, and `i2c2.dz`;
- full `v4l_map` and `device_map` objects;
- optional `camera_mode`, `stream_mode`, and `topology` values.

The planner emits JSON with `semantic_change`, `hardware_change`, `changed_sections`, and a de-duplicated `steps` array. Its precedence is `camera_hard_reset` over `gstapp_restart`; a hard reset already restarts all three consumers. Non-hardware `VHL_CAM` produces `gstapp_restart`, `ord_restart`, and `vcm_restart`; `ORD` and `VCM` produce their respective restart; `ETC` produces `policy_reload`; additional script-only keys produce no immediate step.

Give the CLI a Python 3 shebang and executable git mode:

```bash
rtk chmod +x dist/pim/opt/pim/bin/camera_runtime_config.py
```

**Step 4: Reduce bootstrap to a prerequisite guard**

Replace snapshot publication, READY, manifest, hashes, and `/tmp/config` handling in `camera_config_bootstrap.sh` with checks for:

- readable source root directory;
- readable regular `ord_vcm_conf.json` under that root;
- available `python3`, `jq`, `flock`, `logger`, and `/proc/sys/kernel/random/boot_id`;
- no creation or mutation beneath `/run/pim-camera/config`.

Keep `PIM_CAMERA_CONFIG_SOURCE_DIR` and `PIM_CAMERA_CONFIG_BOOT_ID_FILE` injection for offline tests. Rewrite `config_bootstrap_test.sh` to assert guard-only behavior, including that an `edgeconf_newer.json` file is neither selected nor copied by bootstrap.

**Step 5: Run the focused and camera-health tests**

```bash
rtk git add --chmod=+x dist/pim/opt/pim/bin/camera_runtime_config.py
rtk python3 test/camera_health/runtime_config_test.py
rtk bash test/camera_health/config_bootstrap_test.sh
rtk python3 test/camera_health/package_executable_test.py
rtk bash test/camera_health/run_all.sh
```

Expected: all pass; no `/tmp/config`, READY, manifest, or SHA assertion remains in the rewritten bootstrap test.

**Step 6: Commit Task 1**

```bash
rtk git add dist/pim/opt/pim/bin/camera_runtime_config.py dist/pim/opt/pim/bin/camera_config_bootstrap.sh test/camera_health/runtime_config_test.py test/camera_health/config_bootstrap_test.sh test/camera_health/package_executable_test.py test/camera_health/run_all.sh
rtk git commit -m "feat(cam): add mutable runtime config engine"
```

### Task 2: Add owner identity, request leases, result history, and the control CLI

**Files:**

- Create: `dist/pim/opt/pim/lib/cam_recovery.sh`
- Create: `dist/pim/opt/pim/bin/cam-recoveryctl`
- Create: `test/camera_health/recovery_protocol_test.sh`
- Modify: `dist/pim/opt/pim/lib/cam_state.sh`
- Modify: `test/test_cam_state.sh`
- Modify: `test/camera_health/package_executable_test.py`
- Modify: `test/camera_health/run_all.sh`

**Step 1: Write a failing protocol test with isolated roots**

The test exports these overrides before sourcing the library or invoking the CLI:

```bash
export PIM_CAMERA_RUN_DIR="$WORK/run/pim-camera"
export PIM_CAMERA_STATE_DIR="$WORK/var/lib/pim-camera"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot_id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
```

Create a fake `$PIM_CAMERA_PROC_ROOT/$daemon_pid/stat` whose field 22 is stable. Test:

- owner record contains boot ID, invocation UUID, PID, proc start time, token, and `STARTING`;
- PID reuse with a different start time and a token mismatch both fail closed before side effects;
- legal lifecycle transitions succeed and illegal transitions fail;
- first request creates pending state; second request exits `75` with no queue file;
- claim moves pending to active atomically and preserves request ID/source/reason;
- `--wait` success/failure prints the exact sentinel and propagates result status;
- wait timeout exits `124` without cancelling the active request;
- unavailable daemon exits `69`; bad type/arguments exit `64`;
- an atomic state/storage failure exits `70`, and empty `--source` or `--reason` is rejected;
- every accepted request ID is a UUID, and failed wait output uses the same sentinel key order with `status=FAILED` and the stored non-zero rc;
- action attempt/success/failure/consecutive counters persist across a new library process;
- an invalid-owner nonterminal history record reconciles exactly once to `FAILED/interrupted` and sets service state dirty;
- history contains source path and mtime fields when supplied, but no SHA/generation fields.

**Step 2: Run the protocol test and verify the red state**

```bash
rtk bash test/camera_health/recovery_protocol_test.sh
```

Expected: failure because the library and CLI are missing.

**Step 3: Implement atomic owner and request primitives**

`cam_recovery.sh` owns all path calculation and JSON state mutation. Its externally used functions are:

```text
cam_owner_create
cam_owner_assert
cam_owner_set_lifecycle
cam_request_submit
cam_request_claim
cam_request_transition
cam_action_counter_begin
cam_action_counter_finish
cam_request_finish
cam_reconcile_interrupted
cam_recovery_status_json
```

Use `/proc/$daemon_pid/stat` field 22 and compare the entire owner tuple immediately before each external side effect. Use two UUID reads for invocation ID and owner token. Use a non-blocking `flock` only around short pending/active state transitions; the presence of pending or active JSON is the long-lived exclusive lease.

Enforce this lifecycle transition table in one function:

| From | Allowed next state |
| --- | --- |
| `STARTING` | `ACTIVE`, `DEGRADED`, `STOPPING` |
| `ACTIVE` | `APPLYING_CONFIG`, `RECOVERING`, `DEGRADED`, `STOPPING` |
| `APPLYING_CONFIG` | `ACTIVE`, `DEGRADED`, `STOPPING` |
| `RECOVERING` | `ACTIVE`, `DEGRADED`, `STOPPING` |
| `DEGRADED` | `APPLYING_CONFIG`, `RECOVERING`, `STOPPING` |
| `STOPPING` | no outgoing transition |

All JSON writes use a temporary on the same filesystem, `fsync`, rename, and directory `fsync`. Store runtime owner/lease/result state beneath `$PIM_CAMERA_RUN_DIR` and persistent service/counter/history state beneath `$PIM_CAMERA_STATE_DIR`. `cam_action_counter_begin` increments `attempted` only on the `running` transition; terminal finish updates succeeded/failed and consecutive failure counts.

Initialize `recovery/state.json` with all four public actions under an `actions` object. Each action record contains `attempted`, `succeeded`, `failed`, `consecutive_failures`, `last_request_id`, `last_started_at`, `last_finished_at`, `last_status`, and `last_rc`. History files contain the top-level request plus an ordered `actions` array so fallback actions receive their own counters without becoming nested requests.

Remove only the obsolete recovery and lock functions/constants from `cam_state.sh`; preserve camera health, streak, channel, and recording state functions. Rewrite `test/test_cam_state.sh` to derive `ROOT` from its own path, use a private `STATE_DIR`, and test only that retained health-state contract.

**Step 4: Implement `cam-recoveryctl`**

Support exactly:

```text
cam-recoveryctl request ACTION --source NAME --reason TEXT [--wait SEC]
cam-recoveryctl apply-config --source NAME --reason TEXT [--wait SEC]
cam-recoveryctl status [--request-id UUID] [--json]
```

The CLI sources `cam_recovery.sh`, validates the daemon owner/lifecycle, writes one pending request, and optionally polls the result file. `apply-config` uses request type `apply_config` internally but never increments an action counter merely for accepting the control request. Terminal output is one line with this key order:

```text
CAM_RECOVERY_RESULT id=UUID type=ACTION status=SUCCEEDED rc=0
```

Install a Bash shebang and executable git mode:

```bash
rtk chmod +x dist/pim/opt/pim/bin/cam-recoveryctl
```

**Step 5: Run all state/protocol tests**

```bash
rtk git add --chmod=+x dist/pim/opt/pim/bin/cam-recoveryctl
rtk bash test/camera_health/recovery_protocol_test.sh
rtk bash test/test_cam_state.sh
rtk bash test/camera_health/run_all.sh
```

Expected: all pass, including two-process BUSY behavior and one-time interrupted reconciliation.

**Step 6: Commit Task 2**

```bash
rtk git add dist/pim/opt/pim/lib/cam_recovery.sh dist/pim/opt/pim/bin/cam-recoveryctl dist/pim/opt/pim/lib/cam_state.sh test/camera_health/recovery_protocol_test.sh test/test_cam_state.sh test/camera_health/package_executable_test.py test/camera_health/run_all.sh
rtk git commit -m "feat(cam): add serialized recovery request protocol"
```

### Task 3: Extract the single action executor and turn legacy commands into wrappers

**Files:**

- Create: `dist/pim/opt/pim/lib/cam_recovery_actions.sh`
- Create: `test/cam_link/recovery_actions_test.sh`
- Create: `test/cam_link/legacy_wrapper_test.sh`
- Modify: `dist/pim/opt/pim/bin/start_cam.sh`
- Modify: `dist/pim/opt/pim/bin/kill_test.sh`
- Modify: `dist/pim/opt/pim/bin/init_cam.sh`
- Modify: `dist/pim/opt/pim/bin/cam_hard_reset.sh`
- Modify: `dist/pim/opt/pim/bin/restart_app.sh`
- Modify: `test/cam_link/initcam_modprobe_test.sh`
- Modify: `test/test_init_cam_cleanup.sh`
- Modify: `test/cam_link/run_all.sh`

**Step 1: Write failing executor and wrapper tests**

Use PATH stubs and a call-log file to assert:

- every action validates owner and active request before the first `kill`, `systemctl`, `rmmod`, `modprobe`, sysfs write, or `reboot`;
- invalid current runtime returns `64` and never calls module/hardware/reboot stubs;
- `gstapp_restart` stops only camera-app/BG children, cleans the current recording session, starts through the internal launcher, and verifies readiness;
- `module_reload` stops consumers, unloads `imx8-media-dev` before `max9296`, loads `max9296` before `imx8-media-dev`, and restarts required consumers;
- a failed `max9296` load prevents the dependent media module load;
- hard reset preserves the existing CSI/ISI child-first unbind and parent-first bind order;
- hard reset contains no `systemctl stop`, `start`, or `restart` of `cam-operate.service`;
- module failure escalates once to hard reset; hard-reset failure requests reboot exactly once inside the same top-level request;
- each compatibility wrapper emits a deprecation warning, waits synchronously, and propagates the CLI exit code;
- wrapper mapping is `kill_test.sh -> gstapp_restart`, `init_cam.sh -> module_reload`, and `cam_hard_reset.sh -> camera_hard_reset`;
- `cam_hard_reset.sh -s -S` accepts the old flags but still only forwards the request;
- `restart_app.sh` runs no loop and forwards one `gstapp_restart` request;
- `start_cam.sh` never starts `restart_app.sh`, reads only the fixed runtime, and refuses internal launch without a valid owner context.

**Step 2: Run the focused tests and verify failure**

```bash
rtk bash test/cam_link/recovery_actions_test.sh
rtk bash test/cam_link/legacy_wrapper_test.sh
```

Expected: failures because actions still live in three public scripts and the wrappers still manipulate processes directly.

**Step 3: Move action bodies into `cam_recovery_actions.sh`**

Expose these executor-only functions:

```text
cam_quiesce_gstapp
cam_quiesce_consumers
cam_initial_module_load
cam_start_gstapp
cam_restart_ord
cam_restart_vcm
cam_verify_camera_ready
cam_verify_process_ready
cam_action_gstapp_restart
cam_action_module_reload
cam_action_camera_hard_reset
cam_action_reboot_fallback
cam_execute_action_step
cam_execute_recovery_request
```

Move the orphan recording cleanup and `/dev/shm` pressure cleanup from `init_cam.sh` into the action library. Move the hardware sequence from `cam_hard_reset.sh` without its service flags. Every function receives the runtime path and owner/request identity through explicit arguments or read-only executor context; no function searches the source root.

`cam_initial_module_load` is startup-only: it loads `max9296` then `imx8-media-dev`, checks the resulting nodes, and does not unload modules or increment a recovery-action counter. Same-boot restart never uses this shortcut; it selects `module_reload` or `camera_hard_reset` from persistent projection/dirty state.

`cam_execute_action_step` validates the owner/lease and updates only the counter for the action it actually runs. `cam_execute_recovery_request` owns lifecycle `RECOVERING`, request state transitions, final result/history, health verification, and the module-to-hard-to-reboot fallback chain. This separation lets one `apply-config` transaction call several de-duplicated action steps without prematurely completing its top-level request. A direct `gstapp_restart` failure becomes terminal `DEGRADED`; repeated liveness failures are escalated later by the daemon policy rather than recursively creating another request.

**Step 4: Replace public scripts with forwarding boundaries**

Each of `kill_test.sh`, `init_cam.sh`, and `cam_hard_reset.sh` becomes a short `exec /opt/pim/bin/cam-recoveryctl request` wrapper with a finite wait. Preserve `-q`, `-s`, and `-S` parsing only to avoid breaking callers; none changes the action.

Use exact wrapper waits: `120` seconds for `kill_test.sh`, `restart_app.sh`, and external `start_cam.sh`; `300` seconds for `init_cam.sh` and `cam_hard_reset.sh`. A timeout returns `124` without cancelling the daemon's request.

Make `restart_app.sh` a one-release forwarding shim. Make `start_cam.sh` behave as follows:

- outside executor context, forward a synchronous `gstapp_restart` so `/usr/local/bin/startcam` remains useful;
- inside executor context, assert the full owner tuple, validate `/run/pim-camera/config/pim_runtime.json`, parse app/capture/tmp settings, start the selected app and BG checker, and return;
- never launch `restart_app.sh` and never touch source JSON.

Update the old modprobe and cleanup tests to source the new action library instead of extracting implementation from wrappers.

**Step 5: Run camera-link and legacy tests**

```bash
rtk bash test/cam_link/recovery_actions_test.sh
rtk bash test/cam_link/legacy_wrapper_test.sh
rtk bash test/cam_link/initcam_modprobe_test.sh
rtk bash test/test_init_cam_cleanup.sh
rtk bash test/cam_link/run_all.sh -v
```

Expected: all pass; static assertions find no source glob or cam-operate service control in the executor/wrappers.

**Step 6: Commit Task 3**

```bash
rtk git add dist/pim/opt/pim/lib/cam_recovery_actions.sh dist/pim/opt/pim/bin/start_cam.sh dist/pim/opt/pim/bin/kill_test.sh dist/pim/opt/pim/bin/init_cam.sh dist/pim/opt/pim/bin/cam_hard_reset.sh dist/pim/opt/pim/bin/restart_app.sh test/cam_link/recovery_actions_test.sh test/cam_link/legacy_wrapper_test.sh test/cam_link/initcam_modprobe_test.sh test/test_init_cam_cleanup.sh test/cam_link/run_all.sh
rtk git commit -m "refactor(cam): route reset commands through executor"
```

### Task 4: Make daemon startup, restart, and apply-config transactional

**Files:**

- Create: `dist/pim/opt/pim/lib/cam_operate_control.sh`
- Create: `test/camera_health/cam_operate_control_test.sh`
- Modify: `dist/pim/opt/pim/bin/chk_cam_operate.sh`
- Modify: `dist/pim/opt/pim/lib/cam_recovery_actions.sh`
- Modify: `test/camera_health/run_all.sh`
- Modify: `test/cam_link/escalation_test.sh`

**Step 1: Write failing control-transaction tests**

Source `cam_operate_control.sh` with stubs for config staging/publish, executor actions, readiness, and process control. Assert:

- startup creates the owner in `STARTING`, stages source once, publishes runtime, performs initial module init on a new boot, starts consumers, verifies, stores the actual hardware projection, and enters `ACTIVE`;
- source failure on startup publishes nothing, starts no consumer, and returns non-zero;
- same-boot restart stages source again and performs at least `module_reload` even when values match;
- same-boot restart performs `camera_hard_reset` when projection differs, is absent/corrupt, or persistent state is dirty/interrupted;
- startup never treats the existing runtime as input or fallback;
- `apply-config` is accepted only in `ACTIVE` or `DEGRADED` and shares the one request lease;
- invalid apply candidate preserves the current runtime and processes and completes with `rc=64`;
- valid apply computes the union once, quiesces affected consumers, publishes the candidate, executes required steps, verifies readiness, and then returns `ACTIVE`;
- action failure after publish keeps the new runtime and enters `DEGRADED` without rollback;
- active no-change apply publishes/validates without incrementing action counters;
- degraded no-change apply repairs the recorded degraded target; dirty no-change apply uses hard reset;
- direct manual runtime edits survive automatic recovery but are overwritten by startup or apply staging from source;
- action execution never changes the daemon PID or invocation owner.

**Step 2: Run the control test and verify failure**

```bash
rtk bash test/camera_health/cam_operate_control_test.sh
```

Expected: failure because daemon control transactions do not exist.

**Step 3: Implement daemon control functions**

Expose:

```text
cam_daemon_startup
cam_stage_source_candidate
cam_plan_startup_action
cam_apply_config_transaction
cam_poll_pending_request
cam_execute_pending_request
cam_reload_policy
cam_mark_degraded
cam_daemon_begin_stop
cam_daemon_finish_stop
```

Persistent `service-state.json` uses this value-oriented shape:

```json
{
  "schema": 1,
  "last_boot_id": "boot-a",
  "last_successful_hardware_projection": {},
  "dirty": false,
  "degraded_reason": null,
  "degraded_target": null,
  "last_invocation_id": "invocation-a"
}
```

Do not add hashes or generation IDs. Set `dirty=true` before an action that can leave hardware partially changed and clear it only after verification and state persistence complete.

For apply plans, execute the union with this precedence:

1. `camera_hard_reset` once, which includes all consumer restarts;
2. otherwise `gstapp_restart` once, `ord_restart` once, and `vcm_restart` once as selected;
3. `policy_reload` once;
4. final ready/health verification.

The apply transaction calls `cam_execute_action_step` for countered recovery actions and finishes its own top-level request only after all selected steps and final verification complete. ORD/VCM/policy steps are recorded in history but do not invent new public action-counter types.

For a no-change apply in `DEGRADED`, restart only `degraded_target` when it is `ord` or `vcm`, use `gstapp_restart` for a gstApp/process degradation, and use `module_reload` for camera-health degradation. Dirty state always overrides this with `camera_hard_reset`.

**Step 4: Integrate the control library into `chk_cam_operate.sh`**

At daemon entry:

- create/reconcile owner and persistent state;
- run `cam_daemon_startup` before loading any monitoring config;
- set both `FILE_JSON` and `FILE_JSON_` to the single runtime path;
- remove the source glob, `force_edgeconf_app_to_gstapp`, direct startup `modprobe`, and direct reset/reboot branches;
- poll one pending request near the top of each monitor iteration;
- translate existing health evidence into an internal request under the current owner, never a child request loop;
- reload daemon-owned `ETC` values only after a successful apply transaction;
- retain storage, recording, disconnect, cooldown, and file-health evidence calculations.

Replace the old retry branches with explicit action selection. Valid-config gstApp/file-health failures first request `gstapp_restart`; repeated failures use `module_reload`, then the executor's hard-reset/reboot fallback. Disconnect evidence continues to suppress reboot where the existing policy requires it. Config validation failure records `CONFIG_INVALID` and never enters the hardware ladder.

**Step 5: Run control and existing policy tests**

```bash
rtk bash test/camera_health/cam_operate_control_test.sh
rtk bash test/cam_link/escalation_test.sh
rtk bash test/camera_health/run_all.sh
rtk bash test/cam_link/run_all.sh -v
```

Expected: all pass; source-search stubs are called only by startup/apply tests.

**Step 6: Commit Task 4**

```bash
rtk git add dist/pim/opt/pim/lib/cam_operate_control.sh dist/pim/opt/pim/lib/cam_recovery_actions.sh dist/pim/opt/pim/bin/chk_cam_operate.sh test/camera_health/cam_operate_control_test.sh test/camera_health/run_all.sh test/cam_link/escalation_test.sh
rtk git commit -m "feat(cam): make cam-operate own config application"
```

### Task 5: Move dead-process restart and stop ordering under the same owner

**Files:**

- Create: `dist/pim/opt/pim/lib/cam_liveness.sh`
- Create: `test/camera_health/cam_liveness_test.sh`
- Create: `test/camera_health/cam_stop_order_test.sh`
- Modify: `dist/pim/opt/pim/bin/chk_cam_operate.sh`
- Modify: `dist/pim/opt/pim/bin/cam_operate_stop.sh`
- Modify: `dist/pim/opt/pim/bin/restart_app.sh`
- Modify: `test/camera_health/run_all.sh`

**Step 1: Write failing liveness and shutdown tests**

Assert with stubbed process/service state:

- liveness performs no launch in `STARTING`, `APPLYING_CONFIG`, `RECOVERING`, `STOPPING`, or `DEGRADED`;
- missing ORD in `ACTIVE` restarts only `ord-operate.service` through the executor boundary;
- missing VCM in `ACTIVE` restarts only VCM through the executor boundary;
- ORD/VCM start failure records `DEGRADED` with its target and does not call module/hard-reset/reboot;
- missing gstApp respects disconnect, video-node, subdev-readiness, and restart-grace gates before requesting `gstapp_restart`;
- valid-config repeated gstApp restart failures reach `module_reload`; invalid config never escalates;
- one liveness iteration cannot create a request while another pending/active lease exists;
- shutdown call order is lifecycle `STOPPING`, intake close, liveness quiesce, action/child quiesce, managed-process stop, owner cleanup;
- no process launch occurs after `STOPPING` is persisted;
- no long-running `restart_app.sh` process is started or left behind.

**Step 2: Run the new tests and verify failure**

```bash
rtk bash test/camera_health/cam_liveness_test.sh
rtk bash test/camera_health/cam_stop_order_test.sh
```

Expected: failure because liveness still belongs to the removed independent loop and stop has no state ordering.

**Step 3: Implement a one-iteration liveness supervisor**

Move the useful gates from old `restart_app.sh` into `cam_liveness.sh`:

```text
cam_liveness_tick
cam_liveness_gstapp_gate
cam_liveness_restart_ord
cam_liveness_restart_vcm
cam_liveness_note_failure
cam_liveness_quiesce
```

`cam_liveness_tick` is called by the daemon loop and returns after one bounded pass. Use exact process matching (`pgrep -x`) and `systemctl is-active ord-operate.service`. Keep the current grace defaults and gate meanings. Use persistent `gstapp_restart.consecutive_failures` plus a named default threshold of `5` for liveness escalation; reset it only after verified gstApp readiness.

`ord-operate.service` remains an execution boundary, but Task 9 removes its autonomous `Restart`. Until then, tests must stub systemd so the daemon remains the only decision owner.

**Step 4: Implement ordered stop**

`cam_operate_stop.sh` reads the active owner, transitions it to `STOPPING`, closes request intake, signals the daemon control loop to quiesce, waits a bounded interval for action/child acknowledgement, stops gstApp/BG/ORD/VCM, writes terminal stop state, and removes the owner record last. It must not call `killcam`, which would submit a new recovery request during shutdown.

The daemon installs `TERM`, `INT`, and `EXIT` traps that call the same idempotent stop primitives. Ensure two concurrent stop paths do not reorder cleanup or start a consumer.

**Step 5: Run liveness, stop, and full camera tests**

```bash
rtk bash test/camera_health/cam_liveness_test.sh
rtk bash test/camera_health/cam_stop_order_test.sh
rtk bash test/camera_health/run_all.sh
rtk bash test/cam_link/run_all.sh -v
```

Expected: all pass and the wrapper test confirms `restart_app.sh` has no loop.

**Step 6: Commit Task 5**

```bash
rtk git add dist/pim/opt/pim/lib/cam_liveness.sh dist/pim/opt/pim/bin/chk_cam_operate.sh dist/pim/opt/pim/bin/cam_operate_stop.sh dist/pim/opt/pim/bin/restart_app.sh test/camera_health/cam_liveness_test.sh test/camera_health/cam_stop_order_test.sh test/camera_health/run_all.sh
rtk git commit -m "fix(cam): preserve liveness under a single owner"
```

### Task 6: Migrate camera scripts, guardian, and health expectations off source snapshots and hashes

**Files:**

- Create: `test/camera_health/runtime_consumer_path_test.py`
- Modify: `dist/pim/opt/pim/bin/BG_Check_for_pim.sh`
- Modify: `dist/pim/opt/pim/bin/cam_channel_resolve.sh`
- Modify: `dist/pim/opt/pim/bin/pim_guardian.py`
- Modify: `dist/pim/opt/pim/bin/camera_config_expectation.py`
- Modify: `dist/pim/opt/pim/bin/camera_capture_probe.py`
- Modify: `test/camera_health/pim_guardian_startup_grace_test.py`
- Modify: `test/camera_health/config_expectation_test.py`
- Modify: `test/camera_health/capture_probe_test.py`
- Modify: `test/camera_health/run_all.sh`

**Step 1: Write the failing consumer boundary audit**

Define an explicit `CAMERA_RUNTIME_CONSUMERS` tuple in `runtime_consumer_path_test.py` containing the daemon, action/liveness/control libraries, wrappers, BG checker, channel resolver, guardian, expectation resolver, and capture probe. For each file, reject:

- `/tmp/config`;
- `/root/shared_v`;
- source `edgeconf_*.json` discovery;
- `config_sha256`, `boot_import_sha256`, `runtime_override`, and generation/manifest fields.

Separately assert that `config_guard.sh`, `camera_config_bootstrap.sh`, update/factory tools, `chk_wifi.sh`, and `chk_eth1.sh` are allowed source readers. This prevents a broad grep rule from breaking the deliberate network/source boundary.

**Step 2: Run the audit and focused Python tests to verify failure**

```bash
rtk python3 test/camera_health/runtime_consumer_path_test.py
rtk python3 test/camera_health/config_expectation_test.py
rtk python3 test/camera_health/capture_probe_test.py
```

Expected: failures on the current shared/tmp paths and hash fields.

**Step 3: Convert shell/Python camera consumers to one runtime file**

- `BG_Check_for_pim.sh`: set both camera and ETC reads to `PIM_CAMERA_RUNTIME_JSON`, defaulting to `/run/pim-camera/config/pim_runtime.json`.
- `cam_channel_resolve.sh`: replace directory discovery with `PIM_CAMERA_RUNTIME_JSON`; retain an explicit test file override, not a source-directory override.
- `pim_guardian.py`: load the merged runtime once and use the same object for its `edge` and `ord` views; record the runtime path in diagnostics.
- Guardian disconnect recovery requests `module_reload`; heartbeat-frozen recovery requests `gstapp_restart`; the generic watchdog passes an explicit action and reason to `cam-recoveryctl`. Existing SD-mount service control remains outside camera ownership, while its camera stop/start calls pass through the compatibility request wrappers during this release.
- Add a pure guardian action selector: camera mismatch/disconnect bits select `module_reload`, heartbeat-frozen selects `gstapp_restart`, and SD/CPU/voltage-only masks select no camera action.
- No automatic path in guardian invokes `init_cam.sh`, `kill_test.sh`, `start_cam.sh`, or writes `/tmp/recover_req_init_cam` directly.

All consumers validate syntax and required objects before acting. They never repair an invalid runtime from source and never escalate `CONFIG_INVALID` to hardware reset.

**Step 4: Remove config hashes from the health expectation path**

Change `camera_config_expectation.py` to read the runtime file directly, validate current boot ID only from `/proc`, and publish channel/domain expectations without READY/import hash fields. Default its input to `/run/pim-camera/config/pim_runtime.json`.

Change `camera_capture_probe.py::load_expectation` to return domains and stream mode without a config hash. Stop adding `producer_data.config_sha256`. Rewrite the associated tests so a direct valid runtime edit changes channel expectations on the next resolver/app restart without any hash comparison.

**Step 5: Run focused and full camera-health tests**

```bash
rtk python3 test/camera_health/runtime_consumer_path_test.py
rtk python3 test/camera_health/pim_guardian_startup_grace_test.py
rtk python3 test/camera_health/config_expectation_test.py
rtk python3 test/camera_health/capture_probe_test.py
rtk bash test/camera_health/run_all.sh
```

Expected: all pass; the consumer audit reports zero source/tmp/hash violations in its explicit camera list.

**Step 6: Commit Task 6**

```bash
rtk git add dist/pim/opt/pim/bin/BG_Check_for_pim.sh dist/pim/opt/pim/bin/cam_channel_resolve.sh dist/pim/opt/pim/bin/pim_guardian.py dist/pim/opt/pim/bin/camera_config_expectation.py dist/pim/opt/pim/bin/camera_capture_probe.py test/camera_health/runtime_consumer_path_test.py test/camera_health/pim_guardian_startup_grace_test.py test/camera_health/config_expectation_test.py test/camera_health/capture_probe_test.py test/camera_health/run_all.sh
rtk git commit -m "refactor(cam): migrate scripts to merged runtime config"
```

### Task 7: Make ORD and VCM parse the merged runtime document once

**Files:**

- Create: `test/camera_health/native_runtime_config_test.py`
- Modify: `ord/util.h`
- Modify: `ord/tcpServer.cpp`
- Modify: `vcm/util.h`
- Modify: `vcm/tcpServer.cpp`
- Modify: `ord/docs/VERIFICATION_GUIDE_ORD.md`
- Modify: `vcm/docs/VERIFICATION_GUIDE_VCM.md`
- Modify: `test/camera_health/run_all.sh`

**Step 1: Write a failing native-consumer source contract test**

Assert that production ORD/VCM source:

- defines exactly `PIM_RUNTIME_JSON_FILE` as `/run/pim-camera/config/pim_runtime.json`;
- contains no `/root/shared_v`, `/tmp/shared_v`, `EDGE_JSON_FILE`, `ORD_VCM_JSON_FILE`, or config `search_json_file` call;
- opens `PIM_RUNTIME_JSON_FILE` once in each `get_json_config` call;
- validates object-valued `VHL_CAM`, `ORD`, and `VCM` before field extraction;
- releases the json-c root object on every success/error path.

**Step 2: Run the test and verify failure**

```bash
rtk python3 test/camera_health/native_runtime_config_test.py
```

Expected: failures on both source trees' old paths and two-file parsing.

**Step 3: Refactor both parsers**

In both `util.h` files, replace the source/local macros with:

```c
#define PIM_RUNTIME_JSON_FILE "/run/pim-camera/config/pim_runtime.json"
```

In each `CTCPServer::get_json_config`, call `json_object_from_file(PIM_RUNTIME_JSON_FILE)` once, verify all three required objects, parse the existing VHL/ORD/VCM fields from that one root, and `json_object_put` once. Remove filename prefix/suffix validation and fallback discovery. Initialize `json_path` to the fixed file only if the struct field remains useful for logging; otherwise remove the unused assignment.

Update the verification guides to describe process-start caching and restart boundaries: ORD restart for `ORD`, VCM restart for `VCM`, and both restarts for `VHL_CAM` apply.

**Step 4: Run source tests and cross-build ORD/VCM**

```bash
rtk python3 test/camera_health/native_runtime_config_test.py
rtk ./build.sh clean ord
rtk ./build.sh ord
rtk ./build.sh clean vcm
rtk ./build.sh vcm
rtk strings dist/pim/usr/local/bin/ord
rtk strings dist/pim/usr/local/bin/vcm
```

Expected: builds succeed; both binary string listings contain `/run/pim-camera/config/pim_runtime.json` and contain no `/root/shared_v/edgeconf_pim.json` or `/root/shared_v/ord_vcm_conf.json`.

**Step 5: Run the camera-health suite**

```bash
rtk bash test/camera_health/run_all.sh
```

Expected: all pass. ORD/VCM binaries remain ignored build artifacts; commit their sources and tests, not the ignored outputs.

**Step 6: Commit Task 7**

```bash
rtk git add ord/util.h ord/tcpServer.cpp vcm/util.h vcm/tcpServer.cpp ord/docs/VERIFICATION_GUIDE_ORD.md vcm/docs/VERIFICATION_GUIDE_VCM.md test/camera_health/native_runtime_config_test.py test/camera_health/run_all.sh
rtk git commit -m "fix(cam): read merged runtime config in ord and vcm"
```

### Task 8: Change gstApp upstream, rebuild it, and deploy the tracked binary

**Files in `/home/jhw/ai/opencode/projects/gstApp`:**

- Modify: `parser.h`
- Modify: `parser.cpp`
- Modify: `main.cpp`
- Modify: `test/test_parser_config.cpp`

**Files in `/home/jhw/ai/opencode/projects/pim-package-jhw`:**

- Modify: `dist/pim/usr/local/bin/gstApp`
- Modify: `.github/binary-manifest.json`

**Step 1: Write the failing gstApp parser test**

Working directory: `/home/jhw/ai/opencode/projects/gstApp`

Extend `test/test_parser_config.cpp` so its fixture is a merged `pim_runtime.json` containing `VHL_CAM`, `ORD`, and `VCM`. Assert that:

- `ParserClass::json_parser` accepts an exact file path rather than searching a directory;
- `arg.json_file` equals that exact fixture path;
- `VCM.srt_enable` is read from the already opened root object;
- a missing/non-object `VCM` returns `-1` and never triggers a second file open.

**Step 2: Run the QEMU parser test and verify failure**

```bash
rtk bash test/run-parser-config-test.sh
```

Expected: compile/test failure because `json_parser` still expects a directory and opens the ORD/VCM source separately.

**Step 3: Implement exact-path single-document parsing**

In `parser.h`, replace prefix/path defaults with:

```c
#define PIM_RUNTIME_JSON_FILE "/run/pim-camera/config/pim_runtime.json"
```

Change `ParserClass::json_parser` to duplicate the supplied file path into `arg.json_file`, open it once, require object-valued `VHL_CAM`, `ORD`, and `VCM`, parse `VHL_CAM`, then read `VCM.srt_enable` from the same root. Use one cleanup path that always releases the json-c root. Remove the `/home/root/ord_vcm_conf.json` fallback and all `search_file` use from this startup path. `main.cpp` calls:

```cpp
if (parser->json_parser(PIM_RUNTIME_JSON_FILE, JSON_CAM_OBJ_NAME) < 0)
  return -1;
```

Keep `/root/shared_v/.passwd` behavior out of scope; the binary may still contain that unrelated password path, so validation rejects only old camera JSON source strings.

**Step 4: Run upstream tests and commit gstApp source**

```bash
rtk bash test/run-parser-config-test.sh
rtk git diff --check
rtk git add parser.h parser.cpp main.cpp test/test_parser_config.cpp
rtk git commit -m "fix(config): read merged camera runtime JSON"
rtk git log -1 --oneline
```

Expected: parser tests pass and the final command prints the exact upstream commit recorded later by `update_bin.sh`.

**Step 5: Cross-build and deploy through the repository tool**

```bash
rtk ./make-for-imx8 -j4
rtk ./update_bin.sh --pim-dir /home/jhw/ai/opencode/projects/pim-package-jhw
```

Expected: the copied artifact is AArch64; `.github/binary-manifest.json` is updated with measured size/hash/mode and the committed gstApp source ID.

**Step 6: Verify the deployed binary and manifest**

Working directory: `/home/jhw/ai/opencode/projects/pim-package-jhw`

```bash
rtk python3 tools/verify_binaries.py --strict
rtk strings dist/pim/usr/local/bin/gstApp
rtk git diff --check
```

Expected: strict verification passes; strings include `/run/pim-camera/config/pim_runtime.json` and exclude `/root/shared_v/ord_vcm_conf.json`. Add the runtime path to gstApp `required_strings` in the manifest if `update_bin.sh` preserves the prior list, as intended.

**Step 7: Commit the package binary and manifest together**

```bash
rtk git add dist/pim/usr/local/bin/gstApp .github/binary-manifest.json
rtk git commit -m "chore(pim): deploy runtime-config gstApp"
```

### Task 9: Wire systemd/package lifecycle and update the operational contract

**Files:**

- Modify: `dist/pim/etc/systemd/system/pim-camera-config.service`
- Modify: `dist/pim/etc/systemd/system/cam-operate.service`
- Modify: `dist/pim/etc/systemd/system/ord-operate.service`
- Modify: `dist/pim/etc/systemd/system/camera-capture-probe.service`
- Modify: `dist/pim/etc/systemd/system/camera-health-shadow.service`
- Modify: `dist/pim/etc/systemd/system/camera-health-shadow-compare.service`
- Modify: `dist/pim/DEBIAN/postinst`
- Modify: `dist/pim/DEBIAN/preinst`
- Modify: `dist/pim/DEBIAN/postrm`
- Modify: `dist/pim/DEBIAN/control`
- Create: `test/camera_health/systemd_recovery_contract_test.py`
- Create: `docs/camera-health/cam-recovery-operations.md`
- Modify: `docs/camera-health/boot-config-snapshot.md`
- Modify: `docs/camera-health/config-consumer-inventory.md`
- Modify: `docs/camera-health/config-expectation.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/RELEASE_NOTES.md`
- Modify: `test/camera_health/package_executable_test.py`
- Modify: `test/camera_health/run_all.sh`

**Step 1: Write a failing unit/package contract test**

Assert exact service behavior:

- `pim-camera-config.service` is a guard ordered after `pim-config-guard.service` and before `cam-operate.service`, but has no runtime publication wording/path;
- `cam-operate.service` requires/starts after the guard, sets `RuntimeDirectory=pim-camera`, `StateDirectory=pim-camera`, directory modes, `KillMode=control-group`, and retains systemd `Restart=on-failure`;
- `ord-operate.service` has `After=cam-operate.service`, `PartOf=cam-operate.service`, and no `Restart=` directive;
- `ord-operate.service` has no install target, and postinst disables any legacy enablement while leaving manual executor starts available;
- capture/shadow units order after `cam-operate.service` and condition on `/run/pim-camera/config/pim_runtime.json`, never `/tmp/config/READY`;
- postinst installs `/usr/local/bin/cam-recoveryctl`, preserves one-release wrapper links, and enables guard/cam service in the right order;
- package entrypoint test covers the config engine, recovery CLI, and wrapper executability;
- package version is `0.6.3+jhw.camera7`.

**Step 2: Run the contract test and verify failure**

```bash
rtk python3 test/camera_health/systemd_recovery_contract_test.py
```

Expected: failures on old unit ordering, `/tmp/config/READY`, autonomous ORD restart, missing directories, and missing CLI link.

**Step 3: Update systemd and maintainer scripts**

Configure `cam-operate.service` with:

```ini
[Unit]
Requires=pim-camera-config.service
After=pim-camera-config.service sd-mount.service

[Service]
RuntimeDirectory=pim-camera
RuntimeDirectoryMode=0750
StateDirectory=pim-camera
StateDirectoryMode=0750
KillMode=control-group
TimeoutStopSec=90s
```

Do not rely on runtime-directory preservation; every invocation rebuilds runtime. Keep `Restart=on-failure` because it restarts the daemon itself, not managed apps. Remove autonomous ORD restart and the unit's `[Install]` target, disable legacy ORD enablement in postinst, and let the executor call `systemctl start/restart ord-operate.service`.

Remove the current `DefaultDependencies=no` from `cam-operate.service`; the guard, shared mount, runtime directory, and persistent state directory must be available through normal system startup ordering. Extend package dependencies to `python3, python3-yaml, jq, util-linux, procps` because the runtime builder/control path now requires those tools explicitly.

Update maintainer scripts so package upgrade stop uses the ordered `ExecStop` path, links `cam-recoveryctl`, and does not delete persistent recovery history on upgrade, remove, or purge. Do not add a new destructive history cleanup to this change.

**Step 4: Rewrite operator and architecture docs**

Document:

- startup versus `apply-config` versus automatic recovery;
- direct runtime edit test procedure and the expected mixed in-memory exception;
- BUSY/exit/sentinel semantics and status examples;
- persistent counters/history locations and no-SHA policy;
- wrapper deprecation window;
- explicit classification of source authorities/network consumers versus camera runtime consumers;
- action mapping for VHL hardware/non-hardware, ORD, VCM, ETC, and script-only keys;
- recovery that remains ACTIVE versus terminal `DEGRADED` behavior.
- the separate `pim-check` integration boundary, which is not claimed complete unless its external source/deployment is updated and verified.

Replace the old boot snapshot and expectation descriptions rather than adding contradictory appendices.

**Step 5: Run package/service tests**

```bash
rtk python3 test/camera_health/systemd_recovery_contract_test.py
rtk python3 test/camera_health/package_executable_test.py
rtk bash test/camera_health/run_all.sh
rtk python3 tools/verify_binaries.py --strict
```

Expected: all pass and no unit references `/tmp/config/READY`.

**Step 6: Commit Task 9**

```bash
rtk git add dist/pim/etc/systemd/system/pim-camera-config.service dist/pim/etc/systemd/system/cam-operate.service dist/pim/etc/systemd/system/ord-operate.service dist/pim/etc/systemd/system/camera-capture-probe.service dist/pim/etc/systemd/system/camera-health-shadow.service dist/pim/etc/systemd/system/camera-health-shadow-compare.service dist/pim/DEBIAN/postinst dist/pim/DEBIAN/preinst dist/pim/DEBIAN/postrm dist/pim/DEBIAN/control test/camera_health/systemd_recovery_contract_test.py test/camera_health/package_executable_test.py test/camera_health/run_all.sh docs/camera-health/cam-recovery-operations.md docs/camera-health/boot-config-snapshot.md docs/camera-health/config-consumer-inventory.md docs/camera-health/config-expectation.md docs/CHANGELOG.md docs/RELEASE_NOTES.md
rtk git commit -m "feat(cam): wire serialized recovery into package services"
```

### Task 10: Run full host gates, review the change graph, and complete board acceptance

**Files:**

- Create after target execution: `docs/camera-health/cam-recovery-acceptance-2026-09.md`

**Step 1: Run static and host regression gates**

Working directory: `/home/jhw/ai/opencode/projects/pim-package-jhw`

```bash
rtk bash test/camera_health/run_all.sh
rtk bash test/cam_link/run_all.sh -v
rtk bash test/test_cam_state.sh
rtk bash test/test_init_cam_cleanup.sh
rtk python3 -m compileall -q dist/pim/opt/pim/bin test/camera_health
rtk shellcheck dist/pim/opt/pim/bin/camera_config_bootstrap.sh dist/pim/opt/pim/bin/chk_cam_operate.sh dist/pim/opt/pim/bin/cam_operate_stop.sh dist/pim/opt/pim/bin/start_cam.sh dist/pim/opt/pim/bin/kill_test.sh dist/pim/opt/pim/bin/init_cam.sh dist/pim/opt/pim/bin/cam_hard_reset.sh dist/pim/opt/pim/bin/restart_app.sh dist/pim/opt/pim/bin/BG_Check_for_pim.sh dist/pim/opt/pim/bin/cam_channel_resolve.sh dist/pim/opt/pim/lib/cam_recovery.sh dist/pim/opt/pim/lib/cam_recovery_actions.sh dist/pim/opt/pim/lib/cam_operate_control.sh dist/pim/opt/pim/lib/cam_liveness.sh
rtk python3 tools/verify_binaries.py --strict
rtk git diff --check
```

Expected: every command exits `0`. If `shellcheck` is unavailable, record that as an environment gap and run the remaining gates; do not report shellcheck as passed.

**Step 2: Use the repository graph for final impact and test coverage review**

Update the code-review graph, run change detection from the pre-implementation commit, inspect affected flows, and query tests for changed Python/C++ nodes. Because the graph currently does not index the shell-heavy paths, supplement its result with the explicit host suites and source-boundary audits above. Resolve every high-risk finding or document why it is a graph limitation rather than a code gap.

**Step 3: Build the installable package**

```bash
rtk ./build.sh
```

Expected: ORD/VCM and the package build succeed, binary verification succeeds, and the output package reports version `0.6.3+jhw.camera7`.

**Step 4: Execute target-board acceptance without hiding intermediate state**

On the reserved target board, record command output and timestamps for:

1. Fresh boot: runtime merge/aliases are valid and `cam-operate` reaches `ACTIVE`.
2. Kill gstApp, ORD, and VCM separately: each is automatically restarted; ORD/VCM failure injection does not reset hardware.
3. Run two simultaneous requests: one is accepted and one exits `75`; one hardware action is observed.
4. Run module and hard-reset requests: `systemctl is-active cam-operate.service` remains `active`, and owner invocation/PID/token stay unchanged.
5. Restart `cam-operate` in the same boot with unchanged source: exactly one module reload occurs.
6. Change a hardware projection source value and restart: one hard reset occurs; restore the source through an atomic rename immediately after the test.
7. Edit `pim_runtime.json` atomically, restart only gstApp, and confirm the edited value is consumed while ORD/VCM may retain prior in-memory values.
8. Run `apply-config`: source values overwrite the manual runtime edit and affected processes reach ready state.
9. Present an invalid newest edgeconf: apply fails without old-file fallback and leaves current runtime/processes untouched; restore the file after evidence capture.
10. Inject post-publish action failure: new runtime remains, lifecycle becomes `DEGRADED`, and no rollback occurs.
11. Inject module failure then hard-reset failure: fallback counters show module once, hard reset once, and reboot fallback at most once for the top-level request. Use a reboot stub or maintenance-safe interception unless an actual reboot is separately approved.
12. Stop/restart stress: no orphan `restart_app.sh`, duplicate gstApp/ORD/VCM, or launch after `STOPPING`.
13. Reboot once after a prepared interrupted request: reconciliation occurs once and persistent counters/history survive.

Do not run an actual reboot fallback, destructive filesystem operation, or source mutation without the board owner's explicit approval and a saved atomic backup. A missing board or denied fault injection means the release gate remains incomplete, not passed by inference.

**Step 5: Record exact acceptance evidence**

Create `docs/camera-health/cam-recovery-acceptance-2026-09.md` with board identity, package version, boot ID, each test's commands/result, request IDs, counter deltas, owner tuple continuity, restored source confirmation, and any skipped destructive case with its reason.

**Step 6: Review and commit acceptance evidence**

```bash
rtk git add docs/camera-health/cam-recovery-acceptance-2026-09.md
rtk git commit -m "test(cam): record serialized recovery acceptance"
```

## Completion criteria

Implementation is complete only when all of the following are true:

- host/package gates pass with actual output;
- gstApp upstream source commit and primary binary/manifest commit both exist;
- startup/restart/apply are the only source-search boundaries;
- automatic recovery and wrappers use the current mutable runtime only;
- one owner/executor serializes all camera side effects and keeps `cam-operate` active;
- dead gstApp/ORD/VCM auto-restart remains functional under `ACTIVE` only;
- stop ordering prevents relaunch and leaves no orphan restart loop;
- counters/history persist and interrupted work reconciles once;
- no config SHA/generation/manifest mechanism remains in the camera runtime path;
- target-board acceptance is recorded, with destructive cases either safely executed under approval or explicitly left as an incomplete release gate.
