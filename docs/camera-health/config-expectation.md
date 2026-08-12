# Camera capture expectation v1

`camera_config_expectation.py` converts the current boot-scoped
`/tmp/config/edgeconf_pim.json` into the capture-domain expectation consumed by
`camera_capture_probe.py`. It is read-only with respect to camera hardware and
does not start, stop, or recover a pipeline.

The service remains intentionally disabled. When an engineer explicitly starts
`camera-capture-probe.service`, its `ExecStartPre` resolves the expectation
before the IRQ probe begins.

## Inputs and generation rules

The resolver requires:

- `/tmp/config/READY` with the current `boot_id` and a valid boot-import SHA-256;
- `/tmp/config/edgeconf_pim.json` with positive `cam_width`, `cam_height`, and
  `fps` values;
- boolean channel enables at `VHL_CAM.i2c2.ch0/ch1.enable` and
  `VHL_CAM.i2c1.ch2/ch3.enable`. A missing `enable` is treated as `false`.

`READY` is a boot publication gate, not a runtime hash pin. An engineer may
atomically replace the JSON in `/tmp/config`; the resolver accepts the current
valid file and publishes both its SHA-256 and the original import SHA-256. A
difference is diagnosed as `runtime_override=true`.

## Domain contract

The output is atomically published as mode `0640` at
`/run/pim-camera/config-expectation.json`.

| domain | possible channels | single | dual-wide |
| --- | --- | --- | --- |
| `ch01` | 0, 1 | either channel enabled | both 0 and 1 enabled |
| `ch23` | 2, 3 | either channel enabled | both 2 and 3 enabled |

Each domain carries:

- `possible_channels`: fixed hardware wiring;
- `active_channels`: configured channel identity for observation scope;
- `configured_channel_mask`: only that domain's bits;
- `mode`: `disabled`, `single`, or `dual-wide`;
- `expected_format`: CSI input dimensions. Dual-wide doubles the configured
  per-sensor width because gstApp receives the pair as one wide frame.

The top-level `configured_channel_mask` covers all four channels. The
top-level `stream_mode` is `unknown` when no domain is enabled, `single` when
all enabled domains are single, `dual-wide` when all are dual-wide, and
`independent` when enabled domains have mixed modes.

This is only the **configured** mask. It must not be used as the physical link
presence mask or the stream-domain activity mask. Those remain independent
runtime evidence. In dual-wide mode, loss of either physical channel can make
the shared CSI/capture domain unavailable; this resolver does not claim that
the peer channel can continue recording independently.

## Failure behavior

The resolver fails closed for stale `READY`, malformed JSON, invalid hashes,
invalid dimensions/FPS, or non-boolean enable fields. The capture producer also
validates that the expectation contains exactly the domains and channel wiring
declared by `camera_capture_map_v1.json`. A stale or inconsistent expectation
cannot silently enable a different domain.

Offline coverage is provided by:

```sh
bash test/camera_health/run_all.sh
```
