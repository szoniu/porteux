#!/usr/bin/env bash
# filesystem_select.sh — Root filesystem selection
source "${LIB_DIR}/protection.sh"

screen_filesystem_select() {
    # Manual partitioning: auto-detect filesystem
    if [[ "${PARTITION_SCHEME:-auto}" == "manual" ]]; then
        local detected_fs
        detected_fs=$(lsblk -no FSTYPE "${ROOT_PARTITION}" 2>/dev/null | head -1)
        if [[ -n "${detected_fs}" ]]; then
            export FILESYSTEM="${detected_fs}"
            einfo "Auto-detected filesystem: ${FILESYSTEM}"
            return ${TUI_NEXT}
        fi
    fi

    local choice
    choice=$(dialog_radiolist "Filesystem" "Select root filesystem:" \
        "ext4"  "ext4 — stable, widely supported (recommended)"  "on" \
        "fat32" "FAT32 — maximum portability (USB drives)"       "off" \
        "btrfs" "btrfs — snapshots, compression"                 "off" \
        "xfs"   "XFS — high performance, large files"            "off") || return ${TUI_BACK}

    export FILESYSTEM="${choice}"
    einfo "Filesystem: ${FILESYSTEM}"

    return ${TUI_NEXT}
}
