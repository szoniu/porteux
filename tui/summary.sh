#!/usr/bin/env bash
# summary.sh — Installation summary and confirmation
source "${LIB_DIR}/protection.sh"

screen_summary() {
    # Validate config first
    local validation_errors
    validation_errors=$(validate_config 2>&1) || true

    if [[ -n "${validation_errors}" ]]; then
        dialog_msgbox "Configuration Errors" \
            "Please fix these issues before proceeding:\n\n${validation_errors}"
        return ${TUI_BACK}
    fi

    # Build summary
    local summary=""
    summary+="=== PorteuX Installation Summary ===\n\n"

    # Disk
    summary+="DISK & PARTITIONING\n"
    summary+="  Target disk:    ${TARGET_DISK:-?}\n"
    summary+="  Scheme:         ${PARTITION_SCHEME:-auto}\n"
    summary+="  Filesystem:     ${FILESYSTEM:-ext4}\n"
    summary+="  ESP:            ${ESP_PARTITION:-auto}\n"
    summary+="  Root:           ${ROOT_PARTITION:-auto}\n"
    [[ -n "${SWAP_TYPE:-}" && "${SWAP_TYPE}" != "none" ]] && \
        summary+="  Swap:           ${SWAP_TYPE} (${SWAP_SIZE_MIB:-?} MiB)\n"
    summary+="\n"

    # Desktop
    summary+="PORTEUX VARIANT\n"
    summary+="  Desktop:        ${DESKTOP_VARIANT:-kde}\n"
    summary+="  Display server: ${DISPLAY_SERVER:-auto}\n"
    summary+="  Boot mode:      ${BOOT_MODE:-normal}\n"
    summary+="  Persistence:    ${PERSISTENCE_MODE:-changes}\n"
    summary+="\n"

    # GPU
    if [[ -n "${GPU_VENDOR:-}" && "${GPU_VENDOR}" != "unknown" ]]; then
        summary+="GPU\n"
        summary+="  Vendor:         ${GPU_VENDOR}\n"
        summary+="  Device:         ${GPU_DEVICE_NAME:-?}\n"
        [[ "${NVIDIA_MODULE:-no}" == "yes" ]] && \
            summary+="  NVIDIA module:  yes (will be downloaded)\n"
        summary+="\n"
    fi

    # Optional modules
    local modules_list=""
    [[ "${ENABLE_DEVEL_MODULE:-no}" == "yes" ]]    && modules_list+="05-devel "
    [[ "${ENABLE_MULTILANG_MODULE:-no}" == "yes" ]] && modules_list+="08-multilanguage "
    [[ "${ENABLE_MULTILIB_MODULE:-no}" == "yes" ]]  && modules_list+="0050-multilib-lite "
    if [[ -n "${modules_list}" ]]; then
        summary+="OPTIONAL MODULES\n"
        summary+="  ${modules_list}\n\n"
    fi

    # System
    summary+="SYSTEM\n"
    summary+="  Hostname:       ${HOSTNAME:-porteux}\n"
    summary+="  Timezone:       ${TIMEZONE:-UTC}\n"
    summary+="  Locale:         ${LOCALE:-en_US.UTF-8}\n"
    summary+="  Keymap:         ${KEYMAP:-us}\n"
    summary+="\n"

    # User
    summary+="USER\n"
    summary+="  Username:       ${USERNAME:-user}\n"
    summary+="  Groups:         ${USER_GROUPS:-wheel,audio,video}\n"
    summary+="\n"

    # Dual-boot
    if [[ "${PARTITION_SCHEME:-}" == "dual-boot" ]]; then
        summary+="DUAL-BOOT\n"
        if [[ -n "${DETECTED_OSES_SERIALIZED:-}" ]]; then
            summary+="  Detected OS:    ${DETECTED_OSES_SERIALIZED}\n"
        fi
        summary+="  ESP reuse:      ${ESP_REUSE:-yes}\n"
        summary+="\n"
    fi

    # Warnings
    if [[ "${PARTITION_SCHEME:-auto}" == "auto" ]]; then
        summary+="!!! WARNING: All data on ${TARGET_DISK:-?} will be DESTROYED !!!\n\n"
    fi

    dialog_msgbox "Installation Summary" "${summary}"

    # Confirmation
    if [[ "${PARTITION_SCHEME:-auto}" == "auto" ]]; then
        local confirm
        confirm=$(dialog_inputbox "Confirm" \
            "Type YES to confirm installation.\n\nAll data on ${TARGET_DISK:-?} will be permanently erased." \
            "") || return ${TUI_BACK}

        if [[ "${confirm}" != "YES" ]]; then
            dialog_msgbox "Cancelled" "Installation cancelled."
            return ${TUI_BACK}
        fi
    else
        if ! dialog_yesno "Confirm" "Proceed with installation?"; then
            return ${TUI_BACK}
        fi
    fi

    # Countdown
    if [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
        countdown ${COUNTDOWN_DEFAULT}
    fi

    return ${TUI_NEXT}
}
