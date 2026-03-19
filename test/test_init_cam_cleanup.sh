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

# --- 함수 정의 (init_cam.sh에서 발췌) ---
cleanup_recording_orphans() {
    local dir="${1%/}"
    [ -d "$dir" ] || return 0
    local count=0
    local f
    for f in "$dir"/*.mp4 "$dir"/*.ts "$dir"/*.srt \
             "$dir"/*.mp4.part "$dir"/*.ts.part "$dir"/*.srt.part; do
        [ -f "$f" ] || continue
        rm -f "$f"
        count=$((count + 1))
    done
    rm -f /tmp/session_*.video_done /tmp/session_*.srt_done 2>/dev/null
    if [ $count -gt 0 ]; then
        echo "  cleaned=$count"
    else
        echo "  cleaned=0"
    fi
}

# --- Test 1: 녹화 확장자 파일 삭제 ---
echo "Test 1: Recording orphan cleanup"
touch "$TEST_TMP/VD3001_20260224_120000-ch0.mp4"
touch "$TEST_TMP/VD3001_20260224_120000-ch1.mp4.part"
touch "$TEST_TMP/VD3001_20260224_120000-data.srt"
touch "$TEST_TMP/VD3001_20260224_120000-ch0.ts"
touch "$TEST_TMP/VD3001_20260224_120000-ch1.ts.part"
touch "$TEST_TMP/VD3001_20260224_120000-data.srt.part"
cleanup_recording_orphans "$TEST_TMP"
remaining=$(ls "$TEST_TMP" 2>/dev/null | wc -l)
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

# --- Test 3: 세션 플래그 정리 ---
echo "Test 3: Session flags cleanup"
touch /tmp/session_20260224_1200.video_done
touch /tmp/session_20260224_1200.srt_done
cleanup_recording_orphans "$TEST_TMP"
if [ ! -f /tmp/session_20260224_1200.video_done ] && \
   [ ! -f /tmp/session_20260224_1200.srt_done ]; then
    echo "  PASS: Session flags cleaned"
else
    echo "  FAIL: Session flags remain"
    exit 1
fi

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
