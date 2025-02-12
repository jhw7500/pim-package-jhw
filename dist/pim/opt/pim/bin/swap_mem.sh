#!/bin/bash

create_swap() {
    sz_str="2G"
    if [[ -n "$1" ]]; then
        sz_str=$1
    fi
    sz_num="${sz_str:0:-1}"
    sz_unit="${sz_str: -1}"
    if [[ "$sz_num" =~ ^[0-9]+$ ]]; then
        case "${sz_unit}" in
            G)
                sz_count=$((sz_num * 1024))
                ;;
            M)
                sz_count=$sz_num
                ;;
            *)
                echo "size is bad string: ${sz_str}"
                exit 0
                ;;
        esac
    else
        echo "size is bad string: ${sz_str}"
        exit 0
    fi

    remove_swap

    fallocate -l "$sz_str" /swapfile > /dev/null 2>&1
    dd if=/dev/zero of=/swapfile bs=1M count="$sz_count" > /dev/null 2>&1
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    sysctl vm.swappiness=10

    TARGET_FILE="/etc/fstab"
    SWAP_LINE="/swapfile            none                 swap       sw                    0  0"
    if [[ -e "$TARGET_FILE" ]] && grep -q "^/swapfile" "$TARGET_FILE"; then
        sed -i "s|^/swapfile.*|$SWAP_LINE|" "$TARGET_FILE"
    else
        echo "$SWAP_LINE" >> "$TARGET_FILE"
    fi

    TARGET_FILE="/etc/sysctl.conf"
    SWAP_LINE="vm.swappiness=10"
    if [[ -e "$TARGET_FILE" ]] && grep -q "^vm\.swappiness" "$TARGET_FILE"; then
        sed -i "s|^vm\.swappiness.*|$SWAP_LINE|" "$TARGET_FILE"
    else
        echo "$SWAP_LINE" >> "$TARGET_FILE"
    fi

}

get_swap_size() {
    swapon --show | awk '/^\/swapfile/ {print $3}'
}

remove_swap() {
    cur_sz_str=$(get_swap_size)
    if [[ -n "$cur_sz_str" ]]; then
        swapoff /swapfile
    fi

    if [[ -e "/swapfile" ]]; then
        rm /swapfile
    fi
    
    TARGET_FILE="/etc/fstab"
    if [[ -e "$TARGET_FILE" ]]; then
        sed -i '/^\/swapfile/d' "$TARGET_FILE"
    fi
    TARGET_FILE="/etc/sysctl.conf"
    if [[ -e "$TARGET_FILE" ]]; then
        sed -i '/^vm\.swappiness/d' "$TARGET_FILE"
    fi
}

case $1 in
    is_size) get_swap_size;;
    remove) remove_swap;;
    create) create_swap $2;;
    *) echo "bad arg"; exit 1;;
esac
