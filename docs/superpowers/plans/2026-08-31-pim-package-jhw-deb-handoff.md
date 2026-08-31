# PIM Package JHW Camera/VPU DEB Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, board-qualify, and deliver one identifiable `pim-mp` DEB plus one self-contained Korean installation and test guide without sharing the personal GitHub repository.

**Architecture:** A small Python packager copies the tracked `dist/pim` payload into an isolated temporary staging tree, overrides only the staged Debian version, builds with root ownership, extracts the DEB, and byte-audits the complete data payload. Existing package contract tests and binary-manifest verification gate the source; a designated target board gates installation, gstApp, MAX9296, VPU, resolution, crop, frame format, and rollback readiness.

**Tech Stack:** Python 3.8 standard library, `dpkg-deb`, Debian maintainer scripts, Bash, jq, V4L2/media tools, GStreamer/gstApp, MAX9296/AP1302, Markdown.

**Spec:** `docs/superpowers/specs/2026-08-31-pim-package-jhw-deb-handoff-design.md`

## Global Constraints

- External deliverables are exactly `pim-mp_0.6.3+jhw.camera1_arm64.deb` and `PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md`.
- Do not share a GitHub URL, source archive, GitHub Release, ZIP/TAR upgrade bundle, or GitLab branch.
- Package metadata must be `Package: pim-mp`, `Version: 0.6.3+jhw.camera1`, `Architecture: arm64`.
- The supported target is i.MX8MP, Ubuntu 20.04, kernel `5.10.35-lts-5.10.y+g2fce14defc04` only.
- Production camera tests use 30 FPS; 120 FPS remains qualification-only and must not be reported as supported.
- Current 640x360 is AP1302/CSI scaling after FHD sensor readout, not native sensor readout.
- Resolution selection and digital crop are independent; `crop_enable=false` must not write crop registers.
- Do not introduce manual WB register `0x510a` writes.
- Preserve the recipient's unrelated edgeconf values and channel enable state unless a named test case intentionally changes them.
- Never install without the old DEB and JSON backups required for rollback.
- Do not push, tag, or create a remote release during this plan.

## File Structure

- Create `tools/build_handoff_deb.py`: reproducible staging-only version override, DEB build, metadata validation, and complete payload comparison.
- Create `test/tools/build_handoff_deb_test.py`: unit and minimal-package integration contract for the packager.
- Create `docs/handoff/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md`: external recipient guide with no repository URL.
- Generate ignored `handover/pim-package-jhw-camera-vpu-20260831/pim-mp_0.6.3+jhw.camera1_arm64.deb`: final binary deliverable.
- Generate ignored `handover/pim-package-jhw-camera-vpu-20260831/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md`: byte copy of the reviewed guide.
- Store board evidence under `/root/camtest/handoff-camera1-20260831/` on the target; do not include evidence archives in the two-file external deliverable.

---

### Task 1: Reproducible Staging-Only DEB Packager

**Files:**
- Create: `test/tools/build_handoff_deb_test.py`
- Create: `tools/build_handoff_deb.py`

**Interfaces:**
- Consumes: a Debian directory tree containing `DEBIAN/control` and data payload files.
- Produces: `build_handoff_deb.build_package(source: Path, output_dir: Path, version: str) -> Path`.
- Produces: CLI options `--source`, `--output-dir`, and `--version` with the design defaults.
- Guarantees: the source tree is not modified, the output refuses overwrite, and the extracted DEB data payload exactly matches staged data by type, mode, link target, and SHA-256.

- [ ] **Step 1: Write the failing packager test**

Create `test/tools/build_handoff_deb_test.py` with a standard-library test that dynamically imports the tool, constructs a minimal package in a temporary directory, and checks both version isolation and payload fidelity:

