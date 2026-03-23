#!/bin/bash

FLAG_PATH="/tmp"
ERR_CNT="ping_err_cnt"
tag=$(basename "$0")
success_value=" 0% packet loss"
timestamp=$(date +"%Y-%m-%d %T,%3N")
DEFAULT_TEST_IP="199.10.100.20"
DEFAULT_MAX_CNT=2
SYSLOG_FAIL_COUNT=5

find_edgeconf_file() {
    local latest=""
    local f

    for f in /root/shared_v/edgeconf_*.json /root/shared_v/backup_edgeconf_*.json; do
        [ -e "$f" ] || continue
        if [ -z "$latest" ] || [ "$f" -nt "$latest" ]; then
            latest="$f"
        fi
    done

    if [ -n "$latest" ]; then
        printf '%s\n' "$latest"
    else
        printf '%s\n' "/etc/defaultconf.json"
    fi
}

reset_eth1_state() {
    rm -f "${FLAG_PATH}/${ERR_CNT}" "${FLAG_PATH}/err_eth1.log"
}

err_count_check() {
    local old_w_count=0

    if [ -e "${FLAG_PATH}/${ERR_CNT}" ]; then
        old_w_count=$(cat "${FLAG_PATH}/${ERR_CNT}")
    fi

    printf '%s\n' "$((old_w_count + 1))" > "${FLAG_PATH}/${ERR_CNT}"
}

CONFIG_FILE=$(find_edgeconf_file)
IFS=$'\t' read -r ping_check_enable test_ip max_cnt < <(
    jq -r '[
        (if .NETWORK.ETH1 | has("ping_check_enable") then .NETWORK.ETH1.ping_check_enable else true end),
        (.NETWORK.ETH1.client_ip_addr // "199.10.100.20"),
        (.NETWORK.ETH1.ping_max_fail_count // 2)
    ] | @tsv' "$CONFIG_FILE" 2>/dev/null || printf 'true\t%s\t%d\n' "$DEFAULT_TEST_IP" "$DEFAULT_MAX_CNT"
)
unset IFS

if [ "$ping_check_enable" != "true" ]; then
    reset_eth1_state
    exit 0
fi

if [ -z "$test_ip" ] || [ "$test_ip" = "null" ]; then
    logger -p local0.notice "[CHK][$tag:$LINENO] ETH1 ping target is empty, skipping check"
    reset_eth1_state
    exit 0
fi

if ! [[ "$max_cnt" =~ ^[0-9]+$ ]]; then
    max_cnt=$DEFAULT_MAX_CNT
fi
if ! [[ "$SYSLOG_FAIL_COUNT" =~ ^[0-9]+$ ]]; then
    syslog_fail_count=$((max_cnt + 1))
else
    syslog_fail_count=$SYSLOG_FAIL_COUNT
fi
error_trigger_count=$((max_cnt + 1))
counter_cap=$error_trigger_count
if [ "$syslog_fail_count" -gt "$counter_cap" ]; then
    counter_cap=$syslog_fail_count
fi

ETH1_PING=$(ping "$test_ip" -c 3 -W 3 -s 1000 2>/dev/null)

if [[ $ETH1_PING != *"$success_value"* ]]; then
    err_count_check
    err_count=$(cat "${FLAG_PATH}/${ERR_CNT}")
    if [ "$err_count" -gt "$max_cnt" ]; then
        printf '%s ETH1 %s PING ERR\n' "$timestamp" "$test_ip" >> "${FLAG_PATH}/err_eth1.log"
    fi
    if [ "$err_count" -eq "$syslog_fail_count" ]; then
        logger -p local0.info "[CHK][$tag:$LINENO] ETH1 ${test_ip} PING ERR accumulated ${err_count}TIME"
    fi
    if [ "$err_count" -gt "$counter_cap" ]; then
        printf '%s\n' "$counter_cap" > "${FLAG_PATH}/${ERR_CNT}"
    fi
else
    reset_eth1_state
fi
