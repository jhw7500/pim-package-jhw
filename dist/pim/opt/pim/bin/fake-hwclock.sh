#!/bin/bash
set -Eeuo pipefail

tag=$(basename "$0")
KEY=RTC

# logger -p local0.info "[$KEY][$tag:$LINENO] $1"
STATE_FILE="/etc/fake-hwclock.data"

# RTC retry configuration
RTC_MAX_RETRIES=3
RTC_RETRY_DELAY=1  # seconds

# Kernel log option (set LOG_TO_KERNEL=1 to enable dual logging)
LOG_TO_KERNEL="${LOG_TO_KERNEL:-0}"

# Custom logger function: logs to syslog and optionally to kernel log
log_msg() {
    local level="$1"
    shift
    local message="$*"

    # Always log to syslog
    logger -p "local0.$level" "$message"

    # Optionally log to kernel log (/dev/kmsg)
    if [[ "$LOG_TO_KERNEL" == "1" ]] && [[ -w /dev/kmsg ]]; then
        # Map syslog levels to kernel log levels
        local kern_level=5  # default: KERN_INFO
        case "$level" in
            emerg)          kern_level=0 ;;  # KERN_EMERG
            alert)          kern_level=1 ;;  # KERN_ALERT
            crit)           kern_level=2 ;;  # KERN_CRIT
            err)            kern_level=3 ;;  # KERN_ERR
            warn|warning)   kern_level=4 ;;  # KERN_WARNING
            notice)         kern_level=5 ;;  # KERN_NOTICE
            info)           kern_level=6 ;;  # KERN_INFO
            debug)          kern_level=7 ;;  # KERN_DEBUG
        esac

        echo "<${kern_level}>[$KEY] $message" > /dev/kmsg 2>/dev/null || true
    fi
}

# Check if RTC driver is loaded and accessible
check_rtc_driver() {
    local rtc_device="/dev/rtc0"
    local log_level="${1:-err}"  # Allow caller to specify log level (default: err)
    local attempt="${2:-0}"      # Attempt number for logging

    # Check if /dev/rtc0 exists
    if [[ ! -e "$rtc_device" ]]; then
        if [[ $attempt -gt 0 ]]; then
            log_msg "$log_level" "[$KEY][$tag:$LINENO] RTC device not found (attempt $attempt): $rtc_device"
        else
            log_msg "$log_level" "[$KEY][$tag:$LINENO] RTC device not found: $rtc_device"
        fi
        return 1
    fi

    # Check if device is readable
    if [[ ! -r "$rtc_device" ]]; then
        log_msg "$log_level" "[$KEY][$tag:$LINENO] RTC device not readable: $rtc_device"
        return 1
    fi

    # Success
    if [[ $attempt -gt 0 ]]; then
        log_msg notice "[$KEY][$tag:$LINENO] RTC device found successfully (attempt $attempt)"
    fi

    return 0
}

# Read RTC with retries
read_rtc_with_retry() {
    local attempt=1
    local rtc_str=""

    while [[ $attempt -le $RTC_MAX_RETRIES ]]; do
        # Use 'warn' for early attempts (driver may still be loading)
        # Use 'err' only on final attempt
        local log_level="warn"
        if [[ $attempt -eq $RTC_MAX_RETRIES ]]; then
            log_level="err"
        fi

        # Check if RTC driver is available (may load during retries)
        if ! check_rtc_driver "$log_level" "$attempt"; then
            if [[ $attempt -lt $RTC_MAX_RETRIES ]]; then
                sleep "$RTC_RETRY_DELAY"
                ((attempt++))
                continue
            else
                log_msg err "[$KEY][$tag:$LINENO] RTC unavailable after $RTC_MAX_RETRIES attempts"
                return 1
            fi
        fi

        # Try to read RTC
        if rtc_str=$(hwclock -r 2>/dev/null); then
            log_msg notice "[$KEY][$tag:$LINENO] RTC read success: $rtc_str"
            echo "$rtc_str"
            return 0
        fi

        log_msg warn "[$KEY][$tag:$LINENO] hwclock read failed (attempt $attempt/$RTC_MAX_RETRIES)"

        if [[ $attempt -lt $RTC_MAX_RETRIES ]]; then
            sleep "$RTC_RETRY_DELAY"
        fi

        ((attempt++))
    done

    logger -p local0.err "[$KEY][$tag:$LINENO] RTC read failed after $RTC_MAX_RETRIES attempts"
    return 1
}

