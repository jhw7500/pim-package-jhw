#!/bin/bash

#update excute

dpkg -i pim.deb

if [ $? -eq 0 ];then
	echo "dpkg install success!"
else
	echo "dpkg install Failure!"
	exit 1
fi

exit 0;
