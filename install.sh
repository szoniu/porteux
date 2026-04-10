#!/usr/bin/env bash
# install.sh — Main entry point for the PorteuX TUI Installer
#
# Usage:
#   ./install.sh              — Run full installation (TUI wizard + install)
#   ./install.sh --configure  — Run only the TUI wizard (generate config)
#   ./install.sh --install    — Run only the installation (using existing config)
#   ./install.sh --resume     — Resume interrupted installation
#   ./install.sh --dry-run    — Run wizard + simulate installation
#
set -Eeuo pipefail
shopt -s inherit_errexit

_err_handler() {
    local rc=$1 line=$2 src=$3 func=$4
    # Restore stderr if redirected to log (fd 4 trick from screen_progress)
    if { true >&4; } 2>/dev/null; then exec 2>&4; fi
    echo "[ERR] ${src}:${line} (${func}) exit=${rc}" >&2
    echo "[ERR] ${src}:${line} (${func}) exit=${rc}" >> "${LOG_FILE:-/tmp/porteux-installer.log}"
}
trap '_err_handler $? ${LINENO} "${BASH_SOURCE[0]:-?}" "${FUNCNAME[0]:-main}"' ERR

# Mark as the PorteuX installer (used by protection.sh)
export _PORTEUX_INSTALLER=1

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export LIB_DIR="${SCRIPT_DIR}/lib"
export TUI_DIR="${SCRIPT_DIR}/tui"
export DATA_DIR="${SCRIPT_DIR}/data"

# --- Source library modules ---
source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/disk.sh"
source "${LIB_DIR}/network.sh"
source "${LIB_DIR}/iso.sh"
source "${LIB_DIR}/modules.sh"
source "${LIB_DIR}/bootloader.sh"
source "${LIB_DIR}/persistence.sh"
source "${LIB_DIR}/system.sh"
source "${LIB_DIR}/hooks.sh"
source "${LIB_DIR}/preset.sh"

# --- Source TUI screens ---
source "${TUI_DIR}/welcome.sh"
source "${TUI_DIR}/preset_load.sh"
source "${TUI_DIR}/hw_detect.sh"
source "${TUI_DIR}/disk_select.sh"
source "${TUI_DIR}/filesystem_select.sh"
source "${TUI_DIR}/swap_config.sh"
source "${TUI_DIR}/desktop_select.sh"
source "${TUI_DIR}/gpu_config.sh"
source "${TUI_DIR}/persistence_config.sh"
source "${TUI_DIR}/boot_mode_config.sh"
source "${TUI_DIR}/module_select.sh"
source "${TUI_DIR}/network_config.sh"
source "${TUI_DIR}/locale_config.sh"
source "${TUI_DIR}/user_config.sh"
source "${TUI_DIR}/preset_save.sh"
source "${TUI_DIR}/summary.sh"
source "${TUI_DIR}/progress.sh"

# --- Source data files ---
source "${DATA_DIR}/gpu_database.sh"
source "${DATA_DIR}/mirrors.sh"

