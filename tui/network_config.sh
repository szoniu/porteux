#!/usr/bin/env bash
# network_config.sh — Hostname configuration
source "${LIB_DIR}/protection.sh"

screen_network_config() {
    local hostname
    hostname=$(dialog_inputbox "Hostname" "Enter system hostname:" \
        "${HOSTNAME:-porteux}") || return ${TUI_BACK}

    export HOSTNAME="${hostname}"
    einfo "Hostname: ${HOSTNAME}"

    return ${TUI_NEXT}
}
