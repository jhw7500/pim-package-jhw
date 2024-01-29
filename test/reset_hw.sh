#!/usr/bin/env bash
gpioset gpiochip0 8=0
gpioset gpiochip0 9=0
sleep 0.5
gpioset gpiochip0 1=0
sleep 1
gpioset gpiochip0 1=1
sleep 0.5
gpioset gpiochip0 8=1
gpioset gpiochip0 9=1
