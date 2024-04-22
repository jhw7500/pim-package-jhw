#!/bin/bash

if [ ! -z "{$1}" ] ;then
    python3 /opt/cis/bin/dbuart.py $1
fi