case "$1" in
  load)
    # 1. Read Fake-HWClock Time
    FILE_TS=0
    FILE_STR=""
    if [ -f "$STATE_FILE" ]; then
        FILE_STR="$(cat "$STATE_FILE")"
        if [ -n "$FILE_STR" ]; then
            FILE_TS=$(date -d "$FILE_STR" +%s 2>/dev/null || echo 0)
        fi
    fi

    # 2. Check RTC Driver and Read RTC Time
    RTC_TS=0
    RTC_STR=""

    # Try to read RTC with retries
    if RTC_STR=$(read_rtc_with_retry); then
        RTC_TS=$(date -d "$RTC_STR" +%s 2>/dev/null || echo 0)
        if [[ $RTC_TS -eq 0 ]]; then
            log_msg err "[$KEY][$tag:$LINENO] RTC timestamp parsing failed: '$RTC_STR'"
        fi
    else
        log_msg warn "[$KEY][$tag:$LINENO] RTC read failed completely"
    fi

    # Log available time sources
    log_msg notice "[$KEY][$tag:$LINENO] Time sources - RTC: $RTC_STR | Fake-HWClock: $FILE_STR"

    # 3. Compare and Restore
    # If RTC is invalid(0) or older than Fake-HWClock, restore from File
    if [ "$RTC_TS" -lt "$FILE_TS" ]; then
        if [ "$FILE_TS" -gt 0 ]; then
            log_msg emerg "[$KEY][$tag:$LINENO] Using fake-hwclock time (RTC unavailable or older)"
            date -s "$FILE_STR" >/dev/null 2>&1

            # Critical: Resurrect RTC with restored system time
            if hwclock -w 2>/dev/null; then
                NEW_RTC=$(hwclock -r 2>/dev/null || echo "read-failed")
                log_msg notice "[$KEY][$tag:$LINENO] RTC synchronized: $NEW_RTC"
            else
                log_msg err "[$KEY][$tag:$LINENO] Failed to write to RTC (hwclock -w)"
            fi
            exit 0
        fi
    else
        # RTC is newer or equal. Trust RTC.
        log_msg notice "[$KEY][$tag:$LINENO] Using RTC time (valid and current)"
        exit 0
    fi

    # 4. Fallback if both invalid
    # If we are here, RTC < File AND File is invalid(0) -> Both invalid?
    # Or simply File is missing.
    # Check current system time (maybe network synced or kernel default)
    SYS_TS=$(date +%s)
    SYS_STR=$(date "+%Y-%m-%d %H:%M:%S")

    # If system time is suspiciously old (e.g. < 2026), enforce safe epoch
    SAFE_EPOCH_STR="2026-01-01 00:00:00"
    SAFE_EPOCH_TS=$(date -d "$SAFE_EPOCH_STR" +%s)

    log_msg warn "[$KEY][$tag:$LINENO] Fallback: Both RTC and fake-hwclock invalid. Current: $SYS_STR"

    if [ "$SYS_TS" -lt "$SAFE_EPOCH_TS" ]; then
        log_msg emerg "[$KEY][$tag:$LINENO] Using safe epoch time: $SAFE_EPOCH_STR"
        date -s "$SAFE_EPOCH_STR" >/dev/null 2>&1
        hwclock -w 2>/dev/null || true
    else
        log_msg notice "[$KEY][$tag:$LINENO] Using current system time"
    fi
    exit 0
    ;;
  save)
    date "+%Y-%m-%d %H:%M:%S" > "$STATE_FILE".tmp
    mv -f "$STATE_FILE".tmp "$STATE_FILE"
    chmod 0644 "$STATE_FILE"
    log_msg info "[$KEY][$tag:$LINENO] Saved time to $STATE_FILE"
    ;;
  *)
    echo "Usage: fake-hwclock {save|load}"
    exit 1
    ;;
esac
