#!/bin/bash

# Script to read and parse MCP7940 RTC registers
# Usage: ./read_rtc_mcp7940.sh [i2c_bus] [i2c_addr]
# Default: Bus 1, Address 0x6f

BUS=${1:-1}
ADDR=${2:-0x6f}

echo "==========================================="
echo " Reading MCP7940 RTC (Bus: $BUS, Addr: $ADDR)"
echo "==========================================="

# Check if i2cget is available
if ! command -v i2cget &> /dev/null; then
    echo "Error: i2cget command not found. Please install i2c-tools."
    exit 1
fi

# Function to read register
read_reg() {
    local val=$(i2cget -y "$BUS" "$ADDR" "$1" 2>/dev/null)
    if [ -z "$val" ]; then
        echo "Error: Failed to read register $1"
        exit 1
    fi
    echo "$val"
}

# Function to convert BCD to Decimal
bcd2dec() {
    local hex=$1
    # Strip 0x
    hex=${hex#0x}
    # Convert hex to decimal for shell arithmetic
    local dec=$((16#$hex))
    # BCD conversion: (val >> 4) * 10 + (val & 0x0F)
    echo $(( ((dec >> 4) * 10) + (dec & 0x0F) ))
}

# Read Raw Registers
R_SEC=$(read_reg 0x00)
R_MIN=$(read_reg 0x01)
R_HOUR=$(read_reg 0x02)
R_WDAY=$(read_reg 0x03)
R_DATE=$(read_reg 0x04)
R_MONTH=$(read_reg 0x05)
R_YEAR=$(read_reg 0x06)
R_CTRL=$(read_reg 0x07)

echo "Raw Registers:"
echo "  0x00 (Seconds): $R_SEC"
echo "  0x01 (Minutes): $R_MIN"
echo "  0x02 (Hours)  : $R_HOUR"
echo "  0x03 (WeekDay): $R_WDAY"
echo "  0x04 (Date)   : $R_DATE"
echo "  0x05 (Month)  : $R_MONTH"
echo "  0x06 (Year)   : $R_YEAR"
echo "  0x07 (Control): $R_CTRL"
echo "-------------------------------------------"

# Parse SECONDS (Bit 7 is ST - Start Oscillator)
VAL_SEC=$((16#${R_SEC#0x}))
ST_BIT=$(( (VAL_SEC & 0x80) >> 7 ))
SEC_BCD=$(( VAL_SEC & 0x7F )) # Mask out ST bit
SEC_DEC=$(bcd2dec $(printf "0x%x" $SEC_BCD))

# Parse MINUTES
VAL_MIN=$((16#${R_MIN#0x}))
MIN_BCD=$(( VAL_MIN & 0x7F ))
MIN_DEC=$(bcd2dec $(printf "0x%x" $MIN_BCD))

# Parse HOURS (Bit 6 is 12/24)
VAL_HOUR=$((16#${R_HOUR#0x}))
# Check 12/24 mode? Usually we assume 24h if Linux set it, but let's check.
# Bit 6: 1 = 12h, 0 = 24h.
IS_12H=$(( (VAL_HOUR & 0x40) >> 6 ))
if [ "$IS_12H" -eq 1 ]; then
    # 12 Hour Mode
    IS_PM=$(( (VAL_HOUR & 0x20) >> 5 ))
    HOUR_BCD=$(( VAL_HOUR & 0x1F ))
    HOUR_DEC=$(bcd2dec $(printf "0x%x" $HOUR_BCD))
    TIME_SUFFIX="AM"
    [ "$IS_PM" -eq 1 ] && TIME_SUFFIX="PM"
    HOUR_STR="$HOUR_DEC $TIME_SUFFIX (12h mode)"
else
    # 24 Hour Mode
    HOUR_BCD=$(( VAL_HOUR & 0x3F ))
    HOUR_DEC=$(bcd2dec $(printf "0x%x" $HOUR_BCD))
    HOUR_STR="$HOUR_DEC (24h mode)"
fi

# Parse WEEKDAY (Bit 3 is VBATEN - External Battery Enable)
VAL_WDAY=$((16#${R_WDAY#0x}))
VBATEN_BIT=$(( (VAL_WDAY & 0x08) >> 3 ))
WDAY_BCD=$(( VAL_WDAY & 0x07 )) # Bits 0-2
WDAY_DEC=$(bcd2dec $(printf "0x%x" $WDAY_BCD))

# Parse DATE
VAL_DATE=$((16#${R_DATE#0x}))
DATE_BCD=$(( VAL_DATE & 0x3F ))
DATE_DEC=$(bcd2dec $(printf "0x%x" $DATE_BCD))

# Parse MONTH (Bit 5 is LP - Leap Year)
VAL_MONTH=$((16#${R_MONTH#0x}))
LP_BIT=$(( (VAL_MONTH & 0x20) >> 5 ))
MONTH_BCD=$(( VAL_MONTH & 0x1F ))
MONTH_DEC=$(bcd2dec $(printf "0x%x" $MONTH_BCD))

# Parse YEAR
VAL_YEAR=$((16#${R_YEAR#0x}))
YEAR_DEC=$(bcd2dec $(printf "0x%x" $VAL_YEAR))
FULL_YEAR=$((2000 + YEAR_DEC))

echo "Parsed Values:"
echo "  Time      : $HOUR_STR:$MIN_DEC:$SEC_DEC"
echo "  Date      : $FULL_YEAR-$MONTH_DEC-$DATE_DEC (Day: $WDAY_DEC)"
echo ""
echo "Status Flags:"
if [ "$ST_BIT" -eq 1 ]; then
    echo "  [OK] Oscillator (ST): Running"
else
    echo "  [FAIL] Oscillator (ST): STOPPED (Bit 7 in 0x00 is 0)"
fi

if [ "$VBATEN_BIT" -eq 1 ]; then
    echo "  [OK] Battery Backup (VBATEN): Enabled"
else
    echo "  [WARN] Battery Backup (VBATEN): Disabled (Bit 3 in 0x03 is 0)"
fi

if [ "$LP_BIT" -eq 1 ]; then
    echo "  [INFO] Leap Year (LP): Yes"
fi

echo "==========================================="
