#!/bin/bash

PIM_DEB_FILE="pim-mp-xxx.deb"
DB_ANAL_FIRMWARE_VER="1.0.1"
DB_ANAL_FIRMWARE_FILE="cis-daxx_1.0.1.hex"
DB_ECAT_FIRMWARE_VER="1.0.1"
DB_ECAT_FIRMWARE_FILE="cis-dcxx_1.0.1.hex"
DB_TYPE="none"
tag=$(basename "$0")
KEY=PKG

function get_mainboard_type() {
    local cpu_name=$(cat /proc/device-tree/model | cut -d' ' -f2 )
    if [ "${cpu_name}" == "i.MX8MPlus" ]; then
        echo "plus"
    else
        echo "mini"
    fi
}

function get_daughter_type() {
    local dbid_gpio=(496 497 498)
    local sum_id0=0
    local sum_id1=0
    local sum_id2=0
    local id=0
    local type=""

    #gpio init
    for var in "${dbid_gpio[@]}"
    do
        #gpio export
        if [ ! -d "/sys/class/gpio/gpio$var" ] ; then
            echo $var > /sys/class/gpio/export
        fi

        #gpio input direction
        echo in > /sys/class/gpio/gpio$var/direction
    done

    #gpio read
    for i in {0..9}
    do
        if [ $(cat /sys/class/gpio/gpio${dbid_gpio[0]}/value) == 1 ]; then
            sum_id0=`expr $sum_id0 + 1`
        fi

        if [ $(cat /sys/class/gpio/gpio${dbid_gpio[1]}/value) == 1 ]; then
            sum_id1=`expr $sum_id1 + 1`
        fi

        if [ $(cat /sys/class/gpio/gpio${dbid_gpio[2]}/value) == 1 ]; then
            sum_id2=`expr $sum_id2 + 1`
        fi
    done

    if [ $sum_id0 -ge 5 ]; then
        id=`expr $id + 1`
    fi

    if [ $sum_id1 -ge 5 ]; then
        id=`expr $id + 2`
    fi

    if [ $sum_id2 -ge 5 ]; then
        id=`expr $id + 4`
    fi

    #   ID[0:2]
    #ANAL: 000
    #ECAT: 100
    if [ $id -eq 0 ]; then
        type="analog"
    elif [ $id -eq 1 ]; then
        type="ethercat"
    else
        type="none"
    fi

    echo "$type"
}

function get_edge_id() {
    local cnt=0
	docker ps -a -f "name=edge" --format "table {{.ID}}\t{{.Image}}\t{{.Status}}" | while read line;
	do
	if [ $cnt -ge 1 ]; then 
        local name=`echo $line | cut -d' ' -f2`
        if [[ ${name} == "sea_app:latest" ]]; then
            echo $line
            break;
        fi
	fi
	cnt=`expr $cnt + 1`
	done
}

function check_installed_sea() {
    local ret=0
    local active=$(systemctl is-active docker 2>/dev/null)
    if [ "${active}" == "active" ]; then
        local edge_id=`echo $(get_edge_id) | cut -d' ' -f1`
        if [ ! -z "${edge_id}" ]; then
            ret=1
        fi
    fi
    echo "$ret"
}

function suggest_suitable_model() {
    if [ "$(check_installed_sea)" == "1" ]; then
        if [ "$(get_daughter_type)" == "ethercat" ]; then
            echo "cis-c2"
        else
            echo "cis-a2"
        fi
    else
        echo "pim-x4"
    fi
}

function set_db_uartmon() {
    if [ ! -z "$1" ] ;then
        /usr/local/bin/dbuart "<SETUARTMON,$1>" > /dev/null 2>&1
    fi
}

function get_db_version() {
    str=`/usr/local/bin/dbuart '<GETVER>' | grep 'GETVER'`
    if [ -z $str ]; then
        return
    else
        echo $str | tr -d '[]' | cut -d',' -f2 | tr -d ' '
    fi
}

function get_pim_model() {
	debconf-show pim-mp 2>/dev/null | cut -d':' -f2 | tr -d ' '
}

cd `dirname "$0"`
BASEDIR=${PWD}
echo '{"PROGRESS":1,"MSG":"Begin upgrade"}'

if [ "$(get_mainboard_type)" != "plus" ]; then
    echo '{"PROGRESS":100,"MSG":"Error, Bad mainboard_type"}'
	exit 0
fi

########################################
## Install dependency packages        ##
########################################

${BASEDIR}/install_deb.sh

########################################
## Remove old cis package             ##
########################################
if [ -n "$(dpkg -s cis 2> /dev/null)" ]; then 
  echo '{"PROGRESS":10,"MSG":"Start deleting the cis package."}'
  set_db_uartmon 0
  adab stop > /dev/null 2> /dev/null
  dbmon stop > /dev/null 2> /dev/null
  wifim stop > /dev/null 2> /dev/null
  automnt stop > /dev/null 2> /dev/null
  longrun stop > /dev/null 2> /dev/null
  systemctl disable pre-reboot-custom.service > /dev/null 2> /dev/null
  systemctl disable run-watchdog-custom.service > /dev/null 2> /dev/null
  crontab -r > /dev/null 2> /dev/null
  service cron restart > /dev/null 2> /dev/null
  rm /etc/defaultconf.json > /dev/null 2> /dev/null
  rm -rf /var/cis/log > /dev/null 2> /dev/null
  rmdir /var/cis  > /dev/null 2> /dev/null 
  dpkg --purge cis > /dev/null 2> /dev/null
  echo '{"PROGRESS":19,"MSG":"End deleting the cis package."}'
