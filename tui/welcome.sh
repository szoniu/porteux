#!/usr/bin/env bash
# welcome.sh — Welcome screen with prerequisite checks
source "${LIB_DIR}/protection.sh"

screen_welcome() {
    local msg=""
    msg+="Welcome to the ${INSTALLER_NAME} v${INSTALLER_VERSION}\n"
    msg+="\n"
    msg+="This installer will guide you through installing PorteuX\n"
    msg+="to your hard drive or SSD.\n"
    msg+="\n"
    msg+="PorteuX is a Slackware-based modular Linux distribution.\n"
    msg+="It uses squashfs modules (.xzm) with AUFS overlays for\n"
    msg+="a fast, portable, and optionally immutable system.\n"
    msg+="\n"

    # Prerequisite checks
    local -a warnings=()
    local -a errors=()

    # Root check
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        if ! is_root; then
            errors+=("Not running as root")
        fi
    fi

    # EFI check
    if is_efi; then
        msg+="Boot mode: UEFI\n"
    else
        msg+="Boot mode: BIOS (Legacy)\n"
        warnings+=("BIOS boot detected — syslinux will be used")
    fi

    # Network check
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        if has_network; then
            msg+="Network: Connected\n"
        else
            errors+=("No network connectivity (required to download ISO)")
        fi
    fi

    # Dialog backend
    msg+="TUI backend: ${DIALOG_BACKEND:-unknown}\n"

    # Show warnings
    if [[ ${#warnings[@]} -gt 0 ]]; then
        msg+="\n--- Warnings ---\n"
        local w
        for w in "${warnings[@]}"; do
            msg+="  * ${w}\n"
        done
    fi

    # Show errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        msg+="\n--- Errors ---\n"
        local e
        for e in "${errors[@]}"; do
            msg+="  ! ${e}\n"
        done

        if [[ "${FORCE:-0}" != "1" ]]; then
            msg+="\nUse --force to continue despite errors."
            dialog_msgbox "Prerequisites Failed" "${msg}"
            return ${TUI_ABORT}
        else
            msg+="\n--force mode: continuing despite errors."
        fi
    fi

    dialog_msgbox "Welcome" "${msg}"
    return ${TUI_NEXT}
}
