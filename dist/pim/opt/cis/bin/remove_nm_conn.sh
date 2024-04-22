#!/bin/bash

if [ ! -z "$1" ] ;then
  nmcli --fields NAME con show | tr -d ' ' | \
    grep -x "$1" | \
      while read name ;do 
        echo Removing SSID "$name"
        nmcli con delete "$name"
      done
  conn_file="/etc/NetworkManager/system-connections/$1"
  if [ -e $conn_file ]; then
    rm $conn_file
  fi
fi