#!/bin/bash
tag=$(basename "$0")
KEY=PKG
logger -s -p local0.notice "$(printf '\033[33m')[$KEY][$tag:$LINENO] please wait until dependent package installation is finished$(printf '\033[0m')"

while :
do
    pid=$(ps -ef |grep dpkg |grep -v grep |awk '{print $8}')
    if [ -z "$pid" ]; then
        dpkg -i /opt/pim/package/jq/*.deb
        break
    fi
    sleep 1
done

logger -s -p local0.notice "$(printf '\033[33m')[$KEY][$tag:$LINENO] complete dependent package installation$(printf '\033[0m')"
update_edgeconf.sh

#echo -e "\e[33mcomplete install_deb.sh\e[0m"
echo -e "\e[33mif you want the streamApp, run 'update_edgeconf 1', but want the gstApp, run 'update_edgeconf 2'\e[0m"

exit 0