```python
#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/build_handoff_deb.py"


def load_module():
    spec = importlib.util.spec_from_file_location("build_handoff_deb", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HandoffDebTest(unittest.TestCase):
    def make_package(self, root: Path) -> Path:
        source = root / "pim"
        (source / "DEBIAN").mkdir(parents=True)
        (source / "opt/pim/bin").mkdir(parents=True)
        (source / "DEBIAN/control").write_text(
            "Package: pim-mp\nVersion: 0.6.3\nArchitecture: arm64\n"
            "Maintainer: PIM\nDescription: test\n",
            encoding="utf-8",
        )
        tool = source / "opt/pim/bin/probe.sh"
        tool.write_text("#!/bin/sh\necho ok\n", encoding="utf-8")
        tool.chmod(0o755)
        (source / "opt/pim/current").symlink_to("bin/probe.sh")
        return source

    def test_build_changes_only_staged_version_and_preserves_payload(self):
        module = load_module()
        with tempfile.TemporaryDirectory(prefix="handoff-deb-test.") as tmp:
            work = Path(tmp)
            source = self.make_package(work)
            original = (source / "DEBIAN/control").read_bytes()
            output = module.build_package(
                source, work / "out", "0.6.3+jhw.camera1"
            )
            self.assertEqual(original, (source / "DEBIAN/control").read_bytes())
            fields = subprocess.check_output(
                ["dpkg-deb", "-f", str(output), "Package", "Version", "Architecture"],
                text=True,
            ).splitlines()
            self.assertEqual(fields, ["pim-mp", "0.6.3+jhw.camera1", "arm64"])
            with tempfile.TemporaryDirectory(prefix="handoff-deb-extract.") as extracted:
                subprocess.run(["dpkg-deb", "-x", str(output), extracted], check=True)
                target = Path(extracted) / "opt/pim/bin/probe.sh"
                self.assertEqual(target.read_bytes(), b"#!/bin/sh\necho ok\n")
                self.assertEqual(target.stat().st_mode & 0o777, 0o755)
                self.assertEqual(
                    (Path(extracted) / "opt/pim/current").readlink(),
                    Path("bin/probe.sh"),
                )

    def test_existing_output_is_refused(self):
        module = load_module()
        with tempfile.TemporaryDirectory(prefix="handoff-deb-test.") as tmp:
            work = Path(tmp)
            source = self.make_package(work)
            output_dir = work / "out"
            output_dir.mkdir()
            expected = output_dir / "pim-mp_0.6.3+jhw.camera1_arm64.deb"
            expected.write_bytes(b"do not overwrite")
            with self.assertRaises(FileExistsError):
                module.build_package(source, output_dir, "0.6.3+jhw.camera1")
            self.assertEqual(expected.read_bytes(), b"do not overwrite")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test and verify the expected failure**

Run:

```bash
python3 test/tools/build_handoff_deb_test.py
```

Expected: FAIL because `tools/build_handoff_deb.py` does not exist.

- [ ] **Step 3: Implement the minimal packager**

Create `tools/build_handoff_deb.py`. Implement these exact contracts:

```python
DEFAULT_VERSION = "0.6.3+jhw.camera1"
DEFAULT_SOURCE = ROOT / "dist/pim"
DEFAULT_OUTPUT = ROOT / "handover/pim-package-jhw-camera-vpu-20260831"
BANNED_NAMES = {".omc", ".bkit", ".serena", ".vscode", "__pycache__"}


def rewrite_version(control: Path, version: str) -> None:
    lines = control.read_text(encoding="utf-8").splitlines()
    matches = [index for index, line in enumerate(lines) if line.startswith("Version:")]
    if len(matches) != 1:
        raise ValueError(f"expected one Version field, found {len(matches)}")
    lines[matches[0]] = f"Version: {version}"
    control.write_text("\n".join(lines) + "\n", encoding="utf-8")
```

Represent every data-path entry with a stable tuple:

```python
def payload_manifest(root: Path) -> dict[str, tuple[str, int, str]]:
    # regular file -> ("file", mode, sha256)
    # symlink      -> ("link", mode, os.readlink(path))
    # directory    -> ("dir", mode, "")
    # exclude the top-level DEBIAN metadata directory and banned names
