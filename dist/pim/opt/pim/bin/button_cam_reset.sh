#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice "[RST][$tag:$LINENO] button cam reset start"

GPIO_PIN=131  # GPIO number to use
SCRIPT="/opt/pim/bin/cam_disable.sh"  # Path to the script to execute
reset_flag=0
# Export GPIO
if [ ! -d "/sys/class/gpio/gpio${GPIO_PIN}" ]; then
    echo "${GPIO_PIN}" > /sys/class/gpio/export
fi

# Set GPIO direction
echo "in" > /sys/class/gpio/gpio${GPIO_PIN}/direction

# Loop to check GPIO value and execute the script
while true; do
    value=$(cat /sys/class/gpio/gpio${GPIO_PIN}/value)
    if [[ "$value" -eq 1 ]] && [[ "$reset_flag" -eq 0 ]]; then
        echo "GPIO is #value, reset_flag is $reset_flag, executing script..."
        dmesg -n 3
        #$SCRIPT
        /opt/pim/bin/cam_enable.sh 
        reset_flag=1
        echo "reset"
    elif [[ "$value" -eq 0 ]] && [[ "$reset_flag" -eq 1 ]]; then
        #echo "GPIO is $value, reset_flag is $reset_flag"
        dmesg -n 3
        /opt/pim/bin/cam_disable.sh
        reset_flag=0
    fi
    sleep 1  # Check every second
done

# Unexport GPIO on script exit
trap "echo ${GPIO_PIN} > /sys/class/gpio/unexport" EXIT
