#!/bin/bash
success_val=" country: US"
RES=$(dmesg | grep country)

if [[ $RES != *"$success_val"* ]]; then
	echo "   wifi region write fail $success_val"
else
	echo "   wifi region write pass $success_val"
fi
