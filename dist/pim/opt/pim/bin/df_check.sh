#!/bin/bash
echo "start_df_check" >>/shared/df_log.txt  

while :
do
	df /mnt/ -h >>/shared/df_log.txt ;
        echo "sleep 30">>/shared/df_log.txt;
	ls /mnt/202212*>>/shared/df_log.txt; 
	sleep 30;
done

