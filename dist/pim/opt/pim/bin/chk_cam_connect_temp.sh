#!/bin/bash
TEST_CONFIG_FILE="/root/shared_v/edgeconf_pim.json"
SUCCESS_VAL="0xfa"
CAM0_ERR="0xda"
CAM1_ERR="0xea"
CAM01_ERR="0x16"
CAM2_ERR="0xda"
CAM3_ERR="0xea"
CAM23_ERR="0x16"
timestamp=`date +"%Y-%m-%d %T,%3N"`


#ch0/1 Des check
cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
#ch2/3 Des check
cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)

if [[ "$cam01_res" == *"$SUCCESS_VAL"*  ]]; then
        echo "cam01 ok"
else
        echo "cam01 error"
        #echo "I2cwrite 0x90 0x0010 0x31"
        i2ctransfer -f -y -a 2 w3@0x48 0x00 0x10 0x31
        sleep 1

        #echo "SER0 chk I2cwrite 0x80 0x0010 0x21"
        i2ctransfer -f -y -a 2 w3@0x40 0x00 0x10 0x21
        sleep 1

        if [[ "$cam01_res" == *"$CAM1_ERR"* ]]; then
                echo "CAM1_ERR : $cam01_res"
        fi

        if [[ "$cam01_res" == *"$CAM0_ERR"* ]]; then
                echo "CAM0 ERR : $cam01_res"
        fi

        if [[ "$cam01_res" == *"$CAM01_ERR"* ]]; then
                echo "CAM01_ERR : $cam01_res"
        fi
fi

if [[ "$cam23_res" == *"$SUCCESS_VAL"*  ]]; then
        echo "cam23 ok"
else
        echo "cam23 error"
        #echo "I2cwrite 0x90 0x0010 0x31"
        i2ctransfer -f -y -a 1 w3@0x48 0x00 0x10 0x31
        sleep 1
        #echo "SER1 chk I2cwrite 0x80 0x0010 0x21"
        i2ctransfer -f -y -a 1 w3@0x40 0x00 0x10 0x21
        sleep 1
        if [[ "$cam23_res" == *"$CAM3_ERR"* ]]; then
                echo "CAM3_ERR : $cam23_res"
        fi

        if [[ "$cam23_res" == *"$CAM2_ERR"* ]]; then
                echo "CAM2 ERR : $cam23_res"
        fi

        if [[ "$cam23_res" == *"$CAM23_ERR"* ]]; then
                echo "CAM23_ERR : $cam23_res"
        fi
fi
