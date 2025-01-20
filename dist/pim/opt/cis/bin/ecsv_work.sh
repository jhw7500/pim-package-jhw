#!/bin/bash

LOG_DEBUG="local1.debug"
LOG_INFO="local1.info"
LOG_ERROR="local1.err"

fn_LogWrite() {
    local log_level=$1
    shift
    local log_message="ECSV_WORK|$@"

    logger -p "$log_level" "$log_message"
}

fn_run() {
    #$1 : time
    #$2 : ftype
    local min="";
    local wait_t=0;
    local per=0;
    local min_coeff=85;
    local is_error=0;
    local farray=""

    if [ -z $1 ]; then exit 1; fi
    if [ -z $2 ]; then exit 1; fi

    min=$1;

    if [ $2 == "csv" ]; then
        farray=("/root/shared_v/dump_data/ACC0.csv")
        farray+=("/root/shared_v/dump_data/ADC0.csv")
    elif [ $2 == "csv_v2" ]; then
        farray=("/root/shared_v/dump_data/ACC0.csv")
        farray+=("/root/shared_v/dump_data/ADC0.csv")        
        farray+=("/root/shared_v/dump_data/N_ACC0.acc")
        farray+=("/root/shared_v/dump_data/N_ADC0.adc")
        min_coeff=85
    else
        echo 'ERROR:bad arguments'
        exit 1;
    fi
    
    echo '{"PROGRESS":0,"MSG":"start"}'

    fn_LogWrite $LOG_INFO "start ecsv $min"

    # 1STEP : delete file
    if [ -d "/root/shared_v/dump_data" ]; then
        rm -rf /root/shared_v/dump_data/*
    fi

    if [ -d "/shared/dump_data" ]; then
        rm -rf /shared/dump_data/*
    fi

    # 2STEP : ecsv $time
    ##ecsv $min;
    /usr/bin/docker exec edge python3 main_controller start_datalogging $min > /dev/null 2>&1
    if [ $? -ne 0 ]; then 
        fn_LogWrite $LOG_ERROR "ecsv not excuted"
        echo 'ERROR:ecsv not excuted'
        exit 1; 
    fi
    
    # 3STEP : delay time
    wait_t=`expr $min \* $min_coeff`
    tag_t=`expr $min \* 60`
	for ((i=0;i<wait_t;i++))
	do
        sleep 1
        per=`echo "$i $wait_t"|awk '{printf "%d", (($1+1) * 100) / ($2 +1)}'`
        echo "{\"PROGRESS\":$per,\"MSG\":\"measuring...\"}"
        if [ i == $tag_t ]; then
            fn_LogWrite $LOG_INFO "$min minutes have passed"
        fi
	done
    
    # 4STEP : check file
    for((i=0;i<=10;i++))
    do
        is_error=0
        for var in "${farray[@]}"
        do
            if [ ! -f $var ]; then is_error=1; fi
        done

        if [ ${is_error} -eq 0 ]; then
            break;
        else
            sleep 1
        fi
    done

    if [ ${is_error} -ne 0 ]; then
        fn_LogWrite $LOG_ERROR "files does not exist"
        echo 'ERROR:files does not exist'
        exit 1;
    fi

    # 5STEP : move file 
    mkdir -p "/shared/dump_data"
    chmod 777 "/shared/dump_data"
    for var in "${farray[@]}"
    do
        chmod 666 $var
        mv $var "/shared/dump_data"
    done

    fn_LogWrite $LOG_INFO "Finished"
    echo '{"PROGRESS":100,"MSG":"Finished"}'
}

case $1 in
    fn_run) fn_run $2 $3;;
    *) echo "ERROR:Bad Command"; exit 1;;
esac