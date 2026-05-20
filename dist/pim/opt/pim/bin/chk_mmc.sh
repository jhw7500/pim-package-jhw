#!/bin/bash

tag=$(basename "$0")
RES=$(cat /sys/kernel/debug/mmc2/mmc2:0001/ext_csd)
KEY=MMC
#echo $RES

typea="${RES:536:2}"
typeb="${RES:538:2}"
#echo $typea $typeb
typead=$(echo "ibase=16; $typea"|bc)
typebd=$(echo "ibase=16; $typeb"|bc)
typead=$((typead*10))
typebd=$((typebd*10))
#echo Type A percent:$(($typead*10))%
#echo Type B percent:$(($typebd*10))%
#logger -p local0.notice [$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%
if [ $typead -ge 80 ] || [ $typebd -ge 80 ]
then
    logger -p local0.emerg "[$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%"
elif [ $typead -ge 60 ] || [ $typebd -ge 60 ]
then
    logger -p local0.crit "[$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%"
elif [ $typead -ge 40 ] || [ $typebd -ge 40 ]
then
    logger -p local0.error "[$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%"
else
    logger -p local0.notice "[$KEY][$tag:$LINENO] mmc Type A:$typead% Type B:$typebd%"
fi

max_per1=95
max_per2=90
max_per3=85

TMP_VAR_FILE="/tmp/chk_mmc_var"
VAR_FILE="/var/log/cantops/mmc_mode"
if [[ ! -f "$VAR_FILE" ]]; then
    echo "Initializing variable to default value..."
    echo "MODE=0" > "$VAR_FILE"
fi

source "$VAR_FILE"
logger -p local0.info "[$KEY][$tag:$LINENO] Previous Mode : $MODE"

per=$(df -h |grep /dev/root | awk '{print $5}')
per=$(echo $per | sed 's/%//')
#echo "per:$per, max_per:$max_per"
if (( per > max_per1 && MODE != 4)); then
    #touch /tmp/emmc_warning
    NEW_MODE=4
    logger -p local0.emerg "[$KEY][$tag:$LINENO] New Mode : $NEW_MODE, emmc size $per% > $max_per1"
    logger -p local0.emerg "[$KEY][$tag:$LINENO] rsyslog, journald stop and disable"
    systemctl stop rsyslog
    systemctl stop systemd-journald*
    systemctl disable rsyslog
    echo "MODE=$NEW_MODE" > "$VAR_FILE"
elif (( per > max_per2 && MODE != 3)); then
    NEW_MODE=3
    logger -p local0.emerg "[$KEY][$tag:$LINENO] New Mode : $NEW_MODE, emmc size $per% > $max_per2"
    logger -p local0.emerg "[$KEY][$tag:$LINENO] log level change to err"
    /opt/pim/bin/change_line.sh "local0.err;*.emerg       /var/log/cantops/local0.log" "/var/log/cantops/local0.log" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "*.err;auth,authpriv,local0,kern.none     /var/log/cantops/syslog" "/var/log/cantops/syslog" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "kern.err         /var/log/cantops/kern.log" "/var/log/cantops/kern.log" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "local1.err                /var/log/cantops/local1.log;outfmt2" "/var/log/cantops/local1.log;outfmt2" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "MaxLevelStore=err" "MaxLevelStore" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelSyslog=err" "MaxLevelSyslog" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelKMsg=err" "MaxLevelKMsg" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelConsole=err" "MaxLevelConsole" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelWall=err" "MaxLevelWall" /etc/systemd/journald.conf
    systemctl restart rsyslog
    systemctl restart systemd-journald
    systemctl enable rsyslog
    echo "MODE=$NEW_MODE" > "$VAR_FILE"
elif (( per > max_per3 && MODE != 2)); then
    NEW_MODE=2
    logger -p local0.emerg "[$KEY][$tag:$LINENO] New Mode : $NEW_MODE, emmc size $per% > $max_per3"
    logger -p local0.emerg "[$KEY][$tag:$LINENO] log level change to notice"
    /opt/pim/bin/change_line.sh "local0.notice;*.emerg       /var/log/cantops/local0.log" "/var/log/cantops/local0.log" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "*.notice;auth,authpriv,local0,kern.none     /var/log/cantops/syslog" "/var/log/cantops/syslog" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "kern.notice         /var/log/cantops/kern.log" "/var/log/cantops/kern.log" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "local1.notice                /var/log/cantops/local1.log;outfmt2" "/var/log/cantops/local1.log;outfmt2" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "MaxLevelStore=notice" "MaxLevelStore" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelSyslog=notice" "MaxLevelSyslog" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelKMsg=notice" "MaxLevelKMsg" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelConsole=notice" "MaxLevelConsole" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelWall=notice" "MaxLevelWall" /etc/systemd/journald.conf
    systemctl restart rsyslog
    systemctl restart systemd-journald
    systemctl enable rsyslog
    echo "MODE=$NEW_MODE" > "$VAR_FILE"
elif (( MODE != 1 )); then
    NEW_MODE=1
    logger -p local0.notice "[$KEY][$tag:$LINENO] New Mode : $NEW_MODE, emmc size $per% <= $max_per1%"
    logger -p local0.notice "[$KEY][$tag:$LINENO] log level change (local0 : notice, local1 : all, syslog : all, kern : notice, journald : info)"
    /opt/pim/bin/change_line.sh "local0.notice;*.emerg       /var/log/cantops/local0.log" "/var/log/cantops/local0.log" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "*.*;auth,authpriv,local0,kern.none     /var/log/cantops/syslog" "/var/log/cantops/syslog" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "kern.notice         /var/log/cantops/kern.log" "/var/log/cantops/kern.log" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "local1.*                /var/log/cantops/local1.log;outfmt2" "/var/log/cantops/local1.log;outfmt2" /etc/rsyslog.d/50-default.conf
    /opt/pim/bin/change_line.sh "MaxLevelStore=info" "MaxLevelStore" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelSyslog=info" "MaxLevelSyslog" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelKMsg=info" "MaxLevelKMsg" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelConsole=info" "MaxLevelConsole" /etc/systemd/journald.conf
    /opt/pim/bin/change_line.sh "MaxLevelWall=info" "MaxLevelWall" /etc/systemd/journald.conf
    systemctl restart rsyslog
    systemctl restart systemd-journald
    systemctl enable rsyslog
    echo "MODE=$NEW_MODE" > "$VAR_FILE"
fi

TMP_TEXT=$(cat "$VAR_FILE")
echo "$TMP_TEXT" > "$TMP_VAR_FILE"
