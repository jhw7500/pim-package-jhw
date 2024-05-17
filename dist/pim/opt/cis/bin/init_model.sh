#!/bin/bash

## model feature ##
json_cis_a2='{
    "model_name":"cis-a2",
    "mainboard_type":"plus",
    "daughterboard_type":"analog",
    "iot_app": "sea_app",
    "cam_max_channel": 2,
    "dev": {
        "f_status": 131,
        "f_boot0": 132,
        "c2m_rst": 133,
        "id_0": 496,
        "id_1": 497,
        "id_2": 498,
        "spi": "/dev/spidev2.0",
        "uart": "/dev/ttymxc3",
        "wlan": "wlp1s0",
        "sd": "mmcblk0"
    }
}'

json_cis_c2='{
    "model_name":"cis-c2",
    "mainboard_type":"plus",
    "daughterboard_type":"ethercat",
    "iot_app": "sea_app",
    "cam_max_channel": 0,
    "dev": {
        "f_status": 131,
        "f_boot0": 132,
        "c2m_rst": 133,
        "id_0": 496,
        "id_1": 497,
        "id_2": 498,
        "spi": "/dev/spidev2.0",
        "uart": "/dev/ttymxc3",
        "wlan": "wlp1s0",
        "sd": "mmcblk0"
    }
}'

json_pim_a2='{
    "model_name":"pim-a2",
    "mainboard_type":"plus",
    "daughterboard_type":"analog",
    "iot_app": "none",
    "cam_max_channel": 2,
    "dev": {
        "f_status": 131,
        "f_boot0": 132,
        "c2m_rst": 133,
        "id_0": 496,
        "id_1": 497,
        "id_2": 498,
        "spi": "/dev/spidev2.0",
        "uart": "/dev/ttymxc3",
        "wlan": "wlp1s0",
        "sd": "mmcblk0"
    }
}'

json_pim_c2='{
    "model_name":"pim-c2",
    "mainboard_type":"plus",
    "daughterboard_type":"ethercat",
    "iot_app": "none",
    "cam_max_channel": 0,
    "dev": {
        "f_status": 131,
        "f_boot0": 132,
        "c2m_rst": 133,
        "id_0": 496,
        "id_1": 497,
        "id_2": 498,
        "spi": "/dev/spidev2.0",
        "uart": "/dev/ttymxc3",
        "wlan": "wlp1s0",
        "sd": "mmcblk0"
    }
}'

json_pim_x2='{
    "model_name":"pim-x2",
    "mainboard_type":"plus",
    "daughterboard_type":"none",
    "iot_app": "none",
    "cam_max_channel": 2,
    "dev": {
        "f_status": 131,
        "f_boot0": 132,
        "c2m_rst": 133,
        "id_0": 496,
        "id_1": 497,
        "id_2": 498,
        "spi": "/dev/spidev2.0",
        "uart": "/dev/ttymxc3",
        "wlan": "wlp1s0",
        "sd": "mmcblk0"
    }
}'

json_pim_x4='{
    "model_name":"pim-x4",
    "mainboard_type":"plus",
    "daughterboard_type":"none",
    "iot_app": "none",
    "cam_max_channel": 4,
    "dev": {
        "f_status": 131,
        "f_boot0": 132,
        "c2m_rst": 133,
        "id_0": 496,
        "id_1": 497,
        "id_2": 498,
        "spi": "/dev/spidev2.0",
        "uart": "/dev/ttymxc3",
        "wlan": "wlp1s0",
        "sd": "mmcblk0"
    }
}'

create_model_info() {
    case $1 in
    cis-a2) echo "$json_cis_a2" > /etc/cts/model_info.json;;
    cis-c2) echo "$json_cis_c2" > /etc/cts/model_info.json;;
    pim-a2) echo "$json_pim_a2" > /etc/cts/model_info.json;;
    pim-c2) echo "$json_pim_c2" > /etc/cts/model_info.json;;
    pim-x2) echo "$json_pim_x2" > /etc/cts/model_info.json;;
    pim-x4) echo "$json_pim_x4" > /etc/cts/model_info.json;;
    *) echo "Unknown model $1"; exit 1;;
    esac
}


## main
case $1 in
cis-a2|cis-c2|pim-a2|pim-c2|pim-x2|pim-x4)
    create_model_info $1;;
*) echo "Unknown model $1"; exit 1;;
esac
