#!/bin/bash
tag=$(basename "$0")
key=DSK

start=$(fdisk -l /dev/mmcblk$1 |grep mmcblk$1p$2|awk '{print $2}')
if [ "$start" == "*" ]; then
    echo start sector fail
    logger -p local0.error [$key][$tag:$LINENO] start sector fail
    start=$(fdisk -l /dev/mmcblk$1 |grep mmcblk$1p$2|awk '{print $3}')
    end=$(fdisk -l /dev/mmcblk$1 |grep mmcblk$1p$2|awk '{print $4}')
else
    end=$(fdisk -l /dev/mmcblk$1 |grep mmcblk$1p$2|awk '{print $3}')
fi

echo mmcblk$1p$2 start:$start end:$end
logger -p local0.notice [$key][$tag:$LINENO] mmcblk$1p$2 start:$start end:$end

#: <<'END'
if [ "$end" -lt 60000000 ]; then
echo fdisk mmcblk$1p$2
logger -p local0.alert [$key][$tag:$LINENO] fdisk mmcblk$1p$2 size up
fdisk -u -c /dev/mmcblk$1 <<EOF
d
$2
n
p
$2
$start

wq
EOF
logger -p local0.notice "[$key][$tag:$LINENO] resizefe /dev/mmcblk$1p$2"
resize2fs /dev/mmcblk$1p$2
fi
#END
