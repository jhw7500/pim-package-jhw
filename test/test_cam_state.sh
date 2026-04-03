#!/bin/bash
set -e

echo "=== Camera State System Integration Test ==="

rm -rf /tmp/cam_state /tmp/cam_recovery.json /tmp/cam_op_lock

source /home/jhw/ai/opencode/projects/pim-package/dist/pim/opt/pim/lib/cam_state.sh

echo "Test 1: State initialization"
cam_state_init
if [ -d /tmp/cam_state ]; then
    echo "  PASS: State directory created"
else
    echo "  FAIL: State directory not created"
    exit 1
fi

echo "Test 2: Initial state"
state=$(cam_get_state)
if [ "$state" = "healthy" ]; then
    echo "  PASS: Initial state is healthy"
else
    echo "  FAIL: Initial state is $state, expected healthy"
    exit 1
fi

echo "Test 3: Streak increment"
cam_inc_streak
streak=$(cam_state_get streak)
if [ "$streak" -eq 1 ]; then
    echo "  PASS: Streak incremented to 1"
else
    echo "  FAIL: Streak is $streak, expected 1"
    exit 1
fi

echo "Test 4: State transition to degraded"
cam_inc_streak
state=$(cam_get_state)
streak=$(cam_state_get streak)
if [ "$state" = "degraded" ] && [ "$streak" -eq 2 ]; then
    echo "  PASS: State transitioned to degraded after streak >= 2"
else
    echo "  FAIL: State is $state, streak is $streak"
    exit 1
fi

echo "Test 5: Streak reset"
cam_reset_streak
state=$(cam_get_state)
streak=$(cam_state_get streak)
if [ "$state" = "healthy" ] && [ "$streak" -eq 0 ]; then
    echo "  PASS: Streak reset, state back to healthy"
else
    echo "  FAIL: State is $state, streak is $streak"
    exit 1
fi

echo "Test 6: Channel error recording"
cam_channel_error 0
cam_channel_error 2
ch0_error=$(cam_state_get channels/ch0_error)
ch1_error=$(cam_state_get channels/ch1_error)
ch2_error=$(cam_state_get channels/ch2_error)
if [ "$ch0_error" = "true" ] && [ "$ch1_error" = "false" ] && [ "$ch2_error" = "true" ]; then
    echo "  PASS: Channel errors recorded correctly"
else
    echo "  FAIL: ch0=$ch0_error, ch1=$ch1_error, ch2=$ch2_error"
    exit 1
fi

echo "Test 7: Has channel error check"
if cam_has_channel_error; then
    echo "  PASS: cam_has_channel_error returns true"
else
    echo "  FAIL: cam_has_channel_error should return true"
    exit 1
fi

echo "Test 8: Channel clear"
cam_channel_clear 0
ch0_error=$(cam_state_get channels/ch0_error)
if [ "$ch0_error" = "false" ]; then
    echo "  PASS: Channel 0 error cleared"
else
    echo "  FAIL: ch0 error is $ch0_error, expected false"
    exit 1
fi

echo "Test 9: Recovery request"
cam_request_recovery "test_recovery"
if cam_recovery_requested; then
    reason=$(cam_recovery_reason)
    if [ "$reason" = "test_recovery" ]; then
        echo "  PASS: Recovery request recorded with correct reason"
    else
        echo "  FAIL: Recovery reason is $reason, expected test_recovery"
        exit 1
    fi
else
    echo "  FAIL: Recovery request not found"
    exit 1
fi

echo "Test 10: Recovery attempt increment"
cam_inc_recovery_attempt
attempts=$(jq -r '.attempts' /tmp/cam_recovery.json)
if [ "$attempts" -eq 1 ]; then
    echo "  PASS: Recovery attempt incremented to 1"
else
    echo "  FAIL: Attempts is $attempts, expected 1"
    exit 1
fi

echo "Test 11: Recovery exhausted check"
jq '.attempts = 5' /tmp/cam_recovery.json > /tmp/cam_recovery.json.tmp && mv /tmp/cam_recovery.json.tmp /tmp/cam_recovery.json
if cam_recovery_exhausted; then
    echo "  PASS: cam_recovery_exhausted returns true at max attempts"
else
    echo "  FAIL: cam_recovery_exhausted should return true"
    exit 1
fi

echo "Test 12: Clear recovery"
cam_clear_recovery
if ! cam_recovery_requested; then
    echo "  PASS: Recovery request cleared"
else
    echo "  FAIL: Recovery request still exists"
    exit 1
fi

echo "Test 13: Lock acquisition"
if cam_lock "test_op"; then
    echo "  PASS: Lock acquired"
else
    echo "  FAIL: Could not acquire lock"
    exit 1
fi

echo "Test 14: Lock protection (second lock should fail)"
if ! cam_lock "other_op"; then
    echo "  PASS: Second lock correctly rejected"
else
    echo "  FAIL: Second lock should have been rejected"
    exit 1
fi

echo "Test 15: Lock release"
cam_unlock
if cam_lock "another_op"; then
    echo "  PASS: Lock released, can acquire new lock"
    cam_unlock
else
    echo "  FAIL: Could not acquire lock after release"
    exit 1
fi

echo "Test 16: Record init"
cam_record_init
state=$(cam_get_state)
init_ts=$(cam_state_get last_init_ts)
if [ "$state" = "recovering" ] && [ "$init_ts" -gt 0 ]; then
    echo "  PASS: Init recorded with state recovering"
else
    echo "  FAIL: State=$state, init_ts=$init_ts"
    exit 1
fi

echo "Test 17: Record start"
sleep 1
cam_record_start
start_ts=$(cam_state_get last_start_ts)
if [ "$start_ts" -gt "$init_ts" ]; then
    echo "  PASS: Start recorded with newer timestamp"
else
    echo "  FAIL: start_ts=$start_ts should be greater than init_ts=$init_ts"
    exit 1
fi

echo "Test 18: Cooldown check"
if cam_in_init_cooldown 40; then
    echo "  PASS: cam_in_init_cooldown returns true (within cooldown)"
else
    echo "  FAIL: cam_in_init_cooldown should return true"
    exit 1
fi

echo "Test 19: Full state reset"
cam_reset_state
state=$(cam_get_state)
streak=$(cam_state_get streak)
if [ "$state" = "healthy" ] && [ "$streak" -eq 0 ]; then
    echo "  PASS: State fully reset to healthy"
else
    echo "  FAIL: State=$state, streak=$streak"
    exit 1
fi

echo "Test 20: Startup grace check"
if cam_in_startup_grace 10; then
    echo "  PASS: cam_in_startup_grace returns true (within grace)"
else
    echo "  FAIL: cam_in_startup_grace should return true"
    exit 1
fi

echo ""
echo "=== All 20 tests passed ==="
