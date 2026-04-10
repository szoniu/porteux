#!/usr/bin/env bash
# swap_config.sh — Swap configuration
source "${LIB_DIR}/protection.sh"

screen_swap_config() {
    local choice
    choice=$(dialog_radiolist "Swap Configuration" "Select swap method:" \
        "none"      "No swap (PorteuX is lightweight)"         "on" \
        "partition" "Swap partition (traditional disk swap)"    "off" \
        "file"      "Swap file on root partition"              "off") || return ${TUI_BACK}

    export SWAP_TYPE="${choice}"
    einfo "Swap type: ${SWAP_TYPE}"

    if [[ "${SWAP_TYPE}" == "partition" || "${SWAP_TYPE}" == "file" ]]; then
        local size
        size=$(dialog_inputbox "Swap Size" \
            "Enter swap size in MiB:" \
            "${SWAP_SIZE_MIB:-${SWAP_DEFAULT_SIZE_MIB}}") || return ${TUI_BACK}

        export SWAP_SIZE_MIB="${size}"
        einfo "Swap size: ${SWAP_SIZE_MIB} MiB"
    fi

    return ${TUI_NEXT}
}
