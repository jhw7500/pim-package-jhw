#!/bin/bash
rmmod imx8-media-dev
rmmod max9296

sleep 2

modprobe max9296
modprobe imx8-media-dev