```

Build and audit in one operation:

```python
def build_package(source: Path, output_dir: Path, version: str) -> Path:
    source = source.resolve()
    control = source / "DEBIAN/control"
    if not control.is_file():
        raise FileNotFoundError(control)
    package = control_field(control, "Package")
    architecture = control_field(control, "Architecture")
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"{package}_{version}_{architecture}.deb"
    if output.exists():
        raise FileExistsError(output)

    with tempfile.TemporaryDirectory(prefix="pim-handoff-stage.") as temporary:
        stage = Path(temporary) / "pim"
        shutil.copytree(source, stage, symlinks=True)
        remove_banned(stage)
        rewrite_version(stage / "DEBIAN/control", version)
        expected = payload_manifest(stage)
        subprocess.run(
            ["dpkg-deb", "--root-owner-group", "--build", str(stage), str(output)],
            check=True,
        )
        extracted = Path(temporary) / "extracted"
        subprocess.run(["dpkg-deb", "-x", str(output), str(extracted)], check=True)
        actual = payload_manifest(extracted)
        if actual != expected:
            raise RuntimeError(describe_manifest_difference(expected, actual))
        validate_deb_fields(output, package, version, architecture)
    print(f"DEB={output}")
    print(f"SHA256={sha256_file(output)}")
    return output
```

The CLI must return non-zero with a concise error for a missing control file, invalid version field,
metadata mismatch, payload mismatch, or existing output. It must never edit `dist/pim`.

- [ ] **Step 4: Run the focused packager test**

Run:

```bash
python3 test/tools/build_handoff_deb_test.py
```

Expected: `Ran 2 tests` and `OK`.

- [ ] **Step 5: Run static checks**

Run:

```bash
python3 -m py_compile tools/build_handoff_deb.py test/tools/build_handoff_deb_test.py
git diff --check
```

Expected: both commands exit 0 without output.

- [ ] **Step 6: Commit the packager**

```bash
git add tools/build_handoff_deb.py test/tools/build_handoff_deb_test.py
git commit -m "build: add reproducible camera VPU handoff deb"
```

### Task 2: Source Gates, DEB Build, and Extracted-Payload Audit

**Files:**
- Generate: `handover/pim-package-jhw-camera-vpu-20260831/pim-mp_0.6.3+jhw.camera1_arm64.deb`

**Interfaces:**
- Consumes: Task 1 packager and tracked `dist/pim` payload.
- Produces: one locally ignored DEB plus emitted SHA-256.

- [ ] **Step 1: Verify the repository payload contracts**

Run:

```bash
python3 tools/verify_binaries.py --strict
python3 test/camera_health/max9296_package_config_test.py
python3 test/camera_health/max9296_package_tools_test.py
python3 test/camera_health/package_executable_test.py
```

Expected: binary verification exits 0; each package test prints `PASS` and exits 0.

- [ ] **Step 2: Verify maintainer-script syntax and kernel identity**

Run:

```bash
bash -n dist/pim/DEBIAN/preinst
bash -n dist/pim/DEBIAN/postinst
bash -n dist/pim/DEBIAN/prerm
bash -n dist/pim/DEBIAN/postrm
modinfo -F vermagic dist/pim/opt/pim/driver/max9296.ko
```

Expected: all syntax checks exit 0 and vermagic begins with
`5.10.35-lts-5.10.y+g2fce14defc04`.

- [ ] **Step 3: Build the handoff DEB**

Run:

```bash
python3 tools/build_handoff_deb.py
```

Expected: output reports the exact DEB path and a 64-character SHA-256; the output directory contains
only the DEB at this point.

- [ ] **Step 4: Independently inspect the DEB metadata and required files**

Run:

```bash
dpkg-deb -f handover/pim-package-jhw-camera-vpu-20260831/pim-mp_0.6.3+jhw.camera1_arm64.deb Package Version Architecture
dpkg-deb -c handover/pim-package-jhw-camera-vpu-20260831/pim-mp_0.6.3+jhw.camera1_arm64.deb
```

Expected metadata lines: `pim-mp`, `0.6.3+jhw.camera1`, `arm64`. The file list must contain every
path listed in design section 5, including all four qualification tools and the 640x360 fragment.

- [ ] **Step 5: Record the DEB and component checksums**

Run `sha256sum` for the DEB and the eleven design-section-5 component paths. Save the exact output in
the execution log; these literal values feed Task 3 and the board comparison.

### Task 3: Self-Contained External Installation and Test Guide

**Files:**
- Create: `docs/handoff/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md`

**Interfaces:**
- Consumes: Task 2 exact DEB SHA-256 and component hashes.
- Produces: one Korean operator document with no personal repository URL.

- [ ] **Step 1: Write the guide with immutable identity and stop conditions**

The first page must state:

- DEB filename, exact SHA-256, package/version/architecture, supported OS/kernel.
- This is a test-board handoff, not GitLab integration or production rollout.
- Stop before installation on any environment mismatch, checksum mismatch, missing old DEB, or failed
  JSON backup.
- The package `postinst` changes system services/configuration as well as camera files.

- [ ] **Step 2: Add exact preflight, backup, install, and verification commands**

Use commands runnable directly on the target, without `rtk` and without repository access:

```bash
uname -m
uname -r
. /etc/os-release && printf '%s %s\n' "$ID" "$VERSION_ID"
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
sha256sum ./pim-mp_0.6.3+jhw.camera1_arm64.deb

