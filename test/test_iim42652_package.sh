#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREPARE="$ROOT/dist/pim/opt/pim/bin/iim42652_prepare_modules.sh"
CONTROL="$ROOT/dist/pim/opt/pim/bin/iim42652_module.sh"
KREL="5.10.35-lts-5.10.y+g2fce14defc04"
DRIVER_DIR="$ROOT/dist/pim/lib/modules/$KREL/updates/pim-iim42652"
DTB="$ROOT/dist/pim/opt/pim/boot/imx8mp-evk-iim42652.dtb"

TMPDIR_IIM=$(mktemp -d)
trap 'rm -rf "$TMPDIR_IIM"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

echo "Test 1: package contains the manual IIM-42652 control surface"
assert_file "$PREPARE"
assert_file "$CONTROL"
assert_file "$ROOT/dist/pim/etc/modprobe.d/iim42652-manual.conf"

echo "Test 2: package-owned module set is verified before depmod without loading"
FAKE_ROOT="$TMPDIR_IIM/modules"
FAKE_MODULE_DIR="$FAKE_ROOT/$KREL/updates/pim-iim42652"
FAKE_BIN="$TMPDIR_IIM/bin"
LOG="$TMPDIR_IIM/commands.log"
mkdir -p "$FAKE_MODULE_DIR" "$FAKE_BIN"
for module in inv-icm42600.ko inv-icm42600-i2c.ko inv_sensors_timestamp.ko; do
    printf 'fixture:%s\n' "$module" > "$FAKE_MODULE_DIR/$module"
done

cat > "$FAKE_BIN/modinfo" <<'EOF'
#!/bin/sh
printf '%s SMP preempt mod_unload modversions aarch64\n' "$IIM_KERNEL_RELEASE"
EOF
cat > "$FAKE_BIN/depmod" <<'EOF'
#!/bin/sh
printf 'depmod %s\n' "$*" >> "$IIM_TEST_LOG"
EOF
cat > "$FAKE_BIN/modprobe" <<'EOF'
#!/bin/sh
printf 'modprobe %s\n' "$*" >> "$IIM_TEST_LOG"
EOF
cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "$IIM_TEST_UNAME"
EOF
chmod +x "$FAKE_BIN/modinfo" "$FAKE_BIN/depmod" "$FAKE_BIN/modprobe" "$FAKE_BIN/uname"

IIM_MODULE_ROOT="$FAKE_ROOT" \
IIM_KERNEL_RELEASE="$KREL" \
IIM_MODINFO="$FAKE_BIN/modinfo" \
IIM_DEPMOD="$FAKE_BIN/depmod" \
IIM_TEST_LOG="$LOG" \
    "$PREPARE"

assert_file "$FAKE_MODULE_DIR/inv-icm42600.ko"
assert_file "$FAKE_MODULE_DIR/inv-icm42600-i2c.ko"
assert_file "$FAKE_MODULE_DIR/inv_sensors_timestamp.ko"
grep -Fxq "depmod -a $KREL" "$LOG" || fail "depmod was not run for $KREL"
if grep -q '^modprobe ' "$LOG"; then
    fail "installer must not load IIM modules"
fi

cat > "$FAKE_BIN/modinfo-fixed" <<EOF
#!/bin/sh
printf '%s SMP preempt mod_unload modversions aarch64\\n' '$KREL'
EOF
chmod +x "$FAKE_BIN/modinfo-fixed"
: > "$LOG"
PATH="$FAKE_BIN:$PATH" IIM_TEST_UNAME="5.10.35-wrong" \
IIM_MODULE_ROOT="$FAKE_ROOT" IIM_MODINFO="$FAKE_BIN/modinfo-fixed" \
IIM_DEPMOD="$FAKE_BIN/depmod" IIM_TEST_LOG="$LOG" "$PREPARE" >/dev/null \
    || fail "package preparation incorrectly depended on the running kernel"
