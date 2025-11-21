#!/bin/bash
TAG=$(basename "$0")
KEY=MNT
DEVICE=/dev/mmcblk1p1
DIR=/mnt/sd_cam
mnt_state=0
mnt_cnt=0
mnt_folder=0
mnt_dev=0
daemon_name=""
status=""
mnt_flag="/dev/shm/sd_mount_flag"
fsck_cnt=0
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

mount_cmd="mount -t vfat -o noatime,nodiratime,flush,dirsync,utf8=1,shortname=mixed $DEVICE $DIR"
fsck_cmd='fsck.vfat -vaw "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.error'

#mount_cmd="mount -t ext4 -o noatime,nodiratime,commit=60,data=writeback,barrier=1,errors=remount-ro $DEVICE $DIR"
#fsck_cmd='fsck.ext4 -vyfp "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.error'

while true; do
    case $mnt_state in
        0)
            #logger -p local0.info "[$KEY][$TAG:$LINENO] case 0"
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                logger -p local0.info "[$KEY][$TAG:$LINENO] umount $DIR"
                umount $DIR
                mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
                #logger -p local0.info "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev"
                if [ -z "$mnt_dev" ]; then
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : rm -rf /mnt/*"
                    rm -rf "$DIR"

                    if [ ! -d $DIR ]; then
                        logger -p local0.info "[$KEY][$TAG:$LINENO] mkdir -p $DIR"
                        mkdir -p $DIR
                    fi

                    FSTYPE="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null)"
                    if [ -z "$FSTYPE" ]; then
                        FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null)"
                    fi

                    logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE fstype : $FSTYPE"
                    case "$FSTYPE" in
                        vfat|fat|fat32|msdos)
                            mount_cmd="mount -t vfat -o noatime,nodiratime,flush,dirsync,utf8=1,shortname=mixed $DEVICE $DIR"
                            ;;
                        ext4)
                            mount_cmd="mount -t ext4 -o noatime,nodiratime,commit=60,data=writeback,barrier=1,errors=remount-ro $DEVICE $DIR"
                            ;;
                        exfat)
                            mount_cmd="mount -t exfat -o noatime,nodiratime $DEVICE $DIR"
                            ;;
                        *)
                            logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE fstype is wrong! : fallback"
                            ;;
                    esac

                    logger -p local0.notice "[$KEY][$TAG:$LINENO] $mount_cmd"
                    eval "$mount_cmd"

                    mnt_folder=$(df | grep $DEVICE | awk '{print $6}')
                    if [ "$mnt_folder" == "$DIR" ]; then
                        if [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i '(rw,')" ]; then
                            logger -p local0.notice "[$KEY][$TAG:$LINENO] sd_mount_flag set"
                            echo '1' > $mnt_flag
		                    mnt_state=1
		                    mnt_cnt=0
                            fsck_cnt=0
                            rm '$DIR/FSCK*'
                            daemon_name=cam-operate
                            status=$(systemctl is-enabled $daemon_name 2>/dev/null)
                            if [ "$status" == "enabled" ]; then
                                status=$(systemctl is-active $daemon_name 2>/dev/null)
                                if [ "$status" != "active" ]; then
                                    systemctl start $daemon_name
                                fi
                            fi
                        else
                            logger -p local0.err "[$KEY][$TAG:$LINENO] mounted not r/w"
                            mnt_state=1
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
                elif [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i '(ro,')" ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] mmcblk1 s/w read only"
                    mnt_state=1
                else
                    mnt_state=1
                fi
            fi
        ;;
        1)
            if [ ! -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                echo '0' > $mnt_flag
                ((mnt_cnt++))
                #logger -p local0.error "[$KEY][$TAG:$LINENO] no sd card($mnt_cnt)"
                if [ $mnt_cnt -ge 2 ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] no sd card($mnt_cnt)"
                    mnt_cnt=0
                    mnt_state=0
                    break
                fi
            else
                mnt_dev=$(df | grep $DIR | awk '{print $1}')
                if [ "$mnt_dev" != "$DEVICE" ]; then
                    echo '0' > $mnt_flag
                    ((mnt_cnt++))
                    logger -p local0.error "[$KEY][$TAG:$LINENO] $mnt_dev != $DEVICE($mnt_cnt)"
                    if [ $mnt_cnt -ge 2 ]; then
                        #logger -p local0.error "[$KEY][$TAG:$LINENO] umount $DEVICE, $DIR"
                        #umount $DEVICE
                        #umount $DIR
                        mnt_state=0
                        break
                    fi
                fi

		        if [ "$(cat /sys/block/mmcblk1/ro)" = "1" ] || [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i '(ro,')" ]; then
                    echo '0' > $mnt_flag
                    ((mnt_cnt++))
                    if [ "$(cat /sys/block/mmcblk1/ro)" = "1" ]; then
		                logger -p local0.error "[$KEY][$TAG:$LINENO] $DEVICE is in H/W read-only mode(mnt_cnt:$mnt_cnt/fsck_cnt:$fsck_cnt)"
                    fi

                    if [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i '(ro,')" ]; then
                        logger -p local0.error "[$KEY][$TAG:$LINENO] $DEVICE is in S/W read-only mode(mnt_cnt:$mnt_cnt/fsck_cnt:$fsck_cnt)"
                    fi

                    if [ $mnt_cnt -ge 3 ]; then
                        if [ "$tmp_path" == "$DIR" ]; then
                            daemon_name=cam-operate
                            status=$(systemctl is-active $daemon_name 2>/dev/null)
                            if [ "$status" != "active" ]; then
                                systemctl stop $daemon_name
                            fi
                        fi

                        if [ $fsck_cnt -ge 5 ]; then
                            logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE cannot recovery : sd-mount exit"
                            exit 0
                        fi
                        logger -p local0.error "[$KEY][$TAG:$LINENO] unmount for fsck..."
		                umount $DEVICE
                        sleep 2
		                #umount $mnt_folder
                        #mnt_state=1
                        mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
                        logger -p local0.error "[$KEY][$TAG:$LINENO] mnt_dev:$mnt_dev"
                        if [ -z "$mnt_dev" ]; then
                            logger -p local0.error "[$KEY][$TAG:$LINENO] unmounted $mnt_folder, $DEVICE"

                            FSTYPE="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null)"
                            if [ -z "$FSTYPE" ]; then
                                FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null)"
                            fi

                            logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE fstype : $FSTYPE"

                            #fsck.vfat -v -y $DEVICE
                            #fsck.vfat -vaw $DEVICE |tee /var/log/cantops/local0.log
                            #fsck.vfat -vaw "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /"  | logger -p local0.error
                            case "$FSTYPE" in
                                vfat|fat|fat32|msdos)
                                    fsck_cmd='fsck.vfat -vaw "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.notice'
                                    ;;
                                ext4)
                                    fsck_cmd='fsck.ext4 -pv "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.notice'
                                    ;;
                                exfat)
                                    fsck_cmd='fsck.exfat -y "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.notice'
                                    ;;
                                *)
                                    logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE fstype is wrong! : fallback"
                                    ;;
                            esac

                            logger -p local0.notice "[$KEY][$TAG:$LINENO] $fsck_cmd"
                            eval "$fsck_cmd"
                            #rm -rf "$mnt_folder"
                            #rm "$mnt_flag"
                            mnt_state=0
                            mnt_cnt=0
                            ((fsck_cnt++))
                        else
                            logger -p local0.error "[$KEY][$TAG:$LINENO] force unmount for fsck..."
                            umount -f $DEVICE
                        fi
                    fi
		        fi
            fi
        ;;
    esac
    sleep 3
done

