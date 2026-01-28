#!/bin/bash
tag=$(basename "$0")
KEY=RTC
set -u

# logger -p local0.info "[$KEY][$tag:$LINENO] $1"
STATE_FILE="/etc/fake-hwclock.data"

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

    # 2. Read RTC Time
    RTC_TS=0
    RTC_STR=""
    if RTC_STR=$(hwclock -r 2>/dev/null); then
        RTC_TS=$(date -d "$RTC_STR" +%s 2>/dev/null || echo 0)
    else
        logger -p local0.err "[$KEY][$tag:$LINENO] Failed to read RTC (hwclock -r failed)"
    fi

    # 3. Compare and Restore
    # If RTC is invalid(0) or older than Fake-HWClock, restore from File
    if [ "$RTC_TS" -lt "$FILE_TS" ]; then
        if [ "$FILE_TS" -gt 0 ]; then
            logger -p local0.emerg "[$KEY][$tag:$LINENO] RTC($RTC_STR) is older/invalid. Restoring from fake-hwclock ($FILE_STR)"
            date -s "$FILE_STR" >/dev/null 2>&1
            
            # Critical: Resurrect RTC with restored system time
            if hwclock -w 2>/dev/null; then
                logger -p local0.notice "[$KEY][$tag:$LINENO] Resurrected RTC with system time."
            else
                logger -p local0.err "[$KEY][$tag:$LINENO] Failed to write to RTC (hwclock -w)."
            fi
            exit 0
        fi
    else
        # RTC is newer or equal. Trust RTC.
        # Kernel usually syncs RTC on boot, but we can log it.
        # logger -p local0.info "[$KEY][$tag:$LINENO] RTC time ($RTC_STR) is valid."
        exit 0
    fi

    # 4. Fallback if both invalid
    # If we are here, RTC < File AND File is invalid(0) -> Both invalid?
    # Or simply File is missing.
    # Check current system time (maybe network synced or kernel default)
    SYS_TS=$(date +%s)
    
    # If system time is suspiciously old (e.g. < 2025), enforce safe epoch
    # Assuming build/release date 2025-01-01 as safe baseline
    SAFE_EPOCH_STR="2025-01-01 00:00:00"
    SAFE_EPOCH_TS=$(date -d "$SAFE_EPOCH_STR" +%s)

    if [ "$SYS_TS" -lt "$SAFE_EPOCH_TS" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] System time too old ($SYS_TS). Fallback to safe epoch ($SAFE_EPOCH_STR)."
        date -s "$SAFE_EPOCH_STR" >/dev/null 2>&1
        hwclock -w 2>/dev/null || true
    fi
    exit 0
    ;;
  save)
    date "+%Y-%m-%d %H:%M:%S" > "$STATE_FILE".tmp
    mv -f "$STATE_FILE".tmp "$STATE_FILE"
    chmod 0644 "$STATE_FILE"
    logger -p local0.info "[$KEY][$tag:$LINENO] Saved time to $STATE_FILE"
    ;;
  *)
    echo "Usage: fake-hwclock {save|load}"
    exit 1
    ;;
esac