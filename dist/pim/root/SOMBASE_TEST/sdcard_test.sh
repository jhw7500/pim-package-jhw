#!/bin/bash
#for PIM Camera sdcard Test
VERSION="20221108"
COUNT_PATH="/root/count"
SDA_PATH="/mnt/sda"
SDB_PATH="/mnt/sdb"
WRITE_COUNT="sd_write_count"
MAX_CP_COUNT=5
FILE_BLK_SIZE=1M
FILE_SIZE=10

function SDCARD_Mount() {
	#echo "  SD CARD MOUNT"
	/root/automnt_sda.sh &
	/root/automnt_sdb.sh &
	
	Check_SDA_find;
	Check_SDB_find;
}

function Write_count(){
	if [ -e ${COUNT_PATH}/"$WRITE_COUNT" ]; then
		old_w_count=$(cat ${COUNT_PATH}/$WRITE_COUNT)
		rm ${COUNT_PATH}/"$WRITE_COUNT"
		new_w_count=$(expr $old_w_count + 1);
		echo $new_w_count >> ${COUNT_PATH}/"$WRITE_COUNT"
	else
		echo 1 >> ${COUNT_PATH}/"$WRITE_COUNT"
	fi
}

function Check_SDA_find() {
	SDCARDA_FIND=$(cat /proc/partitions | grep -o 'mmcblk1p1')
	if [ "$SDCARDA_FIND" != "mmcblk1p1" ]; then
		echo "SDCARD A MOUNT error"
		exit 1
	fi
}

function Check_SDB_find() {
	SDCARDB_FIND=$(cat /proc/partitions | grep -o 'mmcblk0p1')
	if [ "$SDCARDB_FIND" != "mmcblk0p1" ]; then
		echo "SDCARD B MOUNT error"
		exit 1
	fi
}