grep -Fxq "depmod -a $KREL" "$LOG" \
    || fail "package preparation did not index the fixed target kernel"

echo "Test 3: package preparation rejects modules built for a different kernel"
cat > "$FAKE_BIN/modinfo-wrong" <<'EOF'
#!/bin/sh
printf '5.10.35-wrong SMP preempt mod_unload modversions aarch64\n'
EOF
chmod +x "$FAKE_BIN/modinfo-wrong"
if IIM_MODULE_ROOT="$FAKE_ROOT" \
   IIM_KERNEL_RELEASE="$KREL" \
   IIM_MODINFO="$FAKE_BIN/modinfo-wrong" \
   IIM_DEPMOD="$FAKE_BIN/depmod" \
   IIM_TEST_LOG="$LOG" \
       "$PREPARE" >/dev/null 2>&1; then
    fail "package preparation accepted a mismatched vermagic"
fi

cat > "$FAKE_BIN/modinfo-prefix" <<'EOF'
#!/bin/sh
printf '%s-other SMP preempt mod_unload modversions aarch64\n' "$IIM_KERNEL_RELEASE"
EOF
chmod +x "$FAKE_BIN/modinfo-prefix"
if IIM_MODULE_ROOT="$FAKE_ROOT" \
   IIM_KERNEL_RELEASE="$KREL" \
   IIM_MODINFO="$FAKE_BIN/modinfo-prefix" \
   IIM_DEPMOD="$FAKE_BIN/depmod" \
   IIM_TEST_LOG="$LOG" \
       "$PREPARE" >/dev/null 2>&1; then
    fail "package preparation accepted a release that only shares the expected prefix"
fi

echo "Test 4: manual controller loads and unloads the transport explicitly"
: > "$LOG"
PATH="$FAKE_BIN:$PATH" IIM_TEST_LOG="$LOG" IIM_TEST_UNAME="$KREL" "$CONTROL" load
PATH="$FAKE_BIN:$PATH" IIM_TEST_LOG="$LOG" IIM_TEST_UNAME="$KREL" "$CONTROL" unload
grep -Fxq 'modprobe inv-icm42600-i2c' "$LOG" || fail "manual load command missing"
grep -Fxq 'modprobe -r inv-icm42600-i2c inv-icm42600 inv_sensors_timestamp' "$LOG" \
    || fail "manual unload command missing or out of order"
if PATH="$FAKE_BIN:$PATH" IIM_TEST_LOG="$LOG" IIM_TEST_UNAME="5.10.35-wrong" \
       "$CONTROL" load >/dev/null 2>&1; then
    fail "manual controller loaded modules on the wrong running kernel"
fi

echo "Test 5: modprobe configuration suppresses alias-based autoload"
modprobe -C "$ROOT/dist/pim/etc/modprobe.d" --showconfig \
    | grep -Fx 'blacklist inv_icm42600_i2c' >/dev/null \
    || fail "inv_icm42600_i2c alias blacklist is not active"

echo "Test 6: packaged production artifacts match the target kernel and DT contract"
for module in inv-icm42600.ko inv-icm42600-i2c.ko inv_sensors_timestamp.ko; do
    path="$DRIVER_DIR/$module"
    assert_file "$path"
    vermagic=$(modinfo -F vermagic "$path")
    case "$vermagic" in
        "$KREL "*) ;;
        *) fail "$module vermagic mismatch: $vermagic" ;;
    esac
done
assert_file "$DTB"
[ "$(fdtget -t s "$DTB" /soc@0/bus@30800000/i2c@30ad0000/imu@68 compatible)" \
    = "invensense,iim42652" ] || fail "DT compatible mismatch"
[ "$(fdtget -t u "$DTB" /soc@0/bus@30800000/i2c@30ad0000 clock-frequency)" \
    = "400000" ] || fail "I2C5 clock-frequency mismatch"

