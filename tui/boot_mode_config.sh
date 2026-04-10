#!/usr/bin/env bash
# boot_mode_config.sh — PorteuX default boot mode selection
source "${LIB_DIR}/protection.sh"

screen_boot_mode_config() {
    local msg="Select the default boot mode for PorteuX:\n"

    local choice
    choice=$(dialog_radiolist "Boot Mode" "${msg}" \
        "normal"  "Normal — graphical desktop with persistence"       "on" \
        "copy2ram" "Copy to RAM — load entire system to memory"       "off" \
        "fresh"   "Always Fresh — ignore saved changes at boot"       "off" \
        "text"    "Text Mode — console only (runlevel 3)"             "off") || return ${TUI_BACK}

    export BOOT_MODE="${choice}"
    einfo "Boot mode: ${BOOT_MODE}"

    if [[ "${BOOT_MODE}" == "copy2ram" ]]; then
        dialog_msgbox "Copy to RAM" \
            "Copy to RAM mode loads the entire system into memory.\n\n\
This means:\n\
  + Faster operation after initial boot\n\
  + Source media can be removed after boot\n\
  - Slower initial boot (copies all modules to RAM)\n\
  - Requires sufficient RAM (recommended: 4+ GB)"
    fi

    return ${TUI_NEXT}
}
