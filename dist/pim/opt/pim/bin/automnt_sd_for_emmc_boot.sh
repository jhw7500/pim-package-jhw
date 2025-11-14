#!/bin/bash

TAG=$(basename "$0")
KEY=MNT
DEVICE=/dev/mmcblk1p1
DIR=/mnt/sd_cam
mnt_state=0
mnt_cnt=0
mnt_folder=0
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
#umount $DEVICE
#rm -rf $mnt_folder

while true; do
    case $mnt_state in
        0)
            logger -p local0.notice "[$KEY][$TAG:$LINENO] case 0"
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                #logger -p local0.notice "[$KEY][$TAG:$LINENO] sd card file system check : fsck.vfat -a /dev/mmcblk1p1"
                umount $DIR
                mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
                logger -p local0.notice "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev"
                if [ -z "$mnt_dev" ]; then
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : rm -rf /mnt/*"
                    rm -rf "$DIR"

                    if [ ! -d $DIR ]; then
                        logger -p local0.notice "[$KEY][$TAG:$LINENO] mkdir -p $DIR"
                        mkdir -p $DIR
                    fi
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount $DEVICE $DIR"
                    mount -t vfat -o noatime,nodiratime,flush,dirsync,utf8=1,shortname=mixed $DEVICE $DIR
                    mnt_folder=$(df | grep $DEVICE | awk '{print $6}')
                    if [ "$mnt_folder" == "$DIR" ]; then
                        logger -p local0.notice "[$KEY][$TAG:$LINENO] sd_mount_flag set"
                        echo '1' > $mnt_flag
		                mnt_state=1
		                mnt_cnt=0
                        rm '$DIR/FSCK*'
                        daemon_name=cam-operate
                        status=$(systemctl is-enabled $daemon_name 2>/dev/null)
                        if [ "$status" == "enabled" ]; then
                            systemctl start $daemon_name
                        fi
                    else
                        logger -p local0.err "[$KEY][$TAG:$LINENO] sd mount failed"
                    fi
                elif [ "$mnt_dev" != "$DEVICE" ]; then
		            logger -p local0.err "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev != $DEVICE"
                    mnt_state=1
		            #logger -p local0.err "[$KEY][$TAG:$LINENO] force unmount..."
                    #umount -f $mnt_folder
		            #umount -f $DEVICE
                    #mount $DEVICE $mnt_folder
                    #logger -p local0.notice "[$KEY][$TAG:$LINENO] remount $DEVICE $DIR"
                elif [ "$(cat /sys/block/mmcblk1/ro)" = "1" ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] mmcblk1 h/w read only"
                    mnt_state=1
                elif [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i 'ro,')" ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] mmcblk1 s/w read only"
                    mnt_state=1
                else
                    mnt_state=1
                fi
            fi
        ;;
        1)
            if [ ! -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                ((mnt_cnt++))
                logger -p local0.error "[$KEY][$TAG:$LINENO] no sd card($mnt_cnt)"
                if [ $mnt_cnt -ge 4 ]; then
                    mnt_cnt=0
                    #logger -p local0.emerg "[$KEY][$TAG:$LINENO] please check sd card"
		            #mnt_cnt=0
                    #umount $mnt_folder
                    mnt_state=0
                    #rm $mnt_flag
                fi
            else
                mnt_dev=$(df | grep $DIR | awk '{print $1}')
                if [ "$mnt_dev" != "$DEVICE" ]; then
                    ((mnt_cnt++))
                    logger -p local0.error "[$KEY][$TAG:$LINENO] $mnt_dev != $DEVICE($mnt_cnt)"
                    if [ $mnt_cnt -ge 4 ]; then
                        #logger -p local0.error "[$KEY][$TAG:$LINENO] umount $DEVICE, $DIR"
                        #umount $DEVICE
                        #umount $DIR
                        mnt_state=0
                        break
                    fi
                fi

		        if [ "$(cat /sys/block/mmcblk1/ro)" = "1" ] || [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i 'ro,')" ]; then
                    ((mnt_cnt++))
                    if [ "$(cat /sys/block/mmcblk1/ro)" = "1" ]; then
		                logger -p local0.error "[$KEY][$TAG:$LINENO] $DEVICE is in H/W read-only mode($mnt_cnt)"
                    fi

                    if [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i 'ro,')" ]; then
                        logger -p local0.error "[$KEY][$TAG:$LINENO] $DEVICE is in S/W read-only mode($mnt_cnt)"
                    fi

                    if [ $mnt_cnt -ge 4 ]; then
                        mnt_cnt=0
                        systemctl stop cam-operate
                        logger -p local0.error "[$KEY][$TAG:$LINENO] unmount for fsck..."
		                umount $DEVICE
                        sleep 2
		                #umount $mnt_folder
                        #mnt_state=1
                        mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
                        logger -p local0.error "[$KEY][$TAG:$LINENO] mnt_dev:$mnt_dev"
                        if [ -z "$mnt_dev" ]; then
                            logger -p local0.error "[$KEY][$TAG:$LINENO] unmounted $mnt_folder, $DEVICE"
                            logger -p local0.error "[$KEY][$TAG:$LINENO] fsck.vfat -v $DEVICE"
                            #fsck.vfat -v -y $DEVICE
                            #fsck.vfat -vaw $DEVICE |tee /var/log/cantops/local0.log
                            fsck.vfat -vaw "$DEVICE" 2>&1 \
 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" \
 | logger -p local0.error
                            #rm -rf "$mnt_folder"
                            #rm "$mnt_flag"
                            mnt_state=0
                        else
                            logger -p local0.error "[$KEY][$TAG:$LINENO] force unmount for fsck..."
                            umount -f $DEVICE
                            #umount -f $mnt_folder
                            sleep 2
                            mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
                            logger -p local0.error "[$KEY][$TAG:$LINENO] mnt_dev:$mnt_dev"
                            if [ -z "$mnt_dev" ]; then
                                logger -p local0.error "[$KEY][$TAG:$LINENO] fsck.vfat -vaw $DEVICE"
                                fsck.vfat -vaw $DEVICE |tee /var/log/cantops/local0.log
                                mnt_state=0
                            fi
                        fi
                    fi
		        fi
            fi
        ;;
    esac
    sleep 5
done
