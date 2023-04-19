#!/bin/bash
success_val=" country: US"
RES=$(cat /var/log/dmesg.0 | grep  "Firmware OTP region: 10")

if [[ $RES != *"$success_val"* ]]; then
	echo "   wifi region write fail $RES"
else
	echo "   wifi region write pass $success_val"
fi
