#!/bin/bash

serial_port="/dev/ttySC0"
#serial_port="/dev/ttySC1"

#stty -F "$serial_port" 115200 cs8 -cstopb -parenb -icanon min 1 time 1
#stty -F "$serial_port" 115200
stty -F "$serial_port" -echo -onlcr 115200
#stty -F "$serial_port" -echo 115200

echo "Loopback test on $serial_port"

while true; do
    read -p "Enter data to send (or 'exit' to quit): " data
    if [ "$data" == "exit" ]; then
        break
    fi
    #read -t 1 received_data < "$serial_port" &
    #received_data=$(head -n 1 < "$serial_port" &)
    head -n 1 < "$serial_port" &
    #received_data=$(head -n 1 < "$serial_port") &
    echo "$data" > "$serial_port"
    echo recevied
    sleep 0.5
    #read -t 1 received_data < "$serial_port"
    #echo "Received: $received_data"
done

echo "Exiting loopback test"
