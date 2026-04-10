#!/usr/bin/env bash
# config.sh — Save/load configuration using ${VAR@Q} quoting
source "${LIB_DIR}/protection.sh"

# config_save — Serialize all CONFIG_VARS to a sourceable bash file
config_save() {
    local file="${1:-${CONFIG_FILE}}"
    local dir
    dir="$(dirname "${file}")"
    mkdir -p "${dir}"

    # Restrict permissions — file contains password hashes
    (
        umask 077
        {
            echo "#!/usr/bin/env bash"
            echo "# PorteuX TUI Installer configuration"
            echo "# Generated: $(date -Iseconds)"
            echo "# Version: ${INSTALLER_VERSION}"
            echo ""

            local var
            for var in "${CONFIG_VARS[@]}"; do
                if [[ -n "${!var+x}" ]]; then
                    # Use ${VAR@Q} for safe quoting
                    echo "${var}=${!var@Q}"
                fi
            done
        } > "${file}"
    )

    einfo "Configuration saved to ${file}"
}

# config_load — Load configuration from file
config_load() {
    local file="${1:-${CONFIG_FILE}}"

    if [[ ! -f "${file}" ]]; then
        eerror "Configuration file not found: ${file}"
        return 1
    fi

    # Build a filtered file with only known CONFIG_VARS assignments
    local safe_file
    safe_file=$(mktemp "${TMPDIR:-/tmp}/porteux-config-safe.XXXXXX")

    local line_num=0
    while IFS= read -r line; do
        (( line_num++ )) || true
        # Pass through comments and empty lines
        if [[ "${line}" =~ ^[[:space:]]*# ]] || [[ "${line}" =~ ^[[:space:]]*$ ]] || [[ "${line}" =~ ^#! ]]; then
            echo "${line}" >> "${safe_file}"
            continue
        fi

        # Must be a known variable assignment
        local var_name
        var_name="${line%%=*}"
        var_name="${var_name%%[[:space:]]*}"

        local found=0
        local known_var
        for known_var in "${CONFIG_VARS[@]}"; do
            if [[ "${var_name}" == "${known_var}" ]]; then
                found=1
                break
            fi
        done

        if [[ ${found} -eq 0 ]]; then
            ewarn "Unknown variable at line ${line_num}: ${var_name} (skipping)"
            continue
        fi
        echo "${line}" >> "${safe_file}"
    done < "${file}"

    # Source the filtered file (only known variables)
    # shellcheck disable=SC1090
    source "${safe_file}"
    rm -f "${safe_file}"

    einfo "Configuration loaded from ${file}"
}

# config_get — Get a config variable value (for external scripts)
config_get() {
    local var="$1"
    echo "${!var:-}"
}

# config_set — Set a config variable
config_set() {
    local var="$1" value="$2"

    # Validate variable name is in CONFIG_VARS
    local found=0
    local known_var
    for known_var in "${CONFIG_VARS[@]}"; do
        if [[ "${var}" == "${known_var}" ]]; then
            found=1
            break
        fi
    done

    if [[ ${found} -eq 0 ]]; then
        ewarn "Setting unknown config variable: ${var}"
    fi

    printf -v "${var}" '%s' "${value}"
    export "${var}"
}

# config_dump — Print current configuration to stdout
config_dump() {
    local var
    for var in "${CONFIG_VARS[@]}"; do
        if [[ -n "${!var+x}" ]]; then
            echo "${var}=${!var@Q}"
        fi
    done
}

# config_diff — Compare two config files, showing differences
config_diff() {
    local file1="$1" file2="$2"
    diff --unified=0 \
        <(sort "${file1}" | grep -v '^#' | grep -v '^$') \
        <(sort "${file2}" | grep -v '^#' | grep -v '^$') || true
}

# validate_config — Check configuration consistency before installation
# Prints error messages to stdout. Returns 0 if valid, 1 if errors found.
validate_config() {
    local -a errors=()

    # --- Required variables (must be non-empty) ---
    local -a required=(
        TARGET_DISK FILESYSTEM HOSTNAME TIMEZONE LOCALE
        GPU_VENDOR USERNAME ROOT_PASSWORD_HASH USER_PASSWORD_HASH
    )
    local var
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            errors+=("${var} is required but not set")
        fi
    done

    # --- Enum validation (only check if non-empty) ---
    if [[ -n "${PARTITION_SCHEME:-}" ]] && \
       [[ "${PARTITION_SCHEME}" != "auto" && "${PARTITION_SCHEME}" != "dual-boot" && "${PARTITION_SCHEME}" != "manual" ]]; then
        errors+=("PARTITION_SCHEME='${PARTITION_SCHEME}' — must be auto, dual-boot, or manual")
    fi

    if [[ -n "${FILESYSTEM:-}" ]] && \
       [[ "${FILESYSTEM}" != "ext4" && "${FILESYSTEM}" != "btrfs" && "${FILESYSTEM}" != "xfs" && "${FILESYSTEM}" != "fat32" ]]; then
        errors+=("FILESYSTEM='${FILESYSTEM}' — must be ext4, btrfs, xfs, or fat32")
    fi

    if [[ -n "${SWAP_TYPE:-}" ]] && \
       [[ "${SWAP_TYPE}" != "partition" && "${SWAP_TYPE}" != "file" && "${SWAP_TYPE}" != "none" ]]; then
        errors+=("SWAP_TYPE='${SWAP_TYPE}' — must be partition, file, or none")
    fi

    if [[ -n "${DESKTOP_VARIANT:-}" ]]; then
        local valid_desktop=0
        local dv
        for dv in cinnamon cosmic gnome kde lxde lxqt mate xfce; do
            [[ "${DESKTOP_VARIANT}" == "${dv}" ]] && { valid_desktop=1; break; }
        done
        if [[ ${valid_desktop} -eq 0 ]]; then
            errors+=("DESKTOP_VARIANT='${DESKTOP_VARIANT}' — must be one of: cinnamon, cosmic, gnome, kde, lxde, lxqt, mate, xfce")
        fi
    fi

    if [[ -n "${BOOT_MODE:-}" ]] && \
       [[ "${BOOT_MODE}" != "normal" && "${BOOT_MODE}" != "fresh" && "${BOOT_MODE}" != "copy2ram" && "${BOOT_MODE}" != "text" ]]; then
        errors+=("BOOT_MODE='${BOOT_MODE}' — must be normal, fresh, copy2ram, or text")
    fi

    if [[ -n "${PERSISTENCE_MODE:-}" ]] && \
       [[ "${PERSISTENCE_MODE}" != "changes" && "${PERSISTENCE_MODE}" != "none" ]]; then
        errors+=("PERSISTENCE_MODE='${PERSISTENCE_MODE}' — must be changes or none")
    fi

    if [[ -n "${GPU_VENDOR:-}" ]] && \
       [[ "${GPU_VENDOR}" != "nvidia" && "${GPU_VENDOR}" != "amd" && "${GPU_VENDOR}" != "intel" && "${GPU_VENDOR}" != "none" && "${GPU_VENDOR}" != "unknown" ]]; then
        errors+=("GPU_VENDOR='${GPU_VENDOR}' — must be nvidia, amd, intel, none, or unknown")
    fi

    if [[ -n "${NVIDIA_MODULE:-}" ]] && \
       [[ "${NVIDIA_MODULE}" != "yes" && "${NVIDIA_MODULE}" != "no" ]]; then
        errors+=("NVIDIA_MODULE='${NVIDIA_MODULE}' — must be yes or no")
    fi

    # --- Format validation ---
    # Hostname: RFC 1123
    if [[ -n "${HOSTNAME:-}" ]] && \
       [[ ! "${HOSTNAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        errors+=("HOSTNAME='${HOSTNAME}' — invalid (RFC 1123: alphanumeric + hyphens, 1-63 chars)")
    fi

    # Locale: xx_XX.UTF-8
    if [[ -n "${LOCALE:-}" ]] && \
       [[ ! "${LOCALE}" =~ ^[a-z]{2}_[A-Z]{2}\.UTF-8$ ]]; then
        errors+=("LOCALE='${LOCALE}' — must match xx_XX.UTF-8 format")
    fi

    # --- Block device checks (skip in DRY_RUN) ---
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        if [[ -n "${TARGET_DISK:-}" && "${PARTITION_SCHEME:-auto}" != "manual" ]] && \
           [[ ! -b "${TARGET_DISK}" ]]; then
            errors+=("TARGET_DISK='${TARGET_DISK}' — block device does not exist")
        fi

        if [[ "${PARTITION_SCHEME:-}" == "dual-boot" && "${ESP_REUSE:-no}" == "yes" ]] && \
           [[ -n "${ESP_PARTITION:-}" && ! -b "${ESP_PARTITION}" ]]; then
            errors+=("ESP_PARTITION='${ESP_PARTITION}' — block device does not exist")
        fi

        if [[ "${PARTITION_SCHEME:-}" == "dual-boot" ]] && \
           [[ -n "${ROOT_PARTITION:-}" && ! -b "${ROOT_PARTITION}" ]]; then
            errors+=("ROOT_PARTITION='${ROOT_PARTITION}' — block device does not exist")
        fi
    fi

    # --- Cross-field logic ---
    if [[ "${SWAP_TYPE:-}" == "file" ]] && \
       [[ -z "${SWAP_SIZE_MIB:-}" || "${SWAP_SIZE_MIB:-0}" -le 0 ]]; then
        errors+=("SWAP_TYPE=file requires SWAP_SIZE_MIB > 0")
    fi

    if [[ "${PARTITION_SCHEME:-}" == "dual-boot" ]] && \
       [[ -z "${ESP_PARTITION:-}" ]]; then
        errors+=("PARTITION_SCHEME=dual-boot requires ESP_PARTITION to be set")
    fi

    if [[ -n "${SHRINK_PARTITION:-}" ]]; then
        if [[ -n "${SHRINK_PARTITION_FSTYPE:-}" ]] && \
           [[ "${SHRINK_PARTITION_FSTYPE}" != "ntfs" && "${SHRINK_PARTITION_FSTYPE}" != "ext4" && "${SHRINK_PARTITION_FSTYPE}" != "btrfs" ]]; then
            errors+=("SHRINK_PARTITION_FSTYPE='${SHRINK_PARTITION_FSTYPE}' — must be ntfs, ext4, or btrfs")
        fi
        if [[ -z "${SHRINK_NEW_SIZE_MIB:-}" || "${SHRINK_NEW_SIZE_MIB:-0}" -le 0 ]]; then
            errors+=("SHRINK_PARTITION set requires SHRINK_NEW_SIZE_MIB > 0")
        fi
    fi

    # --- Output ---
    if [[ ${#errors[@]} -gt 0 ]]; then
        local err
        for err in "${errors[@]}"; do
            echo "- ${err}"
        done
        return 1
    fi

    return 0
}