# --- Cleanup trap ---
cleanup() {
    local rc=$?

    # Restore terminal echo (gum backend may disable it)
    stty echo </dev/tty 2>/dev/null || true

    # Restore stderr if it was redirected to log file
    if { true >&4; } 2>/dev/null; then
        exec 2>&4
        exec 4>&-
    fi

    # Unmount if still mounted
    if mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        ewarn "Cleaning up mount points..."
        unmount_filesystems 2>/dev/null || true
    fi

    if [[ ${rc} -ne 0 ]]; then
        eerror "Installer exited with code ${rc}"
        eerror "Log file: ${LOG_FILE}"
    fi
    return ${rc}
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT
trap 'trap - EXIT; cleanup; exit 143' TERM

# --- Parse arguments ---
MODE="full"
DRY_RUN=0
FORCE=0
NON_INTERACTIVE=0
export DRY_RUN FORCE NON_INTERACTIVE

usage() {
    cat <<'EOF'
PorteuX TUI Installer

Usage:
  install.sh [OPTIONS] [COMMAND]

Commands:
  (default)       Run full installation (wizard + install)
  --configure     Run only the TUI configuration wizard
  --install       Run only the installation phase (requires config)
  --resume        Resume interrupted installation (scan disks for checkpoints)

Options:
  --config FILE   Use specified config file
  --dry-run       Simulate installation without destructive operations
  --force         Continue past failed prerequisite checks
  --non-interactive  Abort on any error (no recovery menu)
  --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configure)
            MODE="configure"
            shift
            ;;
        --install)
            MODE="install"
            shift
            ;;
        --resume)
            MODE="resume"
            shift
            ;;
        --config)
            if [[ $# -lt 2 ]]; then
                die "--config requires a file argument"
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            eerror "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# --- Main functions ---

# run_configuration_wizard — Launch all TUI screens
run_configuration_wizard() {
    init_dialog

    register_wizard_screens \
        screen_welcome \
        screen_preset_load \
        screen_hw_detect \
        screen_disk_select \
        screen_filesystem_select \
        screen_swap_config \
        screen_desktop_select \
        screen_gpu_config \
        screen_persistence_config \
        screen_boot_mode_config \
        screen_module_select \
        screen_network_config \
        screen_locale_config \
        screen_user_config \
        screen_preset_save \
        screen_summary

    run_wizard

    config_save "${CONFIG_FILE}"
    einfo "Configuration complete. Saved to ${CONFIG_FILE}"
}

# run_post_install — Final steps after installation
run_post_install() {
    einfo "=== Post-installation ==="

    # Unmount everything
    unmount_filesystems

    if dialog_yesno "Reboot" "Would you like to reboot now?"; then
        einfo "Rebooting..."
        if [[ "${DRY_RUN}" != "1" ]]; then
            reboot
        else
            einfo "[DRY-RUN] Would reboot now"
        fi
    else
        einfo "You can reboot manually when ready."
        einfo "Log file: ${LOG_FILE}"
    fi
}

# preflight_checks — Verify system readiness
preflight_checks() {
    einfo "Running preflight checks..."

    if [[ "${DRY_RUN}" != "1" ]]; then
        is_root || die "Must run as root"
        ensure_dns
        has_network || die "Network connectivity required (to download ISO)"
    fi

    # Ensure required tools are available
    if [[ "${DRY_RUN}" != "1" ]]; then
        check_dependencies
    fi

    # Sync clock
    if [[ "${DRY_RUN}" != "1" ]]; then
        if pgrep -x chronyd &>/dev/null || pgrep -x ntpd &>/dev/null; then
            einfo "NTP daemon already running, clock should be synced"
        elif command -v ntpdate &>/dev/null; then
            try "Syncing system clock" ntpdate pool.ntp.org || true
        fi
    fi

    einfo "Preflight checks passed"
}

# --- Entry point ---
main() {
    init_logging

    einfo "========================================="
    einfo "${INSTALLER_NAME} v${INSTALLER_VERSION}"
    einfo "========================================="
    einfo "Mode: ${MODE}"
    [[ "${DRY_RUN}" == "1" ]] && ewarn "DRY-RUN mode enabled"

    case "${MODE}" in
        full)
            run_configuration_wizard
            screen_progress
            run_post_install
            ;;
        configure)
            run_configuration_wizard
            ;;
        install)
            config_load "${CONFIG_FILE}"
            deserialize_detected_oses
            init_dialog
            screen_progress
            run_post_install
            ;;
        resume)
            local resume_rc=0
            try_resume_from_disk || resume_rc=$?

            case ${resume_rc} in
                0)
                    config_load "${CONFIG_FILE}"
                    deserialize_detected_oses
                    init_dialog
                    screen_progress
                    run_post_install
                    ;;
                *)
                    init_dialog
                    dialog_msgbox "Resume: Nothing Found" \
                        "No previous installation data found.\nStarting full installation."
                    run_configuration_wizard
                    screen_progress
                    run_post_install
                    ;;
            esac
            ;;
        *)
            die "Unknown mode: ${MODE}"
            ;;
    esac

    einfo "Done."
}

main "$@"
