#!/usr/bin/env bash
# bootloader.sh — Bootloader installation for PorteuX (syslinux/GRUB)
source "${LIB_DIR}/protection.sh"

# bootloader_install — Install and configure the bootloader
bootloader_install() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    einfo "Installing bootloader..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would install bootloader"
        return 0
    fi

    if is_efi; then
        _bootloader_install_efi
    else
        _bootloader_install_bios
    fi

    einfo "Bootloader installation complete"
}

# _bootloader_install_efi — Install GRUB for EFI systems
_bootloader_install_efi() {
    local target="${MOUNTPOINT}"
    local esp="${target}/boot/efi"

    einfo "Installing GRUB for EFI..."

    # PorteuX ISO may include EFI boot files already
    if [[ -d "${target}/EFI/BOOT" ]]; then
        einfo "EFI boot files found in ISO, copying to ESP..."

        # Ensure ESP mount point exists
        mkdir -p "${esp}"

        # Copy EFI directory to ESP
        try "Copying EFI boot files" cp -a "${target}/EFI" "${esp}/"

        # Copy boot directory contents (vmlinuz, initrd, syslinux configs)
        if [[ -d "${target}/boot" ]]; then
            try "Copying boot files" cp -a "${target}/boot/." "${esp}/boot/" 2>/dev/null || true
        fi
    fi

    # Configure GRUB if available, otherwise rely on ISO's EFI setup
    if command -v grub-install &>/dev/null; then
        _install_grub_efi "${target}" "${esp}"
    elif [[ -f "${esp}/EFI/BOOT/BOOTX64.EFI" ]]; then
        einfo "Using ISO's built-in EFI bootloader"
        _configure_efi_boot_entry
    else
        ewarn "No EFI bootloader found — manual configuration may be required"
    fi
}

# _install_grub_efi — Install GRUB for EFI from system packages
_install_grub_efi() {
    local target="$1"
    local esp="$2"

    # Create GRUB configuration for PorteuX
    local grub_cfg="${esp}/boot/grub/grub.cfg"
    mkdir -p "$(dirname "${grub_cfg}")"

    local root_uuid
    root_uuid=$(get_uuid "${ROOT_PARTITION}")

    local boot_params="kvm.enable_virt_at_load=0"
    case "${BOOT_MODE:-normal}" in
        fresh)   boot_params+=" baseonly norootcopy" ;;
        copy2ram) boot_params+=" copy2ram" ;;
        text)    boot_params+=" 3" ;;
    esac

    if [[ "${PERSISTENCE_MODE:-changes}" == "changes" ]]; then
        boot_params+=" changes=EXIT:/${PORTEUX_CHANGES_DIR}"
    fi

    cat > "${grub_cfg}" <<GRUBEOF
set timeout=5
set default=0

menuentry "PorteuX" {
    linux /boot/syslinux/vmlinuz ${boot_params}
    initrd /boot/syslinux/initrd.zst
}

menuentry "PorteuX (Copy to RAM)" {
    linux /boot/syslinux/vmlinuz copy2ram kvm.enable_virt_at_load=0
    initrd /boot/syslinux/initrd.zst
}

menuentry "PorteuX (Text Mode)" {
    linux /boot/syslinux/vmlinuz 3 kvm.enable_virt_at_load=0
    initrd /boot/syslinux/initrd.zst
}

menuentry "PorteuX (Always Fresh)" {
    linux /boot/syslinux/vmlinuz baseonly norootcopy kvm.enable_virt_at_load=0
    initrd /boot/syslinux/initrd.zst
}
GRUBEOF

    einfo "GRUB configuration written to ${grub_cfg}"

    # Install GRUB to ESP
    try "Installing GRUB EFI" grub-install \
        --target=x86_64-efi \
        --efi-directory="${esp}" \
        --boot-directory="${esp}/boot" \
        --bootloader-id=PorteuX \
        --removable \
        --no-nvram 2>/dev/null || true

    einfo "GRUB EFI installed"
}

# _configure_efi_boot_entry — Create EFI boot entry using efibootmgr
_configure_efi_boot_entry() {
    if ! command -v efibootmgr &>/dev/null; then
        ewarn "efibootmgr not available, skipping EFI boot entry creation"
        return 0
    fi

    local esp_part="${ESP_PARTITION:?ESP_PARTITION not set}"
    local part_num
    part_num=$(echo "${esp_part}" | sed 's/.*[^0-9]\([0-9]*\)$/\1/')
    local disk
    disk=$(_partition_to_disk "${esp_part}")

    try "Creating EFI boot entry" efibootmgr \
        --create \
        --disk "${disk}" \
        --part "${part_num}" \
        --loader "\\EFI\\BOOT\\BOOTX64.EFI" \
        --label "PorteuX" \
        --quiet 2>/dev/null || true

    einfo "EFI boot entry created"
}

