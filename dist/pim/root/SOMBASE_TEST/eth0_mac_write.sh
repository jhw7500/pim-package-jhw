#!/bin/bash
var=$1
echo "write $1"
python3 mac_addr_for_PIM.py write eth0 $1

ret= python3 mac_addr_for_PIM.py read eth0
