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
    "umpc_quirks:Applying UMPC quirks"
    "finalize:Finalization"
)

# screen_progress — Main installation progress screen
screen_progress() {
    einfo "=== Starting installation ==="

    # Save config to target after disk is ready
    _save_config_to_target() {
        if [[ -d "${MOUNTPOINT}" ]] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
            local target_config="${MOUNTPOINT}/tmp/porteux-installer.conf"
            mkdir -p "$(dirname "${target_config}")"
            config_save "${target_config}"
            einfo "Config saved to target for resume"
        fi
    }

    # Detect and handle resume
    _detect_and_handle_resume

    # On resume the target is unmounted, but its phases (disks, iso_*) are skipped
    # via their checkpoints — so re-mount the existing partitions here, or the
    # remaining phases (bootloader, system_config, users) would write to the live
    # filesystem instead of the disk. mount_filesystems only mounts; no format.
    _resume_derive_partitions
    if checkpoint_reached "disks" && [[ -b "${ROOT_PARTITION:-}" ]] \
       && ! mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        einfo "Resume: remounting target (${ROOT_PARTITION}) at ${MOUNTPOINT}..."
        mount_filesystems
        checkpoint_migrate_to_target
    fi

    # Safety guard: if the ISO was already extracted but the target isn't mounted
    # (e.g. resume couldn't recover ROOT_PARTITION), the remaining phases would
    # silently write to the LIVE filesystem and produce an unbootable system.
    # Fail loudly instead of pretending to succeed.
    if checkpoint_reached "iso_extract" && ! mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        die "Target ${MOUNTPOINT} is not mounted (could not recover ROOT_PARTITION on resume).
Refusing to install to the live filesystem. Run a fresh install instead:
  ./install.sh --install --config ${CONFIG_FILE}"
    fi

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

    local complete_msg="PorteuX has been installed successfully!\n\n\
Desktop: ${DESKTOP_VARIANT:-kde}\n\
Persistence: ${PERSISTENCE_MODE:-changes}\n\
Boot mode: ${BOOT_MODE:-normal}\n\n\
Default credentials until first boot applies your settings:\n\
  root/toor, guest/guest\n\n\
After reboot:\n\
  - Install more software via the PorteuX App Store (porteux-app-store,\n\
    in the desktop menu) or with .xzm modules.\n\
  - Activate optional modules you downloaded:\n\
    activate /porteux/optional/<module>.xzm\n\
    (or move them to /porteux/modules/ to auto-load at boot)."

    if [[ "${ENABLE_DEVEL_MODULE:-no}" == "yes" || "${ENABLE_MULTILANG_MODULE:-no}" == "yes" \
        || "${ENABLE_MULTILIB_MODULE:-no}" == "yes" ]]; then
        complete_msg+="\n  - Your selected optional modules are in /porteux/optional/\n\
    and need 'activate' before use."
    fi

    dialog_msgbox "Installation Complete" "${complete_msg}"
}

# _execute_phase — Execute a single installation phase
_execute_phase() {
    local phase="$1"

    case "${phase}" in
        preflight)
            preflight_checks
            ;;
        disks)
            # Resume onto a disk that already holds a PorteuX install but lost
            # its 'disks' checkpoint: repartitioning here would wipe it.
            # Refuse the destructive plan, mount what is there, carry on.
            if [[ "${MODE:-}" == "resume" ]] && _resume_target_has_system; then
                ewarn "Resume: ${ROOT_PARTITION:-${RESUME_FOUND_PARTITION:-?}} already holds an"
                ewarn "installed PorteuX system but the 'disks' checkpoint is missing."
                ewarn "Refusing to reformat — mounting the existing system instead."
            else
                einfo "Executing disk plan..."
                disk_execute_plan
            fi
            mount_filesystems
            # Target jest zamontowany — od teraz log leży na dysku, nie na
            # tmpfs live ISO, więc przetrwa reboot i resume.
            log_relocate_to_target
            # Move checkpoints onto the mounted target so resume survives a crash
            # or reboot (reassigns CHECKPOINT_DIR to the disk).
            checkpoint_migrate_to_target
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
        umpc_quirks)
            umpc_apply_quirks
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

# _resume_derive_partitions — Recover ESP_PARTITION/ROOT_PARTITION on resume.
# They're set during the disks phase, so a config saved at the end of the wizard
# won't have them. Derive them from TARGET_DISK (which IS in the config) by
# inspecting the existing partitions, so the target can be re-mounted.
_resume_derive_partitions() {
    [[ -n "${TARGET_DISK:-}" ]] || return 0
    [[ -n "${ROOT_PARTITION:-}" && -n "${ESP_PARTITION:-}" ]] && return 0
    command -v lsblk &>/dev/null || return 0

    local fs="${FILESYSTEM:-ext4}" path fstype parttype

    # ESP: prefer the EFI System partition type GUID, else first vfat partition.
    if [[ -z "${ESP_PARTITION:-}" ]]; then
        while read -r path fstype parttype; do
            [[ -n "${path}" && "${parttype,,}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || continue
            ESP_PARTITION="${path}"; break
        done < <(lsblk -lno PATH,FSTYPE,PARTTYPE "${TARGET_DISK}" 2>/dev/null)
        if [[ -z "${ESP_PARTITION:-}" ]]; then
            ESP_PARTITION=$(lsblk -lno PATH,FSTYPE "${TARGET_DISK}" 2>/dev/null | awk '$2=="vfat"{print $1; exit}')
        fi
        [[ -n "${ESP_PARTITION:-}" ]] && export ESP_PARTITION && einfo "Resume: derived ESP_PARTITION=${ESP_PARTITION}"
    fi

    # Root: first partition matching the chosen filesystem, excluding the ESP.
    if [[ -z "${ROOT_PARTITION:-}" ]]; then
        while read -r path fstype; do
            [[ -n "${path}" && "${path}" != "${ESP_PARTITION:-}" && "${fstype}" == "${fs}" ]] || continue
            ROOT_PARTITION="${path}"; break
        done < <(lsblk -lno PATH,FSTYPE "${TARGET_DISK}" 2>/dev/null)
        [[ -n "${ROOT_PARTITION:-}" ]] && export ROOT_PARTITION && einfo "Resume: derived ROOT_PARTITION=${ROOT_PARTITION}"
    fi
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
