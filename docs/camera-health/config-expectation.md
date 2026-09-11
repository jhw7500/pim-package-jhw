# Camera capture expectation v1

`camera_config_expectation.py` converts the merged camera runtime at
`/run/pim-camera/config/pim_runtime.json` into the capture-domain expectation
consumed by `camera_capture_probe.py`. It is read-only with respect to camera
hardware and does not start, stop, or recover a pipeline.

`camera-capture-probe.service` remains intentionally non-enabled. When an
engineer explicitly starts it, systemd orders it after `cam-operate.service`
and conditions startup on the merged runtime. `ExecStartPre` resolves the
expectation before the IRQ probe begins.

## Input and validation

The resolver parses the current runtime file and requires object-valued
`VHL_CAM`, `ORD`, and `VCM`. From `VHL_CAM` it requires positive
`cam_width`, `cam_height`, and `fps` values plus boolean channel enables at:

- `i2c2.ch0.enable` and `i2c2.ch1.enable`
- `i2c1.ch2.enable` and `i2c1.ch3.enable`

A missing `enable` is treated as `false`. The resolver records the current boot
identity only as process/runtime diagnostics. A valid atomic manual edit of
`pim_runtime.json` is reflected the next time the expectation/probe service is
started; source files are not consulted or repaired by this path.

## Domain contract

The output is atomically published with mode `0640` at
`/run/pim-camera/config-expectation.json`.

| domain | possible channels | single | dual-wide |
| --- | --- | --- | --- |
| `ch01` | 0, 1 | either channel enabled | both 0 and 1 enabled |
| `ch23` | 2, 3 | either channel enabled | both 2 and 3 enabled |

Each domain carries:

- `possible_channels`: fixed hardware wiring
- `active_channels`: configured channel identity for observation scope
- `configured_channel_mask`: only that domain's bits
- `mode`: `disabled`, `single`, or `dual-wide`
- `expected_format`: CSI input dimensions; dual-wide doubles the configured
  per-sensor width because gstApp receives the pair as one wide frame

The top-level `configured_channel_mask` covers all four channels. The
top-level `stream_mode` is `unknown` when no domain is enabled, `single` when
all enabled domains are single, `dual-wide` when all are dual-wide, and
`independent` when enabled domains have mixed modes.

This is only the **configured** mask. It must not be used as the physical link
presence mask or the stream-domain activity mask. Those remain independent
runtime evidence. In dual-wide mode, loss of either physical channel can make
the shared CSI/capture domain unavailable; the resolver does not claim that the
peer channel can continue recording independently.

## Failure behavior

Malformed runtime JSON, missing required objects, invalid dimensions/FPS, or
non-boolean enable fields fail closed before the probe starts. The capture
producer also validates that the expectation contains exactly the domains and
channel wiring declared by `camera_capture_map_v1.json`. An invalid or
inconsistent expectation cannot silently enable a different domain, trigger
source recovery, or escalate to a hardware reset.

Offline coverage is provided by:

```sh
bash test/camera_health/run_all.sh
```
