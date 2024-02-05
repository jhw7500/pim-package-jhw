#!/bin/bash
while :
do
    pid=$(ps -ef |grep dpkg |grep -v grep |awk '{print $8}')
    if [ -z "$pid" ]; then
        dpkg -i /opt/pim/package/jq/*.deb
        break
    fi
    sleep 1
done
echo "install_deb.sh complete"
exit 0