install -d -m 0700 /root/pim-handoff-backup-20260831
cp -a /root/shared_v/edgeconf*.json /root/pim-handoff-backup-20260831/
cp -a /root/shared_v/ord_vcm_conf.json /root/pim-handoff-backup-20260831/
cp -a /etc/defaultconf.json /root/pim-handoff-backup-20260831/

dpkg -i ./pim-mp_0.6.3+jhw.camera1_arm64.deb
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
depmod -a
ldconfig
modinfo -F vermagic max9296
```

Document that the installer runs `update_edgeconf.sh`; it backfills missing crop/VPU keys while
preserving existing non-null values.

- [ ] **Step 3: Add resolution, crop, VPU, gstApp, and green-frame explanations**

Include the exact resolution table and crop/VPU ranges from the design. Explicitly state:

- `dz=100/150/200` means 1.0x/1.5x/2.0x, not output resolution.
- `crop_enable=false` means no crop register writes.
- Runtime center/factor changes require the stream to have been prepared with crop enabled.
- Changing `crop_enable` requires stop/reconfigure and `cam_hard_reset.sh` or `init_cam.sh`.
- capture `RGBP` is RGB565 while the media-bus is UYVY; select the matching checker.
- VPU arrays contain exactly `[record, rtsp]`; single encoder mirrors record to RTSP.
- 120 FPS is not an acceptance target.

- [ ] **Step 4: Add exact test cases and result form**

For A, B, E, and H, include jq transformations from the current live JSON, hard reset, media format,
FPS, resource, gstApp log, RTSP/record decode, and RGB565 checks. Each transformation writes a new
file and atomically renames it only after `jq empty` succeeds.

The result table must have columns: case, channels, requested output/FPS, actual media output,
sensor/ISP/CSI/ISI FPS, crop state/factor/center, RTSP decode, green-frame result, CPU/RSS/DDR/temp,
dmesg errors, pass/fail, and evidence path.

- [ ] **Step 5: Add exact rollback steps**

Specify service stop, old DEB reinstall, JSON restore, `depmod`, `ldconfig`, reboot/hard reset, and
post-rollback checks. Do not claim rollback is possible when the previous DEB was not retained.

- [ ] **Step 6: Validate and commit the guide**

Run:

```bash
rg -n 'github\.com|jhw7500|git clone' docs/handoff/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md
git diff --check
```

Expected: the repository/private-account scan returns no matches and `git diff --check` exits 0.

Commit:

```bash
git add docs/handoff/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md
git commit -m "docs: add camera VPU deb handoff guide"
```

### Task 4: Reserved Target Installation and Qualification

**Files:**
- Target backup: `/root/camtest/handoff-camera1-20260831/preinstall/`
- Target evidence: `/root/camtest/handoff-camera1-20260831/evidence/`
- Target DEB: `/root/camtest/handoff-camera1-20260831/pim-mp_0.6.3+jhw.camera1_arm64.deb`

**Interfaces:**
- Consumes: Task 2 DEB, Task 3 procedures, target `pim-camera-v016` at `192.168.214.4`.
- Produces: installation and A/B/E/H qualification evidence, followed by restored agreed final config.

- [ ] **Step 1: Reserve the board and run read-only preflight**

Use the JHW board reservation workflow before SSH. Verify no conflicting holder, reserve
`pim-camera-v016`, and stop if the reservation or exact environment check fails.

Collect `uname -a`, `/etc/os-release`, installed `pim-mp`, current config checksums, active camera
services, module hashes, gstApp hash, and free space into the preinstall evidence directory.

- [ ] **Step 2: Back up rollback inputs before transfer/install**

Create the fixed target paths above, copy current edgeconf/ord/defaultconf, and copy or identify the
previous installable DEB. If the previous DEB cannot be recovered, do not install.

- [ ] **Step 3: Transfer and verify the DEB**

Copy the DEB to the fixed target path, run `sha256sum` remotely, and require an exact match with Task 2.
Record `dpkg-deb -f` output before installation.

- [ ] **Step 4: Install and validate package identity**

Stop the camera service in the documented manner, run `dpkg -i`, and capture complete stdout/stderr and
journal/dmesg deltas. Require:

```text
pim-mp 0.6.3+jhw.camera1 arm64
```

Compare installed hashes for all eleven key files with Task 2 and verify `max9296.ko` vermagic.

- [ ] **Step 5: Execute case A — ch0 only, 640x360@30, crop off**

Preserve a case-specific JSON, set only ch0 enabled, select 640x360@30, set `crop_enable=false` and
`dz=100`, then hard-reset. Capture prepare result, media graph, actual V4L2 format, FPS stack, gstApp
logs, one decoded stream/frame, RGB565 check, resources, and dmesg delta.

- [ ] **Step 6: Execute case B — ch0+ch1, 640x360@30, crop off**

Enable ch0/ch1 only and repeat the evidence set. Require dual-wide `1280x360` at the capture node and
valid output for both logical channels.

- [ ] **Step 7: Execute case E — ch0+ch1, 1280x720@30, crop 1.5x**

Select HD, set `crop_enable=true`, `dz=150`, centered coordinates `32768/32768`, and hard-reset. Require
HD output dimensions to remain unchanged while the visible field of view is enlarged. Change one
channel center at runtime, verify the control succeeds and output dimensions remain HD, then restore
the center.

- [ ] **Step 8: Execute case H — VPU contract**

Use two-element arrays, verify default `gop=0` resolves to the active FPS, set one safe non-default
record/RTSP configuration, and confirm gstApp logs/encoder properties. In single-encoder mode verify
the effective RTSP slot mirrors the record slot.

- [ ] **Step 9: Restore the agreed production config and release the board**

Restore `640x360@30`, ch0/ch1 enabled, ch2/ch3 disabled, crop off, `dz=100`, centered coordinates;
hard-reset and rerun the B-case smoke checks. Release the JHW board reservation even if a test fails.

### Task 5: Final Document Evidence and Two-File Delivery Directory

**Files:**
- Modify: `docs/handoff/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md`
- Generate: `handover/pim-package-jhw-camera-vpu-20260831/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md`

**Interfaces:**
- Consumes: Task 4 actual target results and final DEB checksum.
- Produces: exactly two external files with internally consistent identity and tested procedures.

- [ ] **Step 1: Incorporate actual qualification results**

Record the tested board environment, cases, actual FPS/resource values, green-frame outcome, evidence
path, known limitations, and the restored final configuration. Clearly separate observed evidence from
interpretation.

- [ ] **Step 2: Re-run all local gates**

Run:

```bash
python3 test/tools/build_handoff_deb_test.py
python3 tools/verify_binaries.py --strict
python3 test/camera_health/max9296_package_config_test.py
python3 test/camera_health/max9296_package_tools_test.py
python3 test/camera_health/package_executable_test.py
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 3: Commit final evidence updates**

```bash
git add docs/handoff/PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md
git commit -m "docs: record camera VPU handoff qualification"
```

- [ ] **Step 4: Copy the reviewed guide and audit deliverable count**

Copy the tracked guide to the ignored handover directory, then list regular files at depth one. Require
exactly these two names and no others:

```text
PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md
pim-mp_0.6.3+jhw.camera1_arm64.deb
```

- [ ] **Step 5: Final independent verification**

Verify the DEB SHA-256 against the guide, `dpkg-deb -f` metadata, guide private-account scan, clean
worktree, and local commit list. Do not push or publish; report the absolute local delivery directory
to the user.
