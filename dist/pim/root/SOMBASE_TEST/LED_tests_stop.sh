#!/bin/bash
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

LED_init
#GREEN_LED_Blinking
#RED_LED_Blinking
#BLUE_LED_Blinking
