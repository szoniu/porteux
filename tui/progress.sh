#!/usr/bin/env bash
# progress.sh — Installation progress and phase execution
source "${LIB_DIR}/protection.sh"

# Installation phases (displayed in progress UI)
readonly -a INSTALL_PHASES=(
    "preflight:Preflight checks"
    "disks:Disk partitioning"
    "iso_download:Downloading PorteuX ISO"
    "iso_verify:Verifying ISO"
    "iso_extract:Extracting ISO"
    "bootloader:Installing bootloader"
    "persistence:Configuring persistence"
    "optional_modules:Downloading optional modules"
    "system_config:System configuration"
    "users:User setup"
    "finalize:Finalization"
)

# screen_progress — Main installation progress screen
screen_progress() {
    einfo "=== Starting installation ==="

    # Save config to target after disk is ready
    _save_config_to_target() {
        if [[ -d "${MOUNTPOINT}" ]] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
            local target_config="${MOUNTPOINT}/${CHECKPOINT_DIR_SUFFIX}/installer.conf"
            mkdir -p "$(dirname "${target_config}")"
            config_save "${target_config}"
            einfo "Config saved to target for resume"
        fi
    }

    # Detect and handle resume
    _detect_and_handle_resume

    local phase_name phase_desc total=${#INSTALL_PHASES[@]}
    local idx=0

    for phase_entry in "${INSTALL_PHASES[@]}"; do
        phase_name="${phase_entry%%:*}"
        phase_desc="${phase_entry#*:}"
        idx=$((idx + 1))

        if checkpoint_reached "${phase_name}"; then
            einfo "[${idx}/${total}] Skipping ${phase_desc} (checkpoint)"
            continue
        fi

        einfo "[${idx}/${total}] ${phase_desc}..."
        _show_phase_status "${idx}" "${total}" "${phase_desc}"

        maybe_exec "before_${phase_name}"
        _execute_phase "${phase_name}"
        maybe_exec "after_${phase_name}"

        checkpoint_set "${phase_name}"

        # Save config after disk phase
        if [[ "${phase_name}" == "disks" ]]; then
            _save_config_to_target
        fi
    done

    einfo "=== Installation complete ==="
    dialog_msgbox "Installation Complete" \
        "PorteuX has been installed successfully!\n\n\
Desktop: ${DESKTOP_VARIANT:-kde}\n\
Persistence: ${PERSISTENCE_MODE:-changes}\n\
Boot mode: ${BOOT_MODE:-normal}\n\n\
You can now reboot into your new system.\n\n\
Default PorteuX credentials (until first boot applies your settings):\n\
  root/toor, guest/guest"
}

# _execute_phase — Execute a single installation phase
_execute_phase() {
    local phase="$1"

    case "${phase}" in
        preflight)
            preflight_checks
            ;;
        disks)
            einfo "Executing disk plan..."
            disk_execute_plan
            mount_filesystems
            ;;
        iso_download)
            iso_download
            ;;
        iso_verify)
            iso_verify
            ;;
        iso_extract)
            iso_extract
            ;;
        bootloader)
            bootloader_install
            ;;
        persistence)
            persistence_setup
            ;;
        optional_modules)
            modules_download_optional
            ;;
        system_config)
            system_configure
            ;;
        users)
            system_create_users
            ;;
        finalize)
            system_finalize
            modules_list_installed
            ;;
        *)
            ewarn "Unknown phase: ${phase}"
            ;;
    esac
}

# _detect_and_handle_resume — Check for existing checkpoints and offer resume
_detect_and_handle_resume() {
    local has_checkpoints=0
    local completed=""
    local cp_name

    for cp_name in "${CHECKPOINTS[@]}"; do
        if checkpoint_reached "${cp_name}"; then
            has_checkpoints=1
            completed+="  - ${cp_name}\n"
        fi
    done

    if [[ ${has_checkpoints} -eq 1 ]]; then
        if dialog_yesno "Resume Detected" \
            "Found previous installation progress:\n\n${completed}\nResume from last checkpoint?"; then
            einfo "Resuming installation..."
        else
            einfo "Clearing checkpoints and starting fresh..."
            checkpoint_clear
        fi
    fi
}

# _show_phase_status — Show progress bar/info
_show_phase_status() {
    local current="$1" total="$2" desc="$3"
    local percent=$(( (current - 1) * 100 / total ))

    dialog_infobox "Installing" \
        "[${current}/${total}] ${desc}... (${percent}%)"
}
