#!/bin/bash
FLAG_PATH="/tmp"
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

function BG_CHK_LED_init(){
	#red, green LED OFF
	echo none > /sys/devices/platform/leds/leds/gpio1_led/trigger
	echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
	echo none > /sys/devices/platform/leds/leds/gpio2_led/trigger
	echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
    sleep 2
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

function LED_CTRL(){
	TEST_RESULT=0;    
	
	if [ -e ${FLAG_PATH}/err_cam0.log ]; then
        TEST_RESULT=1
        #green off
		echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red 0.2s on 2s off
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.2
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 1.8
		BG_CHK_LED_init
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
        sleep 1.4
		BG_CHK_LED_init
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
        sleep 1
		BG_CHK_LED_init
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
        sleep 0.6
		BG_CHK_LED_init
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
		echo 1 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
		BG_CHK_LED_init
    fi
	
    
	if [ -e ${FLAG_PATH}/err_eth1.log ]; then
        TEST_RESULT=1
        #grenn on 
        echo 1 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        #red on 0.5s off 0.5s
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
		echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
		BG_CHK_LED_init
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
        sleep 0.2
		BG_CHK_LED_init
    fi
	
	
    if [ -e ${FLAG_PATH}/err_cpu_temp.log ]; then
        TEST_RESULT=1
        #grenn off
        echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
		#red on 0.5s, off 0.5s
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
		echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 0.5
		BG_CHK_LED_init
    fi
	
	
    if [ -e ${FLAG_PATH}/err_volt.log ]; then
        TEST_RESULT=1
        #green off
        echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
		#red on 1s, off 1s
        echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 1
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        sleep 1
		BG_CHK_LED_init
    fi
	
	if [ -e ${FLAG_PATH}/wifi_connected.log ]; then
		BLUE_LED_Blinking()
	else 
		echo none > /sys/devices/platform/leds/leds/gpio3_led/trigger
		echo 0 > /sys/devices/platform/leds/leds/gpio3_led/brightness
	fi
	
	
    #normal process
    if [ $TEST_RESULT -eq 0 ]; then
        #red off
        echo 0 > /sys/devices/platform/leds/leds/gpio1_led/brightness
        #GREEN on 0.5s off 0.5s
        echo 1 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        sleep 0.5
        echo 0 > /sys/devices/platform/leds/leds/gpio2_led/brightness
        sleep 0.5
    fi
}

LED_init
LED_CTRL
