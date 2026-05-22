#!/usr/bin/env bash
# welcome.sh — Welcome screen with prerequisite checks
source "${LIB_DIR}/protection.sh"

screen_welcome() {
    # Architecture gate — checked FIRST, before anything touches the disk. This
    # installer is x86_64 only; on aarch64/ARM (Surface Laptop 7 / Snapdragon X,
    # ARM laptops & SBCs) it would wipe the disk, download an x86_64 ISO, then
    # fail to boot. NOT bypassable.
    if ! is_supported_arch; then
        dialog_msgbox "Unsupported architecture" \
"Detected CPU architecture: $(uname -m 2>/dev/null || echo unknown)

This installer supports ONLY amd64 / x86-64.

ARM/aarch64 machines — including the Microsoft Surface Laptop 7 and other
Qualcomm Snapdragon X laptops, ARM laptops and SBCs — are NOT supported:
the PorteuX ISO, squashfs modules and bootloaders are all x86-64.
Proceeding would wipe the disk and then fail to boot.

Installation aborted. No changes were made to any disk."
        return "${TUI_ABORT}"
    fi

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
