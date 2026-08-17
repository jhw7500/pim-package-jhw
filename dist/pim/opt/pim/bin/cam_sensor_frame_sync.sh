#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DMA_READ="${CAM_DMA_READ:-$SCRIPT_DIR/cam_dma_read.sh}"
UPTIME_PATH="${CAM_UPTIME_PATH:-/proc/uptime}"
FRAME_COUNT_REG=0x303a
MAX_SENSOR_FPS=${MAX_SENSOR_FPS:-120}
FRAME_STEP_MARGIN=${FRAME_STEP_MARGIN:-8}

show_help() {
    echo "Usage: $tag [channels] [interval_sec] [samples]"
    echo "  channels     : comma-separated channel list (default: 0,1,2,3)"
    echo "  interval_sec : delay between sweeps (default: 1)"
    echo "                 intervals are timed on /proc/uptime, whose resolution"
    echo "                 is 10 ms; keep this at or above 0.1 for a meaningful"
    echo "                 plausibility ceiling"
    echo "  samples      : number of sweeps including baseline, minimum 2 (default: 10)"
    echo
    echo "Reads AR0234 R0x303A FRAME_COUNT through the existing V4L2 DMA controls."
    echo "It reports the 16-bit raw counter, per-sweep advance, cumulative advance,"
    echo "and cumulative drift relative to the first requested channel."
    echo "Implausible modular advances are reported as RESET_OR_INVALID instead of"
    echo "being mistaken for a 65536-frame counter wrap. A run whose every read is"
    echo "0x0000 or 0xffff is also RESET_OR_INVALID: the register never answered,"
    echo "so it says nothing about whether the sensors produced frames."
    echo
    echo "Examples:"
    echo "  $tag                    # ch0..3, 1 second, 10 samples"
    echo "  $tag 0,1 0.5 20        # compare the two sensors on CSI0"
    echo "  $tag 0,1,2,3 2 30      # four-channel 60-second observation"
    echo
    echo "Environment:"
    echo "  MAX_SENSOR_FPS   plausibility ceiling (default: 120)"
    echo "  FRAME_STEP_MARGIN extra frames allowed per interval (default: 8)"
    echo
    echo "Exit: 0=MATCH/NEAR, 2=MISMATCH, 3=NO_PROGRESS, 4=RESET_OR_INVALID"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

# Wall clock. Used only for durations inside a single sweep, where the sub-
# millisecond resolution matters and a clock step is not a realistic risk.
now_ns() {
    local value

    value=$(date +%s%N) || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf "%s\n" "$value"
}

# Monotonic clock. /proc/uptime is not affected by NTP steps or `date -s`, both
# of which this package performs: update_time_sync.sh restarts systemd-timesyncd
# and enables NTP, and fake-hwclock.sh calls `date -s` directly. A forward wall
# step inflates the elapsed time between samples, which inflates the plausibility
# ceiling and admits an implausible counter advance as if it were real; a
# backward step used to abort the run outright. Resolution is 10 ms, which is far
# below the sample interval this bounds, and the value is built with integer
# arithmetic because a 64-bit nanosecond uptime exceeds float precision.
mono_ns() {
    local raw seconds fraction

    read -r raw _ < "$UPTIME_PATH" || return 1
    [[ "$raw" =~ ^([0-9]+)\.([0-9]{1,9})$ ]] || return 1
    seconds=${BASH_REMATCH[1]}
    fraction=${BASH_REMATCH[2]}
    while (( ${#fraction} < 9 )); do
        fraction="${fraction}0"
    done
    printf "%s\n" "$((10#$seconds * 1000000000 + 10#$fraction))"
}

format_ms() {
    local ns=$1
    awk -v ns="$ns" 'BEGIN { printf "%.3f", ns / 1000000 }'
}

read_frame_count() {
    local channel=$1
    local output value_hex

    READ_START_NS=$(now_ns) || die "date +%s%N is not supported"
    READ_START_MONO_NS=$(mono_ns) || die "/proc/uptime is not readable"
    output=$("$DMA_READ" "$channel" "$FRAME_COUNT_REG" 2>&1) || {
        echo "$output" >&2
        die "DMA read failed for ch$channel"
    }
    READ_END_NS=$(now_ns) || die "date +%s%N is not supported"
    READ_END_MONO_NS=$(mono_ns) || die "/proc/uptime is not readable"

    value_hex=$(printf "%s\n" "$output" |
        sed -nE 's/.*[[:space:]]val=(0x[0-9a-fA-F]{1,4})([[:space:]].*)?$/\1/p' |
        tail -n 1)
    [[ -n "$value_hex" ]] || {
        echo "$output" >&2
        die "failed to parse FRAME_COUNT for ch$channel"
    }

    READ_VALUE=$((value_hex & 0xffff))
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

CHANNEL_LIST=${1:-0,1,2,3}
INTERVAL_SEC=${2:-1}
SAMPLES=${3:-10}

[[ -x "$DMA_READ" ]] || die "missing helper: $DMA_READ"
[[ "$INTERVAL_SEC" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
    die "invalid interval_sec: $INTERVAL_SEC"
[[ "$MAX_SENSOR_FPS" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid MAX_SENSOR_FPS: $MAX_SENSOR_FPS"
[[ "$FRAME_STEP_MARGIN" =~ ^[0-9]+$ ]] ||
    die "invalid FRAME_STEP_MARGIN: $FRAME_STEP_MARGIN"
[[ "$SAMPLES" =~ ^[0-9]+$ ]] || die "invalid samples: $SAMPLES"
SAMPLES=$((10#$SAMPLES))
MAX_SENSOR_FPS=$((10#$MAX_SENSOR_FPS))
FRAME_STEP_MARGIN=$((10#$FRAME_STEP_MARGIN))
(( SAMPLES >= 2 )) || die "samples must be at least 2"

IFS=',' read -r -a CHANNELS <<<"$CHANNEL_LIST"
(( ${#CHANNELS[@]} >= 2 )) || die "at least two channels are required"

declare -A SEEN PREV STEP TOTAL CURRENT MID_NS READ_NS
declare -A HAVE_PREV INVALID_COUNT CONTINUITY STATUS REASON MAX_STEP
declare -A SAMPLE_MONO_NS LAST_SAMPLE_MONO_NS SENTINEL_ONLY

for channel in "${CHANNELS[@]}"; do
    [[ "$channel" =~ ^[0-3]$ ]] || die "invalid channel: $channel (expected 0..3)"
    [[ -z "${SEEN[$channel]+x}" ]] || die "duplicate channel: $channel"
    SEEN[$channel]=1
    HAVE_PREV[$channel]=0
    INVALID_COUNT[$channel]=0
    CONTINUITY[$channel]=1
    STEP[$channel]=0
    TOTAL[$channel]=0
    SENTINEL_ONLY[$channel]=1
done

REF_CHANNEL=${CHANNELS[0]}

# Measured on pim-camera-v016: this register only ever returns 0x0000 or 0xffff
# through the AP1302 DMA tunnel - 0xffff while idle, alternating while
# streaming - although 0x3000 (chip id) and 0x300a (frame_length_lines) read
# real, per-channel-distinct values on the same path. Only the two extremes of a
# 16-bit read means the register is not answering, so any total derived from it
# is meaningless.
#
# Tracked per channel, not per run. A run-wide flag would be cleared by one
# healthy channel, leaving a silent channel to look like a valid zero-advance
# counter; its peer's real advance would then be reported as MISMATCH - an
# out-of-sync claim built on a register that never answered.

echo "[$tag] reg=$FRAME_COUNT_REG channels=$CHANNEL_LIST interval_sec=$INTERVAL_SEC samples=$SAMPLES reference=ch$REF_CHANNEL"
echo "[$tag] plausibility max_sensor_fps=$MAX_SENSOR_FPS frame_step_margin=$FRAME_STEP_MARGIN"
echo "[$tag] note: counters prove frame-count agreement, not exposure/line phase; read_window_ms quantifies sequential-read uncertainty"
echo "[$tag] note: RESET_OR_INVALID means counter continuity was lost; totals and drift after that point are not synchronization evidence"

for ((sample = 1; sample <= SAMPLES; sample++)); do
    SWEEP_START_NS=$(now_ns) || die "date +%s%N is not supported"

    for channel in "${CHANNELS[@]}"; do
        read_frame_count "$channel"
        CURRENT[$channel]=$READ_VALUE
        if (( READ_VALUE != 0 && READ_VALUE != 0xffff )); then
            SENTINEL_ONLY[$channel]=0
        fi
        READ_NS[$channel]=$((READ_END_NS - READ_START_NS))
        MID_NS[$channel]=$((READ_START_NS + READ_NS[$channel] / 2))
        # Timestamp the read midpoint, not its launch. cam_dma_read.sh runs two
        # v4l2-ctl invocations with no timeout, so a wedged camera - exactly
        # when this diagnostic gets run - can stall one read for far longer than
        # the others. Start-to-start elapsed time then no longer matches the
        # interval between the counter observations themselves, which both
        # rejects legitimate advances as RESET_OR_INVALID and admits implausible
        # ones. On a healthy read the midpoint lands in the same 10 ms bucket as
        # the start, so this costs nothing in the normal case.
        SAMPLE_MONO_NS[$channel]=$(((READ_START_MONO_NS + READ_END_MONO_NS) / 2))
    done

    SWEEP_END_NS=$(now_ns) || die "date +%s%N is not supported"
    SWEEP_NS=$((SWEEP_END_NS - SWEEP_START_NS))

    for channel in "${CHANNELS[@]}"; do
        STATUS[$channel]=BASELINE
        REASON[$channel]=first_sample
        MAX_STEP[$channel]=0

        if (( HAVE_PREV[$channel] )); then
            elapsed_ns=$((SAMPLE_MONO_NS[$channel] - LAST_SAMPLE_MONO_NS[$channel]))
            (( elapsed_ns >= 0 )) || die "monotonic clock went backwards for ch$channel"

            step=$(( (CURRENT[$channel] - PREV[$channel]) & 0xffff ))
            max_step=$(( (elapsed_ns * MAX_SENSOR_FPS + 999999999) / 1000000000 + FRAME_STEP_MARGIN ))
            (( max_step < 65536 )) ||
                die "measurement interval is too long to distinguish a 16-bit wrap for ch$channel"
            MAX_STEP[$channel]=$max_step

            if (( step <= max_step )); then
                STATUS[$channel]=OK
                REASON[$channel]=plausible
                STEP[$channel]=$step
                TOTAL[$channel]=$((TOTAL[$channel] + step))
            else
                STATUS[$channel]=RESET_OR_INVALID
                REASON[$channel]="modular_step_${step}_exceeds_${max_step}"
                STEP[$channel]=0
                INVALID_COUNT[$channel]=$((INVALID_COUNT[$channel] + 1))
                CONTINUITY[$channel]=0
            fi
        fi

        PREV[$channel]=${CURRENT[$channel]}
        LAST_SAMPLE_MONO_NS[$channel]=${SAMPLE_MONO_NS[$channel]}
        HAVE_PREV[$channel]=1
    done

    echo "[$tag] sample=$sample sweep_start_ns=$SWEEP_START_NS read_window_ms=$(format_ms "$SWEEP_NS")"
    for channel in "${CHANNELS[@]}"; do
        if [[ "${STATUS[$channel]}" == "BASELINE" || "${STATUS[$channel]}" == "RESET_OR_INVALID" ]]; then
            step_text="-"
        else
            step_text=${STEP[$channel]}
        fi

        if (( CONTINUITY[$channel] && CONTINUITY[$REF_CHANNEL] )); then
            drift=$(printf "%+d" "$((TOTAL[$channel] - TOTAL[$REF_CHANNEL]))")
        else
            drift=NA
        fi
        raw_offset=$(( (CURRENT[$channel] - CURRENT[$REF_CHANNEL]) & 0xffff ))
        (( raw_offset >= 0x8000 )) && raw_offset=$((raw_offset - 0x10000))
        midpoint_offset_ns=$((MID_NS[$channel] - SWEEP_START_NS))
        printf '[%s] sample=%d ch=%d count=0x%04x raw_offset=%+d status=%s reason=%s step=%s max_step=%d valid_total=%d drift=%s read_ms=%s midpoint_offset_ms=%s\n' \
            "$tag" "$sample" "$channel" "${CURRENT[$channel]}" "$raw_offset" \
            "${STATUS[$channel]}" "${REASON[$channel]}" "$step_text" "${MAX_STEP[$channel]}" \
            "${TOTAL[$channel]}" "$drift" "$(format_ms "${READ_NS[$channel]}")" \
            "$(format_ms "$midpoint_offset_ns")"
    done

    if (( sample < SAMPLES )); then
        sleep "$INTERVAL_SEC"
    fi
done

min_total=${TOTAL[${CHANNELS[0]}]}
max_total=$min_total
invalid_total=0
sentinel_channels=""
for channel in "${CHANNELS[@]}"; do
    (( TOTAL[$channel] < min_total )) && min_total=${TOTAL[$channel]}
    (( TOTAL[$channel] > max_total )) && max_total=${TOTAL[$channel]}
    invalid_total=$((invalid_total + INVALID_COUNT[$channel]))
    if (( SENTINEL_ONLY[$channel] )); then
        sentinel_channels="${sentinel_channels}${sentinel_channels:+,}ch$channel"
    fi
    echo "[$tag] channel_summary ch=$channel invalid_count=${INVALID_COUNT[$channel]} continuity=${CONTINUITY[$channel]} valid_total=${TOTAL[$channel]} sentinel_only=${SENTINEL_ONLY[$channel]}"
done

drift_span=$((max_total - min_total))
if [[ -n "$sentinel_channels" ]]; then
    # Any silent channel invalidates the whole comparison. On its own it would
    # otherwise land in NO_PROGRESS, which asserts that the sensors produced no
    # frames; alongside an advancing peer it would produce MISMATCH, which
    # asserts the channels disagree. Both are hardware claims, and a register
    # that never answers cannot support either.
    result=RESET_OR_INVALID
elif (( invalid_total > 0 )); then
    result=RESET_OR_INVALID
elif (( max_total == 0 )); then
    result=NO_PROGRESS
elif (( drift_span == 0 )); then
    result=MATCH
elif (( drift_span == 1 )); then
    result=NEAR
else
    result=MISMATCH
fi

if [[ "$result" == "RESET_OR_INVALID" ]]; then
    echo "[$tag] result=$result sentinel_only=${sentinel_channels:-none} invalid_total=$invalid_total drift_span=NA min_valid_total=$min_total max_valid_total=$max_total"
else
    echo "[$tag] result=$result sentinel_only=${sentinel_channels:-none} invalid_total=$invalid_total drift_span=$drift_span min_valid_total=$min_total max_valid_total=$max_total"
fi
case "$result" in
    RESET_OR_INVALID)
        if [[ -n "$sentinel_channels" ]]; then
            echo "[$tag] interpretation: every read returned 0x0000 or 0xffff, so this register never answered on this path; this says nothing about whether the sensors produced frames"
        else
            echo "[$tag] interpretation: at least one counter reset or DMA read was implausible; do not use totals to judge synchronization"
        fi
        exit 4
        ;;
    NO_PROGRESS)
        echo "[$tag] interpretation: no sensor output frames advanced during the measurement"
        exit 3
        ;;
    MATCH)
        echo "[$tag] interpretation: all channels advanced by the same number of sensor output frames"
        ;;
    NEAR)
        echo "[$tag] interpretation: one-frame difference; repeat with more samples because a sequential read can cross a frame boundary"
        ;;
    MISMATCH)
        echo "[$tag] interpretation: cumulative sensor frame counts diverged by more than one frame"
        exit 2
        ;;
esac
