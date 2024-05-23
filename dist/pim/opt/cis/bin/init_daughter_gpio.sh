#!/bin/bash

f_status=$(python3 /opt/cis/bin/getconfval.py dev_f_status | tr -d '\r\n')
f_boot0=$(python3 /opt/cis/bin/getconfval.py dev_f_boot0 | tr -d '\r\n')
c2m_rst=$(python3 /opt/cis/bin/getconfval.py dev_c2m_rst | tr -d '\r\n')

# f_status gpio init
if [ ! -d "/sys/class/gpio/gpio$f_status" ] ; then
    echo $f_status > /sys/class/gpio/export
fi

echo in > /sys/class/gpio/gpio$f_status/direction

# f_boot0 gpio init
if [ ! -d "/sys/class/gpio/gpio$f_boot0" ] ; then
    echo $f_boot0 > /sys/class/gpio/export
fi

echo out > /sys/class/gpio/gpio$f_boot0/direction
echo 0 > /sys/class/gpio/gpio$f_boot0/value

# c2m_rst gpio init
if [ ! -d "/sys/class/gpio/gpio$c2m_rst" ] ; then
    echo $c2m_rst > /sys/class/gpio/export
fi

echo out > /sys/class/gpio/gpio$c2m_rst/direction
echo 1 > /sys/class/gpio/gpio$c2m_rst/value
sleep 0.1
echo 0 > /sys/class/gpio/gpio$c2m_rst/value
sleep 0.1
echo 1 > /sys/class/gpio/gpio$c2m_rst/value
sleep 1