# _bootloader_install_bios — Install syslinux for BIOS systems
_bootloader_install_bios() {
    local target="${MOUNTPOINT}"
    local disk="${TARGET_DISK:?TARGET_DISK not set}"

    einfo "Configuring syslinux for BIOS boot..."

    # PorteuX ISO includes syslinux configuration
    if [[ -d "${target}/boot/syslinux" ]]; then
        einfo "Syslinux configuration found in ISO"

        # Install syslinux MBR (if available)
        if command -v syslinux &>/dev/null; then
            # Install syslinux to the partition
            try "Installing syslinux" syslinux --install "${ROOT_PARTITION}"

            # Install MBR
            local mbr_bin=""
            local mbr_search=(
                "/usr/lib/syslinux/bios/mbr.bin"
                "/usr/share/syslinux/mbr.bin"
                "/usr/lib/syslinux/mbr/mbr.bin"
            )
            local p
            for p in "${mbr_search[@]}"; do
                if [[ -f "${p}" ]]; then
                    mbr_bin="${p}"
                    break
                fi
            done

            if [[ -n "${mbr_bin}" ]]; then
                try "Installing syslinux MBR" dd bs=440 count=1 conv=notrunc if="${mbr_bin}" of="${disk}"
                einfo "Syslinux MBR installed from ${mbr_bin}"
            else
                ewarn "syslinux MBR binary not found — MBR may need manual installation"
            fi
        elif command -v extlinux &>/dev/null; then
            # extlinux as fallback
            try "Installing extlinux" extlinux --install "${target}/boot/syslinux"
            einfo "extlinux installed"
        else
            ewarn "Neither syslinux nor extlinux found"
            ewarn "You may need to install syslinux manually"
        fi

        # Update syslinux config for persistence
        _update_syslinux_config "${target}/boot/syslinux"
    else
        ewarn "No syslinux directory found in ISO — bootloader may need manual setup"
    fi
}

# _update_syslinux_config — Update syslinux configuration with persistence settings
_update_syslinux_config() {
    local syslinux_dir="$1"

    # Look for porteux.cfg or syslinux.cfg
    local cfg=""
    if [[ -f "${syslinux_dir}/porteux.cfg" ]]; then
        cfg="${syslinux_dir}/porteux.cfg"
    elif [[ -f "${syslinux_dir}/syslinux.cfg" ]]; then
        cfg="${syslinux_dir}/syslinux.cfg"
    else
        ewarn "No syslinux config file found"
        return 0
    fi

    einfo "Updating syslinux configuration: $(basename "${cfg}")"

    # Update persistence parameter
    if [[ "${PERSISTENCE_MODE:-changes}" == "changes" ]]; then
        # Ensure changes= parameter is set in the default boot entry
        if grep -q "changes=" "${cfg}"; then
            einfo "Persistence already configured in syslinux config"
        else
            # Add changes= to the default APPEND line
            sed -i "s|APPEND |APPEND changes=EXIT:/${PORTEUX_CHANGES_DIR} |" "${cfg}" 2>/dev/null || true
            einfo "Added persistence parameter to syslinux config"
        fi
    fi

    # Update boot mode
    case "${BOOT_MODE:-normal}" in
        text)
            # Set default to text mode entry
            sed -i 's/^DEFAULT .*/DEFAULT text/' "${cfg}" 2>/dev/null || true
            ;;
        copy2ram)
            sed -i 's/^DEFAULT .*/DEFAULT copy2ram/' "${cfg}" 2>/dev/null || true
            ;;
        fresh)
            sed -i 's/^DEFAULT .*/DEFAULT fresh/' "${cfg}" 2>/dev/null || true
            ;;
    esac
}

# _partition_to_disk — Extract disk device from partition path
# /dev/sda1 → /dev/sda, /dev/nvme0n1p1 → /dev/nvme0n1
_partition_to_disk() {
    local part="$1"
    if [[ "${part}" =~ (nvme|mmcblk|loop) ]]; then
        echo "${part}" | sed 's/p[0-9]*$//'
    else
        echo "${part}" | sed 's/[0-9]*$//'
    fi
}
