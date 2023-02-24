#!/bin/bash
LOG_PATH="/opt/pim/bin/chk_log"
TEST_RESULT=0;

function LED_init(){
	#ALL LED OFF
	echo none > /sys/devices/platform/leds/leds/gpio1_led/trigger
	echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
	echo none > /sys/devices/platform/leds/leds/gpio2_led/trigger
	echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
	echo none > /sys/devices/platform/leds/leds/gpio3_led/trigger
	echo 0 > /sys/devices/platform/leds/leds/gpio3_led/brightness
}

function GREEN_LED_Blinking(){
	echo heartbeat > /sys/devices/platform/leds/leds/gpio2_led/trigger
}

function RED_LED_Blinking(){
	echo heartbeat > /sys/devices/platform/leds/leds/gpio1_led/trigger
}

function BLUE_LED_Blinking(){
	echo heartbeat > /sys/devices/platform/leds/leds/gpio3_led/trigger
}

function CLEAR_CHK_LOG() {
    rm ${FLAG_PATH}/*.*
}


function LED_CTRL(){
    if [ -e ${FLAG_PATH}/err_cam0.log ]; then
        TEST_RESULT=1
        #green off
	    echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red 0.2s on 2s off
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 2
    fi
    if [ -e ${FLAG_PATH}/err_cam1.log ]; then
        TEST_RESULT=1
        #green off
	    echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red 0.2s x2 on/off 2s off
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 2
    fi
    if [ -e ${FLAG_PATH}/err_cam2.log ]; then
        TEST_RESULT=1
        #green off
	    echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red 0.2s x3 on/off 2s off
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 2
    fi
    if [ -e ${FLAG_PATH}/err_cam3.log ]; then
        TEST_RESULT=1
        #green off
	    echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red 0.2s x4 on/off 2s off
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 2
    fi
    if [ -e ${FLAG_PATH}/err_wifi.log ]; then
        TEST_RESULT=1
        #green red on 0.5s off 0.5s
        echo 1 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
    fi
    if [ -e ${FLAG_PATH}/err_eth0.log ]; then
        TEST_RESULT=1
        #grenn on 
        echo 1 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red on 0.5s off 0.5s
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
    fi
    if [ -e ${FLAG_PATH}/err_sdcard.log ]; then
        TEST_RESULT=1
        #green off
	    echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red 0.2s x5 on/off 2s off
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 2
    fi
    if [ -e ${FLAG_PATH}/err_cpu_temp.log ]; then
        TEST_RESULT=1
        #grenn off red on 0.5s off 0.5s
        echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
    fi
    if [ -e ${FLAG_PATH}/err_volt.log ]; then
        TEST_RESULT=1
        #grenn off red on 0.5s off 0.5s
        echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 1
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 1
    fi

    #normal process
    if [ $TEST_RESULT -eq 0 ]; then
        #red off
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        #red on 0.5s off 0.5s
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
    fi
}



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

    #led control
    LED_CTRL
    sleep 5
done