#!/usr/bin/env bash
# bootloader.sh — Bootloader installation for PorteuX (syslinux/GRUB)
source "${LIB_DIR}/protection.sh"

# _umpc_kernel_cmdline — Echo the UMPC panel-rotation kernel parameters when a
# UMPC with a rotated portrait panel was detected, otherwise echo nothing.
# Shared by both bootloader paths (syslinux APPEND for BIOS, GRUB linux line
# for EFI) so first boot — GRUB menu, fbcon console, SDDM/Plasma/GNOME —
# displays the right way up. fbcon=rotate handles the early console; the
# video=...:panel_orientation override is consumed by KMS-aware compositors.
_umpc_kernel_cmdline() {
    if [[ "${UMPC_DETECTED:-0}" == "1" ]] && [[ -n "${UMPC_PANEL_ORIENTATION:-}" ]]; then
        printf 'fbcon=rotate:%s video=%s:panel_orientation=%s' \
            "${UMPC_FBCON_ROTATE}" "${UMPC_VIDEO_CONNECTOR}" "${UMPC_PANEL_ORIENTATION}"
    fi
}

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

# _bootloader_install_efi — Configure EFI boot using the ISO's bundled EFI
# syslinux. PorteuX ships NO GRUB: iso/EFI/BOOT/ contains bootx64.efi + *.c32 +
# ldlinux.e64 + syslinux.cfg, and that syslinux.cfg does
# `INCLUDE ../../boot/syslinux/porteux.cfg`. The INCLUDE path is relative to the
# loader, so the ESP must hold BOTH /EFI/BOOT and /boot/syslinux. All boot config
# lives in porteux.cfg — the single source of truth shared with the BIOS path.
_bootloader_install_efi() {
    local target="${MOUNTPOINT}"
    local esp="${target}/boot/efi"

    einfo "Configuring EFI boot (syslinux)..."

    if [[ ! -d "${target}/EFI/BOOT" ]]; then
        ewarn "No /EFI/BOOT in extracted ISO — EFI boot may need manual setup"
        return 0
    fi

    mkdir -p "${esp}"

    # Loader + its INCLUDE target must both sit on the ESP.
    try "Copying EFI boot files" cp -a "${target}/EFI" "${esp}/"
    if [[ -d "${target}/boot" ]]; then
        mkdir -p "${esp}/boot"
        try "Copying boot files to ESP" cp -a "${target}/boot/." "${esp}/boot/"
    fi

    # Apply persistence + default boot mode + UMPC quirks to the cfg the firmware
    # actually reads (the one on the ESP).
    if [[ -d "${esp}/boot/syslinux" ]]; then
        _update_syslinux_config "${esp}/boot/syslinux"
    else
        ewarn "No boot/syslinux on ESP — boot config not applied"
    fi

    # Register a firmware boot entry (best-effort; the removable-media fallback
    # path /EFI/BOOT/bootx64.efi boots even without it).
    _configure_efi_boot_entry
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
        --loader "\\EFI\\BOOT\\bootx64.efi" \
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

# _update_syslinux_config — Apply persistence, default boot mode, and UMPC panel
# rotation to PorteuX's syslinux config (porteux.cfg) in one awk pass.
#
# Grounded in the real upstream porteux.cfg, which:
#   - ships NO `DEFAULT` directive (it relies on first-label autoboot), and the
#     labels are: graphical / fresh / copy2ram / text / text-fresh (no "normal");
#   - puts `changes=EXIT:/porteux` only on the `graphical` (and copy2ram) labels.
# So we: emit a real `DEFAULT <label>` for the chosen BOOT_MODE; for persistence
# `changes` ensure the chosen default label carries changes=EXIT:/<base>; for
# `none` strip changes= from every label (truly immutable); and prepend the UMPC
# rotation cmdline to every APPEND. The pass is idempotent (safe on resume).
_update_syslinux_config() {
    local syslinux_dir="$1"

    local cfg=""
    if [[ -f "${syslinux_dir}/porteux.cfg" ]]; then
        cfg="${syslinux_dir}/porteux.cfg"
    elif [[ -f "${syslinux_dir}/syslinux.cfg" ]]; then
        cfg="${syslinux_dir}/syslinux.cfg"
    else
        ewarn "No syslinux config file found in ${syslinux_dir}"
        return 0
    fi

    einfo "Updating syslinux configuration: $(basename "${cfg}")"

    # Map BOOT_MODE to a label that actually exists in porteux.cfg.
    local deflabel
    case "${BOOT_MODE:-normal}" in
        text)     deflabel="text" ;;
        copy2ram) deflabel="copy2ram" ;;
        fresh)    deflabel="fresh" ;;
        *)        deflabel="graphical" ;;
    esac

    local persist="${PERSISTENCE_MODE:-changes}"
    local changes_param="changes=EXIT:/${PORTEUX_PERSISTENCE_DIR}"
    local umpc_cmdline
    umpc_cmdline="$(_umpc_kernel_cmdline)"

    local tmp
    tmp="$(mktemp "${cfg}.XXXXXX")"
    awk -v deflabel="${deflabel}" -v persist="${persist}" \
        -v changes_param="${changes_param}" -v umpc="${umpc_cmdline}" '
    BEGIN { curlabel=""; default_done=0 }
    # Drop any pre-existing DEFAULT directive; we re-emit our own (idempotent).
    toupper($1)=="DEFAULT" { next }
    {
        line=$0
        if (toupper($1)=="LABEL") { curlabel=$2 }
        if (toupper($1)=="APPEND") {
            rest=substr(line, index(line,$1)+length($1))   # text after "APPEND"
            # UMPC rotation first: prepend to every APPEND unless already present.
            if (umpc != "" && rest !~ /panel_orientation=/) {
                rest=" " umpc rest
            }
            # Persistence reconciled only on the chosen default label (other labels
            # keep upstream behavior). Done last so changes= lands at the front in a
            # stable position — making the whole rewrite idempotent on re-run/resume.
            if (curlabel==deflabel) {
                gsub(/[[:space:]]+changes=[^[:space:]]+/, "", rest)
                sub(/^changes=[^[:space:]]+[[:space:]]*/, "", rest)
                if (persist=="changes") { rest=" " changes_param rest }
            }
            line="APPEND" rest
        }
        print line
        # Emit DEFAULT right after the first line so it sits near the top.
        if (NR==1 && !default_done) { print "DEFAULT " deflabel; default_done=1 }
    }
    ' "${cfg}" > "${tmp}"

    if [[ -s "${tmp}" ]]; then
        cat "${tmp}" > "${cfg}"
        rm -f "${tmp}"
        einfo "syslinux config updated (default=${deflabel}, persistence=${persist})"
    else
        rm -f "${tmp}"
        ewarn "Config rewrite produced empty output — leaving ${cfg} unchanged"
    fi
}

# _partition_to_disk — defined in lib/utils.sh
