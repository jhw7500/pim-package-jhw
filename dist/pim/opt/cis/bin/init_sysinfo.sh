#!/bin/bash

## default sysinfo ##
default_sysinfo_cis_a2='{
    "hostname":"cis-camera-v003",
    "mainboard_version":"V0.3",
    "daughterboard_version":"V0.2"
}'

default_sysinfo_cis_c2='{
    "hostname":"cis-c2-v001",
    "mainboard_version":"V0.3",
    "daughterboard_version":""
}'

default_sysinfo_pim_a2='{
    "hostname":"pim-a2-V001",
    "mainboard_version":"V0.3",
    "daughterboard_version":"V0.2"
}'

default_sysinfo_pim_c2='{
    "hostname":"pim-c2-V001",
    "mainboard_version":"V0.3",
    "daughterboard_version":""
}'

default_sysinfo_pim_x2='{
    "hostname":"pim-x2-V001",
    "mainboard_version":"V0.3",
    "daughterboard_version":""
}'

default_sysinfo_pim_x4='{
    "hostname":"pim-camera-v016",
    "mainboard_version":"V0.3",
    "daughterboard_version":""
}'

create_sysinfo() {
    case $1 in
    cis-a2) echo "$default_sysinfo_cis_a2" > /etc/cts/sysinfo.json;;
    cis-c2) echo "$default_sysinfo_cis_c2" > /etc/cts/sysinfo.json;;
    pim-a2) echo "$default_sysinfo_pim_a2" > /etc/cts/sysinfo.json;;
    pim-c2) echo "$default_sysinfo_pim_c2" > /etc/cts/sysinfo.json;;
    pim-x2) echo "$default_sysinfo_pim_x2" > /etc/cts/sysinfo.json;;
    pim-x4) echo "$default_sysinfo_pim_x4" > /etc/cts/sysinfo.json;;
    *) echo "Unknown model $1"; exit 1;;
    esac
}

## main
case $1 in
cis-a2|cis-c2|pim-a2|pim-c2|pim-x2|pim-x4)
    create_sysinfo $1
    ;;
*) 
    if [ ! -f /etc/cts/sysinfo.json ]; then
        model=$(python3 /opt/cis/bin/getconfval.py model_name | tr -d '\r\n')
        create_sysinfo $model
    fi
    ;;
esac
