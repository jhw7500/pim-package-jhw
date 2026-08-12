# Legacy versus health-v1 shadow comparator

`camera_health_shadow_compare.py` measures agreement between the current legacy
camera-link verdict and the read-only health-v1 aggregate. It never writes
`bg_chk_flag.bin`, `err_camN.log`, camera state, restart flags, or a recovery
request. The output always declares:

- `legacy_owner=true`
- `decision_authority=legacy`
- `recovery_requested=false`

The default output is atomically replaced at
`/run/pim-camera/shadow-comparison.json` with mode `0640`.

## Comparable scope

The legacy low nibble of `/tmp/bg_chk_flag.bin` originates from
`chk_cam_connect.sh` and the MAX9296 driver disconnect mask. Therefore it is
compared only with v1 observations from these blocks:

- Sensor
- ISP
- serializer (MAX9295 on the remote camera module)
- GMSL link
- deserializer (MAX9296 on the receiver board)

CSI2, capture, GStreamer, recording, and storage failures remain visible in
the aggregate but are not called a disagreement with the legacy physical-link
mask. This avoids classifying a storage-only failure as a new camera-link false
positive.

The comparison uses `configured_channel_mask` only to limit active channels.
It does not substitute that mask for physical presence. In dual-wide mode a
one-link physical failure may appear as a two-channel legacy mask while v1
retains the single physical link identity; this is counted as
`AGREE_FAILED_SCOPE_DIFF`, not silently normalized away.

## Input consistency and classifications

The comparator requires a current-boot config expectation and a fresh
`aggregate-shadow.json`. All three producer states must be `OK` before v1 is
allowed to agree or disagree with legacy.

The legacy mask is accepted only when it matches the simultaneously visible
`err_camN.log` files. `BG_Check_for_pim.sh` does not publish these atomically, so
a mismatch is classified `INCONCLUSIVE` rather than counted as a product fault.
An active `init_cam_flag`, `restart_flag`, or `kill_flag` is
`EXPECTED_DOWNTIME`, including the short window in which the BG flag is absent.

Stable classifications are:

- `AGREE_HEALTHY`
- `AGREE_FAILED`
- `AGREE_FAILED_UNSCOPED`
- `AGREE_FAILED_SCOPE_DIFF`
- `DISAGREE_SCOPE`
- `LEGACY_ONLY_FAILURE`
- `V1_ONLY_FAILURE`
- `LEGACY_ONLY` (missing/stale producer or aggregate)
- `EXPECTED_DOWNTIME`
- `INCONCLUSIVE`

The output carries boot-scoped sample counts, per-class counts, current run
length, and transition timestamp. Counts are recovered from the previous
atomic output after a comparator process restart; they reset on boot-ID change.

## Deployment

`camera-health-shadow-compare.service` intentionally has no `[Install]`
section. Starting it does not pull in, stop, or restart the aggregator, capture
probe, cam-operate, gstApp, ORD, or VCM. It is enabled only as an explicit soak
step after all producer capabilities are present.

Offline verification:

```sh
bash test/camera_health/run_all.sh
```