fi

########################################
## Check model                        ##
########################################
echo '{"PROGRESS":20,"MSG":"check model"}'

model=$(get_pim_model)
if [ -z "$model" ] || [ "$model" == "none" ]; then
    model=$(suggest_suitable_model)
    echo "pim-mp pim-mp/model select $model" | debconf-set-selections
fi

echo '{"PROGRESS":21,"MSG":"model='"$model"'"}'
if [[ "$model" == *-a* ]]; then
	DB_TYPE="analog"
	DB_FIRMWARE_VER=$DB_ANAL_FIRMWARE_VER
	DB_FIRMWARE_FILE=$DB_ANAL_FIRMWARE_FILE
elif [[ "$model" == *-c* ]]; then
	DB_TYPE="ethercat"
	DB_FIRMWARE_VER=$DB_ECAT_FIRMWARE_VER
	DB_FIRMWARE_FILE=$DB_ECAT_FIRMWARE_FILE
else
	DB_TYPE="none"
fi

########################################
## Install PIM-MP package             ##
########################################

if [ "$(check_installed_sea)" == "1" ]; then
    echo '{"PROGRESS":22,"MSG":"docker stop edge"}'
    docker stop edge > /dev/null 2> /dev/null
fi

if systemctl is-active --quiet pim-gate; then
    echo '{"PROGRESS":22,"MSG":"stop pim-gate"}'
    systemctl stop pim-gate 1> /dev/null 2>&1
fi

case $model in
cis-a2|cis-a4|cis-c2|pim-a2|pim-a4|pim-c2)
  echo '{"PROGRESS":22,"MSG":"stop adab"}'
  # iot관련 앱을 종료한다.
  adab stop > /dev/null 2> /dev/null
  dbmon stop > /dev/null 2> /dev/null
  wifim stop > /dev/null 2> /dev/null
  automnt stop > /dev/null 2> /dev/null
  longrun stop > /dev/null 2> /dev/null	
  set_db_uartmon 0
  ;;
esac

echo '{"PROGRESS":23,"MSG":"Start install pim-mp"}'
dpkg -i $PIM_DEB_FILE > /dev/null 2> /dev/null
echo '{"PROGRESS":24,"MSG":"End install pim-mp"}'

########################################
## Upgrade daughter board firmware    ##
########################################
if [ "$DB_TYPE" != "none" ]; then
  echo '{"PROGRESS":24,"MSG":"CHECK, daughter board firmware"}'
  /opt/cis/bin/init_daughter_gpio.sh > /dev/null 2> /dev/null
  sleep 1
  cur_db_type=$(get_daughter_type)
  if [ "$DB_TYPE" == "$cur_db_type" ]; then
    dbver=$(get_db_version)
    if [[ "$dbver" != "$DB_FIRMWARE_VER" ]]; then
  	  stm32update -b 24 -e 94 $DB_FIRMWARE_FILE
  	  echo '{"PROGRESS":95,"MSG":"Wait for Daughter board boot"}'
  	  sleep 1
  	  echo '{"PROGRESS":96,"MSG":"Update Daughter board version"}'
  	  python3 /opt/cis/bin/dbver.py > /dev/null
    else
      echo '{"PROGRESS":24,"MSG":"daughter board firmware already '$dbver'"}'
      sleep 1
    fi
  else
    echo '{"PROGRESS":24,"MSG":"Warning, daughter board type mismatch('$DB_TYPE'!='$cur_db_type')"}'
    sleep 1
  fi
fi

########################################
## Excute APP                         ##
########################################
case $model in
cis-a2|cis-a4|cis-c2|pim-a2|pim-a4|pim-c2)
  # iot관련 앱을 실행한다.
  python3 /opt/cis/bin/init.py power_on > /dev/null 2> /dev/null
  adab start > /dev/null 2> /dev/null
  dbmon start > /dev/null 2> /dev/null
  wifim start > /dev/null 2> /dev/null
  automnt start > /dev/null 2> /dev/null
  set_db_uartmon 1
  echo '{"PROGRESS":99,"MSG":"start adab"}'
  ;;
esac

case "$model" in
"cis-"*)
    echo '{"PROGRESS":99,"MSG":"docker start edge"}'
    docker start edge > /dev/null 2> /dev/null
    ;;
*)
    if systemctl is-enabled --quiet pim-gate; then
        echo '{"PROGRESS":99,"MSG":"start pim-gate"}'
        systemctl start pim-gate 1> /dev/null 2>&1
    fi
    ;;
esac

service="vsd"
pid=$(ps -ef |grep "$service" |grep -v grep |awk '{print $2}')
if [ ! -n "$pid" ]; then
  #echo "no" >/dev/null
  #sleep 0.5
  logger -p local0.emerg "[$KEY][$tag:$LINENO] $service start"
  nohup $service 1>/dev/null 2>&1 &
fi

echo "PIM_DEB_FILE     : $PIM_DEB_FILE" > /root/fwupgrade/version.txt
echo "DB_FIRMWARE_FILE : $DB_ANAL_FIRMWARE_FILE" >> /root/fwupgrade/version.txt
echo '{"PROGRESS":100,"MSG":"Finished"}'
