#!/bin/bash
iname=$1
oname=$2
file=/etc/netplan/$3
str=$(grep -r match $file)
if [ -z "$str" ]; then
    echo "      match:" >> $file
fi
str=$(grep -r macaddress $file)
if [ -z "$str" ]; then
    echo "        macaddress:" >> $file
fi
str=$(grep -r set-name $file)
if [ -z "$str" ]; then
    echo "      set-name:" >> $file
fi

mac=$(ifconfig $1 | grep "ether " |awk '{print $2}')
echo $mac
#sed -i '/macaddress/macaddress: $mac/' /etc/netplan/$file
sed -i "/macaddress:/ c\        macaddress: $mac" $file
sed -i "/set-name:/ c\      set-name: $oname" $file

