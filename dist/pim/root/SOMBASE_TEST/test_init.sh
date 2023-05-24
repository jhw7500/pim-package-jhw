#!/bin/bash

systemctl stop cam-operate

cp /root/SOMBASE_TEST/eth0.yaml /etc/netplan/
netplan apply

