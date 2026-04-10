#!/usr/bin/env bash
# persistence_config.sh — PorteuX persistence mode selection
source "${LIB_DIR}/protection.sh"

screen_persistence_config() {
    local msg="PorteuX supports two modes of operation:\n\n"
    msg+="PERSISTENT (changes saved):\n"
    msg+="  All changes to the system (installed apps, settings,\n"
    msg+="  user files) are saved to disk and persist across reboots.\n"
    msg+="  Uses AUFS overlay in /${PORTEUX_CHANGES_DIR}/\n\n"
    msg+="IMMUTABLE (always fresh):\n"
    msg+="  System resets to pristine state on every reboot.\n"
    msg+="  Perfect for kiosks, public terminals, or testing.\n"
    msg+="  User files on separate partitions are not affected.\n"

    local choice
    choice=$(dialog_radiolist "Persistence Mode" "${msg}" \
        "changes" "Persistent — save all changes to disk" "on" \
        "none"    "Immutable — fresh system on every boot" "off") || return ${TUI_BACK}

    export PERSISTENCE_MODE="${choice}"
    einfo "Persistence mode: ${PERSISTENCE_MODE}"

    return ${TUI_NEXT}
}