function Check_SDA_Remain_space() {
	sda_remain=$(df |grep $SDA_PATH |awk '{print $4}')
	echo " SD Card A remain space : $sda_remain Byte"
	
	#memory full process
	if (( $sda_remain < ($FILE_SIZE*1024) )); then
		file_full_size=($FILE_SIZE*1024)
		echo "SD card A Remain space $sda_remain byte full: $file_full_size"
		#LogWrite "SD card A Remain space $sda_remain byte"
		[ $EUID -eq 0 ] && [ -e /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches
		
		#memory card clear
		echo "Clear SD card A"
		rm -rf $SDA_PATH* > /dev/null 
		
		# write count clear
		rm ${COUNT_PATH}/"$WRITE_COUNT" > /dev/null 
				
	fi
}

function Check_SDB_Remain_space() {
	sdb_remain=$(df |grep $SDB_PATH |awk '{print $4}')
	echo " SD Card B remain space : $sdb_remain Byte"
	
	#memory full process
	if (( $sdb_remain < ($FILE_SIZE*1024) )); then
		file_full_size=($FILE_SIZE*1024)
		echo "SD card B Remain space $sdb_remain byte full: $file_full_size"
		[ $EUID -eq 0 ] && [ -e /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches
		
		#memory card clear
		echo "Clear SD card B"
		rm -rf $SDB_PATH/* > /dev/null 
		
		# write count clear
		rm ${COUNT_PATH}/"$WRITE_COUNT" > /dev/null 
				
	fi
}

function Generate_Random_file(){
	#Generate Random file 
	TEST_FILE="/root/RANDOM_1.bin"		  
	dd if=/dev/urandom of=$TEST_FILE bs=$FILE_BLK_SIZE count=$FILE_SIZE conv=fsync > /dev/null 2>&1
	TEST_FILE="/root/RANDOM_2.bin"		  
	dd if=/dev/urandom of=$TEST_FILE bs=$FILE_BLK_SIZE count=$FILE_SIZE conv=fsync > /dev/null 2>&1
}

function do_test_SDA() {

	if [ $EUID -ne 0 ]; then
		echo "NOTE: Kernel cache will not be cleared between tests without sudo. This will likely cause inaccurate results." 1>&2
		exit 1
	fi

	for((var=0 ; var < 5 ; var++)); do	   
		Check_SDA_find
		Write_count
				
		file_cnt=$(cat ${COUNT_PATH}/$WRITE_COUNT)
		
		TEST_CP_FILE=${SDA_PATH}/$file_cnt

		#echo " Copy test file $TEST_CP_FILE"
		### [3]copy & compare ###
		# Clear kernel cache to ensure more accurate test
		[ $EUID -eq 0 ] && [ -e /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches
		
		# Create a test file with the specified block size
		dd if=$TEST_FILE of=$TEST_CP_FILE bs=$FILE_BLK_SIZE count=$FILE_SIZE conv=fsync > /dev/null
		if [ $? -ne 0 ]; then
			echo " -SD card A copy Fail : $TEST_CP_FILE"
			exit 1;		
	    fi
		#echo " -$TEST_CP_FILE file copied"
	   # COMPARE FILE 
	   #echo " Compre test file"
	   cmp $TEST_FILE $TEST_CP_FILE > /dev/null
	   if [ $? -ne 0 ]; then
			echo " -SD card File Compare Fail $TEST_CP_FILE"
			exit 1;		
	   fi
	done
}

function do_test_SDB() {

	if [ $EUID -ne 0 ]; then
		echo "NOTE: Kernel cache will not be cleared between tests without sudo. This will likely cause inaccurate results." 1>&2
		exit 1
	fi

	for((var=0 ; var < 5 ; var++)); do	   
		Check_SDB_find
		Write_count
				
		file_cnt=$(cat ${COUNT_PATH}/$WRITE_COUNT)
		
		TEST_CP_FILE=${SDB_PATH}/$file_cnt

		#echo " Copy test file $TEST_CP_FILE"
		### [3]copy & compare ###
		# Clear kernel cache to ensure more accurate test
		[ $EUID -eq 0 ] && [ -e /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches
		
		# Create a test file with the specified block size
		dd if=$TEST_FILE of=$TEST_CP_FILE bs=$FILE_BLK_SIZE count=$FILE_SIZE conv=fsync > /dev/null
		if [ $? -ne 0 ]; then
			echo " -SD card B copy Fail : $TEST_CP_FILE"
			exit 1;		
	    fi
		
		#echo " -$TEST_CP_FILE file copied"
	   # COMPARE FILE 
	   #echo " Compre test file"
	   cmp $TEST_FILE $TEST_CP_FILE > /dev/null
	   if [ $? -ne 0 ]; then
			echo " -SD card File Compare Fail $TEST_CP_FILE"
			exit 1;		
	   fi
	done
}

var=$1
case $var in
    START) 
		echo "TEST $1  version = $VERSION" 
		Generate_Random_file;
		SDCARD_Mount;
		TEST_FILE="/root/RANDOM_1.bin"		  
		do_test_SDA;
		rm ${COUNT_PATH}/"$WRITE_COUNT" > /dev/null 
		#echo "Clear SD card A"
		rm -rf $SDB_PATH/* > /dev/null 
		echo "SD card A SUCCESS"
		echo " "
		echo " "

		TEST_FILE="/root/RANDOM_2.bin"		  
		do_test_SDB;
		rm ${COUNT_PATH}/"$WRITE_COUNT" > /dev/null 
		#echo "Clear SD card B"
		rm -rf $SDB_PATH/* > /dev/null 
		echo "SD card B SUCCESS"
		;;
    MKFILE) 
		echo "Make RANDOM FILE"; 
		Generate_Random_file;
		;;
	CLEAR)
		echo "Clear count file"
		rm $COUNT_PATH/*		
		;;
    *) 
		echo "Wrong option '$1'"; exit 1;;
esac
