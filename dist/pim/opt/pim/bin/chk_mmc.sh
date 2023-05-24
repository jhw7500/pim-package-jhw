#!/bin/bash

tag=$(basename "$0")
RES=$(cat /sys/kernel/debug/mmc2/mmc2:0001/ext_csd)
KEY=MMC
#echo $RES

typea="${RES:536:2}"
typeb="${RES:538:2}"
#echo $typea $typeb
typead=$(echo "ibase=16; $typea"|bc)
typebd=$(echo "ibase=16; $typeb"|bc)
typead=$((typead*10))
typebd=$((typebd*10))
#echo Type A percent:$(($typead*10))%
#echo Type B percent:$(($typebd*10))%
#logger -p local0.notice [$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%
if [ $typead -ge 80 ] || [ $typebd -ge 80 ]
then
    logger -p local0.emerg [$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%
elif [ $typead -ge 60 ] || [ $typebd -ge 60 ]
then
    logger -p local0.crit [$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%
elif [ $typead -ge 40 ] || [ $typebd -ge 40 ]
then
    logger -p local0.error [$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%
else
    logger -p local0.notice [$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%
fi
