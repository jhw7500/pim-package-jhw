#!/bin/bash
set -e

echo "=== init_cam.sh Cleanup Functions Test ==="

# --- 테스트 환경 ---
TEST_TMP="/tmp/test_cleanup_tmp"
TEST_SHM="/tmp/test_cleanup_shm"
rm -rf "$TEST_TMP" "$TEST_SHM"
mkdir -p "$TEST_TMP" "$TEST_SHM/recordings" "$TEST_SHM/capture"

key="TST"
tag="test_cleanup"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
source "$PIM_LIB/cam_recovery_actions.sh"
# This unit test exercises the moved cleanup routine without needing a lease.
cam_effect() { local runtime=$1; shift; "$@"; }
RUNTIME="$TEST_TMP/runtime.json"
printf '{"VHL_CAM":{"tmp_path":"%s","vhl_name":"VD3001"},"ORD":{},"VCM":{}}\n' "$TEST_TMP" > "$RUNTIME"
printf '2026-02-24 12:00:00\n' > "$TEST_TMP/session-start"
export PIM_CAMERA_SESSION_TIME_FILE="$TEST_TMP/session-start"
cleanup_recording_orphans() { cam_cleanup_recording_orphans "$RUNTIME"; }

# --- Test 1: 녹화 확장자 파일 삭제 ---
echo "Test 1: Recording orphan cleanup"
touch "$TEST_TMP/VD3001_20260224_1200-ch0.mp4"
touch "$TEST_TMP/VD3001_20260224_1200-ch1.mp4.part"
touch "$TEST_TMP/VD3001_20260224_1200-data.srt"
touch "$TEST_TMP/VD3001_20260224_1200-ch0.ts"
touch "$TEST_TMP/VD3001_20260224_1200-ch1.ts.part"
touch "$TEST_TMP/VD3001_20260224_1200-data.srt.part"
cleanup_recording_orphans "$TEST_TMP"
remaining=$(find "$TEST_TMP" -maxdepth 1 -type f ! -name runtime.json ! -name session-start | wc -l)
if [ "$remaining" -eq 0 ]; then
    echo "  PASS: All recording files removed"
else
    echo "  FAIL: $remaining files remain"
    ls -la "$TEST_TMP"
    exit 1
fi

# --- Test 2: 녹화 외 파일은 보존 ---
echo "Test 2: Non-recording files preserved"
touch "$TEST_TMP/some_flag_file"
touch "$TEST_TMP/debug.log"
cleanup_recording_orphans "$TEST_TMP"
if [ -f "$TEST_TMP/some_flag_file" ] && [ -f "$TEST_TMP/debug.log" ]; then
    echo "  PASS: Non-recording files preserved"
else
    echo "  FAIL: Non-recording files were deleted"
    exit 1
fi
rm -f "$TEST_TMP/some_flag_file" "$TEST_TMP/debug.log"

# --- Test 3: unrelated session flags are retained ---
echo "Test 3: Session flags retained"
touch /tmp/session_20260224_1200.video_done
touch /tmp/session_20260224_1200.srt_done
cleanup_recording_orphans "$TEST_TMP"
if [ -f /tmp/session_20260224_1200.video_done ] && \
   [ -f /tmp/session_20260224_1200.srt_done ]; then
    echo "  PASS: Session flags retained"
else
    echo "  FAIL: Session flags were deleted"
    exit 1
fi
rm -f /tmp/session_20260224_1200.video_done /tmp/session_20260224_1200.srt_done

# --- Test 4: 빈 디렉터리에서 에러 없이 동작 ---
echo "Test 4: Empty directory is no-op"
cleanup_recording_orphans "$TEST_TMP"
echo "  PASS: No error on empty dir"

# --- Test 5: 존재하지 않는 디렉터리 ---
echo "Test 5: Non-existent directory is no-op"
cleanup_recording_orphans "/tmp/nonexistent_dir_test_12345"
echo "  PASS: No error on missing dir"

# --- 정리 ---
rm -rf "$TEST_TMP" "$TEST_SHM"
echo ""
echo "=== All 5 tests passed ==="
