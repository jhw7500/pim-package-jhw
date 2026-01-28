# SD Recording Manual Test Cases (i.MX8MP 4ch)

## Scope

- Record app: GStreamer split recording (`recording_time` 1~5min)
- Storage: SD card (FAT32/ext4)
- Management: `.part -> all_done -> Safe Move` and session-based retention

## Preconditions

- `/dev/shm` usable for recording: ~2GB
- `recording_time` default 1, test with 1 and 5
- `muxer=mp4`
- SD mount monitor produces `/dev/shm/sd_mount_flag`
- Final directory contains only committed files (no `*.part`)

## PASS/FAIL Rules

- PASS: `final_path` has 0 `*.part` files at all times
- PASS: for a session `YYYYMMDD_HHMM`, committed outputs are complete set (all enabled channels; optional srt)
- FAIL: any `*.part` appears in `final_path`
- FAIL: partial deletion/retention leaving an incomplete session set in `final_path`

## Test Cases

### TC1: Normal recording (recording_time=1)

1. Set `recording_time=1` and start recording.
2. Run for 30 minutes.
3. Verify:
   - `final_path` contains minute-grouped files (per session id).
   - `final_path` has no `*.part`.

### TC2: Normal recording (recording_time=5)

1. Set `recording_time=5` and start recording.
2. Run for 30 minutes.
3. Verify:
   - each 5-min segment is committed.
   - `final_path` has no `*.part`.

### TC3: SD full watermark behavior (WARN=90%, CRIT=95%)

1. Fill SD to >90% usage.
2. Start recording.
3. Verify:
   - oldest sessions are deleted until usage <= 90%.
4. Fill SD to >95% usage.
5. Verify:
   - deletion accelerates, and if unable to free space, system flips to RAM-only mode (sd_mount_flag becomes 0, SD writes stop).

### TC4: Software RO (filesystem remount-ro)

1. Force ext4 error condition in a controlled environment.
2. Verify:
   - SD mount becomes `(ro,)`.
   - `/dev/shm/sd_mount_flag` flips to 0.
   - system continues recording (RAM-only), and SD no longer receives writes.

### TC5: Hardware RO (/sys/block/mmcblk1/ro==1)

1. Use a card or test setup that triggers HW RO.
2. Verify:
   - `/sys/block/mmcblk1/ro` becomes 1.
   - `/dev/shm/sd_mount_flag` flips to 0.
   - system continues recording in RAM-only mode; SD writes stop.

### TC6: SD remove/insert

1. Remove SD during recording.
2. Verify:
   - `/dev/shm/sd_mount_flag` flips to 0.
   - recording continues in RAM-only mode.
3. Insert SD again.
4. Verify:
   - mount returns RW and `/dev/shm/sd_mount_flag` flips to 1.
   - new sessions are committed to SD.

### TC7: NTP time jump safety (stale cleanup)

1. Start recording and wait until `*.part` exist.
2. Apply a large time jump (forward/back) via NTP sync.
3. Verify:
   - recently-writing `*.part` are not deleted as stale.
   - only truly stuck files (size-stable for window) are removed.
