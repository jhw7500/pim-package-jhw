#!/bin/bash
echo "start_df_check" >>/shared/df_log.txt  

while :
do
	df /mnt/sd_cam -h >>/shared/df_log.txt ;
        echo "sleep 30">>/shared/df_log.txt;
	ls /mnt/sd_cam/202212*>>/shared/df_log.txt; 
	sleep 30;
done

