#!/bin/bash


function Check_Installed_Image() {
    ## sea_app:latest의 IMAGE ID 확인#
    latest_image_id=$(docker images | awk '$1=="sea_app" && $2=="latest" {print $3}')
    if [ -z ${latest_image_id} ]; then
        echo "NO_IMAGE"
        exit 1
    fi

    ## latest_image_id와 동일한 IMAGE ID를 가진 sea_app버전 확인 ##
    image_ver=$(docker images | awk -v imgid="$latest_image_id" '$1=="sea_app" && $2!="latest" && $3==imgid {print $1 "," $2}')
    if [ -z ${image_ver} ]; then
        echo "INVALID_IMAGE_TAG"
        exit 1
    fi

    #echo "sea_app,1.1.5"
    echo "$image_ver"
}

function Get_Edge_Container() {
    cnt=0
	docker ps -a -f "name=edge" --format "table {{.ID}}\t{{.Image}}\t{{.Status}}" | while read line;
	do
	if [ $cnt -ge 1 ]; then 
        name=`echo $line | cut -d' ' -f2`
        if [[ ${name} == "sea_app:latest" ]]; then
            echo $line
            break;
        fi
	fi
	cnt=`expr $cnt + 1`
	done
}

function Check_Edge_Container() {
    ## Edge 설치여부 확인  ##
    edge_info="$(Get_Edge_Container)"
    edge_id=`echo ${edge_info} | cut -d' ' -f1`
    if [ -z ${edge_id} ]; then
        echo "NO_EDGE"
        exit 1
    fi

    edge_ver="$(cat /root/shared_v/version.txt 2> /dev/null)"
    edge_status=`echo ${edge_info} | cut -d' ' -f3`
    if [ ${edge_status} == "Up" ]; then
        edge_status="run"
    elif [ ${edge_status} == "Exited" ]; then
        edge_status="stop"
    fi

    echo "$edge_ver $edge_status"
}

function Check_Edge_Status() {
    edge_info="$(Get_Edge_Container)"
    edge_status=`echo ${edge_info} | cut -d' ' -f3`
    echo "$edge_status"
}

function GET_EDGE_STATUS() {
    edge_="$(Check_Edge_Container)"
    edge_status=`echo ${edge_} | cut -d' ' -f2`
    edge_id=`echo ${edge_} | cut -d' ' -f1`
    image_id="$(Check_Installed_Image)"
    echo "DATA:{\"Status\":\"${edge_status}\",\"Edge Version\":\"${edge_id}\",\"Image Version\":\"${image_id}\"}"
}

function EDGE_START() {
    edge_="$(Check_Edge_Container)"
    edge_id=`echo ${edge_} | cut -d' ' -f1`

    if [ ${edge_id} == "NO_EDGE" ]; then
        echo "ERROR:NO_EDGE"
        exit 1
    fi

    /usr/bin/docker start edge > /dev/null 2>&1
    if [ $? -ne 0 ]; then 
        echo 'ERROR:docker start edge'
        exit 1;
    fi

    wait_t=60
	for ((i=0;i<wait_t;i++))
	do
        edge_="$(Check_Edge_Container)"
        edge_status=`echo ${edge_} | cut -d' ' -f2`
        if [ ${edge_status} == "run" ]; then
            break
        fi
        sleep 1
        per=`echo "$i $wait_t"|awk '{printf "%d", (($1+1) * 100) / ($2 +1)}'`
        echo "{\"PROGRESS\":$per,\"MSG\":\"wait Up...\"}"
	done

    edge_="$(Check_Edge_Container)"
    edge_status=`echo ${edge_} | cut -d' ' -f2`
    if [ ${edge_status} != "run" ]; then
        echo "ERROR:time_out"
        exit 1
    fi
}

function EDGE_STOP() {
    edge_="$(Check_Edge_Container)"
    edge_id=`echo ${edge_} | cut -d' ' -f1`

    if [ ${edge_id} == "NO_EDGE" ]; then
        echo "ERROR:NO_EDGE"
        exit 1
    fi

    /usr/bin/docker stop edge > /dev/null 2>&1
    if [ $? -ne 0 ]; then 
        echo 'ERROR:docker stop edge'
        exit 1;
    fi

    wait_t=60
	for ((i=0;i<wait_t;i++))
	do
        edge_="$(Check_Edge_Container)"
        edge_status=`echo ${edge_} | cut -d' ' -f2`
        if [ ${edge_status} == "stop" ]; then
            break
        fi
        sleep 1
        per=`echo "$i $wait_t"|awk '{printf "%d", (($1+1) * 100) / ($2 +1)}'`
        echo "{\"PROGRESS\":$per,\"MSG\":\"wait Up...\"}"
	done

    edge_="$(Check_Edge_Container)"
    edge_status=`echo ${edge_} | cut -d' ' -f2`
    if [ ${edge_status} != "stop" ]; then
        echo "ERROR:time_out"
        exit 1
    fi
}

case $1 in
    GET_EDGE_STATUS ) $1 ;;
    EDGE_START | EDGE_STOP ) $1 ;;
    
    *) echo "ERROR:Bad Command"; exit 1;;
esac

