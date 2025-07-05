#!/bin/bash
# Network Detection Script
# Checks if we're in the home network for backup scheduling

source "$(dirname "$0")/../config/backup.conf"

check_home_network() {
    local gateway_check=false
    local ssid_check=false
    
    # Check default gateway
    if ip route | grep -q "default via $HOME_NETWORK_GATEWAY"; then
        gateway_check=true
    fi
    
    # Check WiFi SSID (if available)
    if command -v nmcli >/dev/null 2>&1; then
        local current_ssid=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
        if [[ "$current_ssid" == "$HOME_NETWORK_SSID" ]]; then
            ssid_check=true
        fi
    else
        # If no nmcli, just rely on gateway
        ssid_check=true
    fi
    
    # Return true if gateway check passes (SSID is optional)
    if $gateway_check; then
        return 0
    else
        return 1
    fi
}

check_internet_connection() {
    # Quick connectivity check
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

case "$1" in
    "home")
        if check_home_network; then
            echo "HOME_NETWORK"
            exit 0
        else
            echo "AWAY_NETWORK"
            exit 1
        fi
        ;;
    "internet")
        if check_internet_connection; then
            echo "INTERNET_AVAILABLE"
            exit 0
        else
            echo "INTERNET_UNAVAILABLE"
            exit 1
        fi
        ;;
    "status")
        if check_home_network; then
            echo "Location: Home Network"
            if check_internet_connection; then
                echo "Internet: Available"
            else
                echo "Internet: Unavailable"
            fi
        else
            echo "Location: Away from Home"
            if check_internet_connection; then
                echo "Internet: Available"
            else
                echo "Internet: Unavailable"
            fi
        fi
        ;;
    *)
        echo "Usage: $0 {home|internet|status}"
        exit 1
        ;;
esac