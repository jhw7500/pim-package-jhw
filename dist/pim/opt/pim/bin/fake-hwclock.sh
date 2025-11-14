#!/bin/bash
tag=$(basename "$0")
KEY=RTC
set -eu

logger -p local0.info "[$KEY][$tag:$LINENO] $1"
STATE_FILE="/etc/fake-hwclock.data"

case "$1" in
  load)
    for i in {1..5}; do
        if [ -e /sys/class/rtc/rtc0/name ] && grep -qi 'ds1307' /sys/class/rtc/rtc0/name; then
            if hwclock --hctosys 2>/dev/null; then
                logger -p local0.notice "[$KEY][$tag:$LINENO] Restored time from DS1307 (hwclock)."
                exit 0
            fi
        fi
    sleep 2
    done

    if [ -f "$STATE_FILE" ]; then
        DATE_STR="$(cat "$STATE_FILE")"
        if [ -n "$DATE_STR" ]; then
            date -s "$DATE_STR" >/dev/null 2>&1 || true
            logger -p local0.emerg "[$KEY][$tag:$LINENO] Restored time from fake-hwclock ($STATE_FILE)."
            exit 0
        fi
    fi

    date -s "2025-01-01 00:00:00" >/dev/null 2>&1 || true
    logger -p local0.emerg "[$KEY][$tag:$LINENO] Fallback to safe epoch."
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
