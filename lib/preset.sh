#!/usr/bin/env bash
# preset.sh — Export/import presets with hardware overlay
source "${LIB_DIR}/protection.sh"

# Hardware-specific variables that should be re-detected, not imported
readonly -a PRESET_HW_VARS=(
    GPU_VENDOR
    GPU_DEVICE_ID
    GPU_DEVICE_NAME
    GPU_DRIVER
    TARGET_DISK
    ESP_PARTITION
    ROOT_PARTITION
    SWAP_PARTITION
    ESP_REUSE
)

# preset_export — Save configuration as a portable preset
preset_export() {
    local file="$1"
    local dir
    dir="$(dirname "${file}")"
    mkdir -p "${dir}"

    {
        echo "#!/usr/bin/env bash"
        echo "# PorteuX TUI Installer Preset"
        echo "# Exported: $(date -Iseconds)"
        echo "# Version: ${INSTALLER_VERSION}"
        echo "# Host: $(hostname 2>/dev/null || echo unknown)"
        echo "#"
        echo "# Hardware-specific values (will be re-detected on import):"
        local hw_var
        for hw_var in "${PRESET_HW_VARS[@]}"; do
            if [[ -n "${!hw_var+x}" ]]; then
                echo "# ${hw_var}=${!hw_var@Q}"
            fi
        done
        echo ""
        echo "# --- Portable configuration ---"

        local var
        for var in "${CONFIG_VARS[@]}"; do
            # Skip hardware-specific vars
            local is_hw=0
            for hw_var in "${PRESET_HW_VARS[@]}"; do
                if [[ "${var}" == "${hw_var}" ]]; then
                    is_hw=1
                    break
                fi
            done
            [[ ${is_hw} -eq 1 ]] && continue

            if [[ -n "${!var+x}" ]]; then
                echo "${var}=${!var@Q}"
            fi
        done
    } > "${file}"

    einfo "Preset exported to ${file}"
}

# preset_import — Load a preset and re-detect hardware
preset_import() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        eerror "Preset file not found: ${file}"
        return 1
    fi

    # Save current hardware values
    local -A saved_hw=()
    local hw_var
    for hw_var in "${PRESET_HW_VARS[@]}"; do
        if [[ -n "${!hw_var+x}" ]]; then
            saved_hw["${hw_var}"]="${!hw_var}"
        fi
    done

    # Load preset (only non-hardware values)
    config_load "${file}"

    # Restore hardware values (re-detected values take priority)
    for hw_var in "${PRESET_HW_VARS[@]}"; do
        if [[ -n "${saved_hw[${hw_var}]+x}" ]]; then
            printf -v "${hw_var}" '%s' "${saved_hw[${hw_var}]}"
            export "${hw_var}"
        fi
    done

    einfo "Preset imported from ${file}"
    einfo "Hardware-specific values preserved from current detection"
}