echo "Test 7: package binary manifest covers the new artifacts"
python3 - "$ROOT/.github/binary-manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
actual = {entry["path"] for entry in manifest["binaries"]}
required = {
    "dist/pim/lib/modules/5.10.35-lts-5.10.y+g2fce14defc04/updates/pim-iim42652/inv-icm42600.ko",
    "dist/pim/lib/modules/5.10.35-lts-5.10.y+g2fce14defc04/updates/pim-iim42652/inv-icm42600-i2c.ko",
    "dist/pim/lib/modules/5.10.35-lts-5.10.y+g2fce14defc04/updates/pim-iim42652/inv_sensors_timestamp.ko",
    "dist/pim/opt/pim/boot/imx8mp-evk-iim42652.dtb",
}
missing = required - actual
if missing:
    raise SystemExit("manifest entries missing: " + ", ".join(sorted(missing)))
PY
python3 "$ROOT/tools/verify_binaries.py" --strict >/dev/null \
    || fail "binary manifest does not match the package artifacts"

echo "Test 8: freshly built Debian package owns every IIM artifact"
DEB="$TMPDIR_IIM/pim-iim42652.deb"
dpkg-deb --root-owner-group --build "$ROOT/dist/pim" "$DEB" >/dev/null
CONTENTS=$(dpkg-deb -c "$DEB")
for packaged_path in \
    "./etc/modprobe.d/iim42652-manual.conf" \
    "./opt/pim/bin/iim42652_prepare_modules.sh" \
    "./opt/pim/bin/iim42652_module.sh" \
    "./opt/pim/boot/imx8mp-evk-iim42652.dtb" \
    "./lib/modules/$KREL/updates/pim-iim42652/inv-icm42600.ko" \
    "./lib/modules/$KREL/updates/pim-iim42652/inv-icm42600-i2c.ko" \
    "./lib/modules/$KREL/updates/pim-iim42652/inv_sensors_timestamp.ko"; do
    case "$CONTENTS" in
        *"$packaged_path"*) ;;
        *) fail "Debian package is missing $packaged_path" ;;
    esac
done

echo "Test 9: package removal lifecycle refreshes module dependencies"
CONTROL_DIR="$TMPDIR_IIM/control"
mkdir -p "$CONTROL_DIR"
dpkg-deb -e "$DEB" "$CONTROL_DIR"
sed 's|^\. /usr/share/debconf/confmodule$|db_get() { RET=test; }|' \
    "$CONTROL_DIR/postrm" > "$TMPDIR_IIM/postrm-test"
chmod +x "$TMPDIR_IIM/postrm-test"
: > "$LOG"
PATH="$FAKE_BIN:$PATH" IIM_TEST_LOG="$LOG" IIM_MODULE_ROOT="$FAKE_ROOT" \
IIM_DEPMOD="$FAKE_BIN/depmod" "$TMPDIR_IIM/postrm-test" upgrade >/dev/null
grep -Fxq "depmod -a $KREL" "$LOG" \
    || fail "postrm upgrade did not refresh dependencies after dpkg removed old modules"

cat > "$FAKE_BIN/depmod-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKE_BIN/depmod-fail"
if ! PATH="$FAKE_BIN:$PATH" IIM_MODULE_ROOT="$FAKE_ROOT" \
     IIM_DEPMOD="$FAKE_BIN/depmod-fail" "$TMPDIR_IIM/postrm-test" upgrade \
     >"$TMPDIR_IIM/postrm-fail.out" 2>"$TMPDIR_IIM/postrm-fail.err"; then
    fail "postrm must keep depmod failure non-fatal"
fi
grep -Fq "WARNING: depmod failed for IIM-42652 kernel $KREL" \
    "$TMPDIR_IIM/postrm-fail.err" \
    || fail "postrm did not report a non-fatal depmod failure"

echo "PASS: IIM-42652 package integration"
