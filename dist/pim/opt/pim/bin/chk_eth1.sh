#!/bin/bash

FLAG_PATH="/tmp"
ERR_CNT="ping_err_cnt"
tag=$(basename "$0")
success_value=" 0% packet loss"
timestamp=$(date +"%Y-%m-%d %T,%3N")
DEFAULT_MAX_CNT=2
SYSLOG_FAIL_COUNT=5
PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:-/run/pim-camera/config/pim_runtime.json}"

config_invalid() {
    logger -p local0.err "[CHK][$tag:$LINENO] CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    echo "CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" >&2
    exit 64
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

if [ "$#" -eq 3 ]; then
    ping_check_enable=$1
    test_ip=$2
    max_cnt=$3
elif [ "$#" -eq 0 ]; then
    command -v jq >/dev/null 2>&1 || config_invalid
    runtime_values=$(jq -er '
        if type != "object" or
           (.NETWORK | type) != "object" or
           (.NETWORK.ETH1 | type) != "object" or
           (.NETWORK.ETH1.ping_check_enable | type) != "boolean" or
           (.NETWORK.ETH1.client_ip_addr | type) != "string" or
           (.NETWORK.ETH1.ping_max_fail_count | type) != "number" or
           .NETWORK.ETH1.ping_max_fail_count < 0 or
           (.NETWORK.ETH1.ping_max_fail_count | floor) != .NETWORK.ETH1.ping_max_fail_count
        then error("invalid ETH1 runtime config")
        else [
            (.NETWORK.ETH1.ping_check_enable | tostring),
            .NETWORK.ETH1.client_ip_addr,
            (.NETWORK.ETH1.ping_max_fail_count | tostring)
        ]
        | if any(.[]; contains("\u001f"))
          then error("runtime value contains field delimiter")
          else join("\u001f") end
        end
    ' "$PIM_CAMERA_RUNTIME_JSON" 2>/dev/null) || config_invalid
    IFS=$'\x1f' read -r ping_check_enable test_ip max_cnt <<<"$runtime_values"
    unset IFS
else
    echo "usage: $0 [ping_check_enable test_ip max_cnt]" >&2
    exit 64
fi

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
