#!/bin/bash
LOG_PATH="/opt/pim/bin/chk_log"
TEST_RESULT=0;


function CLEAR_CHK_LOG() {
    rm ${LOG_PATH}/*.*
}

CLEAR_CHK_LOG
while true; do
    #cam connect check
    /opt/pim/bin/chk_cam_connect.sh
    #wifi check
    /opt/pim/bin/chk_wifi.sh
    #eth0 check
    /opt/pim/bin/chk_eth0.sh
    #sd mount check
    /opt/pim/bin/chk_sd_mount.sh
    #cpu temp check
    /opt/pim/bin/chk_cpu_temp.sh
    #power check
    /opt/pim/bin/chk_voltage.sh

    sleep 5
done
