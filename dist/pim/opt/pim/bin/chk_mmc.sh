#!/bin/bash

tag=$(basename "$0")
RES=$(cat /sys/kernel/debug/mmc2/mmc2:0001/ext_csd)
#echo $RES

typea="${RES:536:2}"
typeb="${RES:538:2}"
#echo $typea $typeb
typead=$(echo "ibase=16; $typea"|bc)
typebd=$(echo "ibase=16; $typeb"|bc)
#echo Type A percent:$(($typead*10))%
#echo Type B percent:$(($typebd*10))%
logger -p local0.notice [CHK][$tag:$LINENO] mmc Type A:$(($typead*10))% Type B:$(($typebd*10))%

