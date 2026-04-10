#!/usr/bin/env bash
# network.sh — Network checks
source "${LIB_DIR}/protection.sh"

# check_network — Verify network connectivity
check_network() {
    einfo "Checking network connectivity..."

    if has_network; then
        einfo "Network connectivity OK"
        return 0
    else
        eerror "No network connectivity"
        return 1
    fi
}
