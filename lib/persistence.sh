#!/usr/bin/env bash
# persistence.sh — PorteuX persistence configuration (changes= parameter)
source "${LIB_DIR}/protection.sh"

# persistence_setup — Configure persistence on the target
# PorteuX uses AUFS overlays with the changes= boot parameter:
#   changes=EXIT:/porteux  — persist changes; PorteuX creates a "changes" subdir
#                            inside /porteux and stores the overlay there
#   (no changes= parameter) — immutable mode (changes lost on reboot)
persistence_setup() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    einfo "Configuring persistence..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would configure persistence: ${PERSISTENCE_MODE:-changes}"
        return 0
    fi

    case "${PERSISTENCE_MODE:-changes}" in
        changes)
            _setup_persistent_changes "${target}"
            ;;
        none)
            einfo "Immutable mode — no persistence configured"
            einfo "Changes will be lost on reboot"
            ;;
        *)
            ewarn "Unknown persistence mode: ${PERSISTENCE_MODE}"
            ewarn "Defaulting to changes (persistent)"
            _setup_persistent_changes "${target}"
            ;;
    esac

    einfo "Persistence configuration complete"
}

# _setup_persistent_changes — Create changes directory for AUFS persistence
_setup_persistent_changes() {
    local target="$1"
    local changes_dir="${target}/${PORTEUX_CHANGES_DIR}"

    # Pre-create the overlay subdir PorteuX uses (/porteux/changes). The installer
    # seeds system/user config here; at boot PorteuX overlays this exact directory
    # because the boot parameter points at the base dir /porteux.
    mkdir -p "${changes_dir}"

    einfo "Persistence directory created: /${PORTEUX_CHANGES_DIR}"
    einfo "Boot parameter: changes=EXIT:/${PORTEUX_PERSISTENCE_DIR}"

    # Create a marker file to indicate persistence is configured
    echo "# PorteuX persistence configuration" > "${changes_dir}/.persistence"
    echo "# Created: $(date -Iseconds)" >> "${changes_dir}/.persistence"
    echo "# Mode: changes" >> "${changes_dir}/.persistence"
}

# persistence_get_boot_param — Return the boot parameter for the current persistence mode
persistence_get_boot_param() {
    case "${PERSISTENCE_MODE:-changes}" in
        changes)
            echo "changes=EXIT:/${PORTEUX_PERSISTENCE_DIR}"
            ;;
        none)
            echo ""
            ;;
    esac
}

# persistence_clean — Clean persistence data (factory reset)
persistence_clean() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"
    local changes_dir="${target}/${PORTEUX_CHANGES_DIR}"

    if [[ -d "${changes_dir}" ]]; then
        ewarn "Cleaning persistence data: ${changes_dir}"
        rm -rf "${changes_dir:?}"/*
        einfo "Persistence data cleaned"
    else
        einfo "No persistence data to clean"
    fi
}
