#!/bin/bash

TAG=$(basename "$0")
KEY=MNT
DEVICE=/dev/mmcblk1p1
mnt_state_=0
mnt_cnt_=0
mnt_folder=/mnt/sd_cam
mnt_dev=0
mnt_flag="/dev/shm/sd_mount_flag"
logger -p local0.notice "[$KEY][$TAG:$LINENO] automnt $1 start"

LOCKFILE="/tmp/automnt_sd_for_emmc_boot.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 1

#fsck.vfat -a /dev/mmcblk1p1 2>&1 | while IFS= read -r line; do
#    LINENO=$(echo "$line" | awk '{print NR}')
#    logger -p local0.notice "[$KEY][$TAG:$LINENO] $line"
#done

#logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : rm -rf $1"
umount $DEVICE
#rm -rf $mnt_folder

while true; do
    case $mnt_state_ in
        0)
            logger -p local0.notice "[$KEY][$TAG:$LINENO] case 0"
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                #logger -p local0.notice "[$KEY][$TAG:$LINENO] sd card file system check : fsck.vfat -a /dev/mmcblk1p1"
                mnt_dev=`df | grep '/mnt/sd_cam' | awk '{print $1}'`
                logger -p local0.notice "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev"
                if [ -z $mnt_dev ]; then
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : rm -rf /mnt/*"
                    rm -rf $mnt_folder

                    if [ ! -d $mnt_folder ]; then
                        logger -p local0.notice "[$KEY][$TAG:$LINENO] mkdir -p $mnt_folder"
                        mkdir -p $mnt_folder
                    fi
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount $DEVICE $mnt_folder"
                    mount $DEVICE $mnt_folder
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] sd_mount_flag set"
                    echo '1' > $mnt_flag
		            mnt_state_=1
		            mnt_cnt=0
                elif [ $mnt_dev != $DEVICE ]; then
		            logger -p local0.err "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev != $DEVICE"
                    mnt_state_=1
		            #logger -p local0.err "[$KEY][$TAG:$LINENO] force unmount..."
                    #umount -f $mnt_folder
		            #umount -f $DEVICE
                    #mount $DEVICE $mnt_folder
                    #logger -p local0.notice "[$KEY][$TAG:$LINENO] remount $DEVICE $mnt_folder"
                fi
            fi
        ;;
        1)
            if [ ! -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                mnt_cnt_=`expr $mnt_cnt_ + 1`
                logger -p local0.error "[$KEY][$TAG:$LINENO] mount_cnt : $mnt_cnt"
                if [ $mnt_cnt_ -ge 4 ]; then
                    logger -p local0.emerg "[$KEY][$TAG:$LINENO] please check sd card"
		            mnt_cnt=0
                    #umount $mnt_folder
                    #mnt_state_=0
                    #rm $mnt_flag
                fi
            else
                mnt_cnt_=0
                mnt_dev=`df | grep $mnt_folder | awk '{print $1}'`
                if [ $mnt_dev != $DEVICE ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev != $DEVICE"
                    umount $mnt_folder
                    umount $DEVICE
                    mnt_state_=0
                fi

		        if [ "$(cat /sys/block/mmcblk1/ro)" = "1" ]; then
		            logger -p local0.error "[$KEY][$TAG:$LINENO] $DEVICE is in read-only mode!"
                    logger -p local0.error "[$KEY][$TAG:$LINENO] unmount for fsck..."
		            umount $DEVICE
		            umount $mnt_folder
                    mnt_state_=1
                    mnt_dev=`df | grep $mnt_folder | awk '{print $1}'`
                    if [ -z $mnt_dev ]; then
                        logger -p local0.error "[$KEY][$TAG:$LINENO] unmounted $mnt_folder, $DEVICE"
                        logger -p local0.error "[$KEY][$TAG:$LINENO] fsck.vfat -v -y $DEVICE"
                        fsck.vfat -v -y $DEVICE
                        rm -rf $mnt_folder
                        rm $mnt_flag
                        mnt_state_=0
                    else
                        logger -p local0.error "[$KEY][$TAG:$LINENO] force unmount for fsck..."
                        umount -f $DEVICE
                        umount -f $mnt_folder
                    fi
		        fi
            fi
        ;;
    esac
    sleep 5
done
