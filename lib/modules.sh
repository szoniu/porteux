#!/usr/bin/env bash
# modules.sh — PorteuX XZM module management
source "${LIB_DIR}/protection.sh"

# modules_list_installed — List XZM modules on the target
modules_list_installed() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"
    local modules_dir="${target}/${PORTEUX_MODULES_DIR}"

    if [[ ! -d "${modules_dir}" ]]; then
        ewarn "Modules directory not found: ${modules_dir}"
        return 1
    fi

    einfo "Installed base modules:"
    local f
    for f in "${modules_dir}"/*.xzm; do
        [[ -f "${f}" ]] || continue
        local size
        size=$(du -h "${f}" | awk '{print $1}')
        einfo "  $(basename "${f}") (${size})"
    done

    local optional_dir="${target}/${PORTEUX_OPTIONAL_DIR}"
    if [[ -d "${optional_dir}" ]]; then
        local has_optional=0
        for f in "${optional_dir}"/*.xzm; do
            [[ -f "${f}" ]] || continue
            if [[ ${has_optional} -eq 0 ]]; then
                einfo "Optional modules:"
                has_optional=1
            fi
            local size
            size=$(du -h "${f}" | awk '{print $1}')
            einfo "  $(basename "${f}") (${size})"
        done
    fi
}

# modules_download_optional — Download optional modules
# Expects: ENABLE_DEVEL_MODULE, ENABLE_MULTILANG_MODULE, ENABLE_MULTILIB_MODULE
modules_download_optional() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"
    local optional_dir="${target}/${PORTEUX_OPTIONAL_DIR}"
    mkdir -p "${optional_dir}"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would download optional modules"
        return 0
    fi

    local any_downloaded=0

    if [[ "${ENABLE_DEVEL_MODULE:-no}" == "yes" ]]; then
        _download_optional_module "05-devel" "${optional_dir}" && any_downloaded=1
    fi

    if [[ "${ENABLE_MULTILANG_MODULE:-no}" == "yes" ]]; then
        _download_optional_module "08-multilanguage" "${optional_dir}" && any_downloaded=1
    fi

    if [[ "${ENABLE_MULTILIB_MODULE:-no}" == "yes" ]]; then
        _download_optional_module "0050-multilib-lite" "${optional_dir}" && any_downloaded=1
    fi

    if [[ "${NVIDIA_MODULE:-no}" == "yes" ]]; then
        _download_nvidia_module "${optional_dir}" && any_downloaded=1
    fi

    if [[ ${any_downloaded} -eq 0 ]]; then
        einfo "No optional modules selected"
    fi
}

# _download_optional_module — Download a single optional module
_download_optional_module() {
    local module_name="$1"
    local target_dir="$2"

    einfo "Downloading optional module: ${module_name}"

    # Check if already present (may have been included in ISO)
    local existing
    for existing in "${target_dir}"/${module_name}*.xzm; do
        if [[ -f "${existing}" ]]; then
            einfo "  Module already present: $(basename "${existing}")"
            return 0
        fi
    done

    # Try to download from PorteuX SourceForge
    local module_url="${PORTEUX_DOWNLOAD_BASE}/modules/${module_name}.xzm/download"

    if curl -fsSL --max-time 60 -o "${target_dir}/${module_name}.xzm" "${module_url}" 2>/dev/null; then
        einfo "  Downloaded: ${module_name}.xzm"
        return 0
    else
        ewarn "  Could not download ${module_name} module (may need manual download)"
        return 1
    fi
}

# _download_nvidia_module — Download NVIDIA driver module
_download_nvidia_module() {
    local target_dir="$1"

    einfo "Downloading NVIDIA driver module..."

    # Check if already present
    local existing
    for existing in "${target_dir}"/nvidia*.xzm "${MOUNTPOINT}/${PORTEUX_MODULES_DIR}"/nvidia*.xzm; do
        if [[ -f "${existing}" ]]; then
            einfo "  NVIDIA module already present: $(basename "${existing}")"
            return 0
        fi
    done

    local nvidia_url="${PORTEUX_DOWNLOAD_BASE}/modules/nvidia-driver.xzm/download"

    if curl -fsSL --max-time 120 -o "${target_dir}/nvidia-driver.xzm" "${nvidia_url}" 2>/dev/null; then
        einfo "  Downloaded: nvidia-driver.xzm"
        return 0
    else
        ewarn "  Could not download NVIDIA module (may need manual download)"
        return 1
    fi
}

# modules_verify — Verify XZM modules are valid squashfs images
modules_verify() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    einfo "Verifying installed modules..."

    local dir
    for dir in "${target}/${PORTEUX_MODULES_DIR}" "${target}/${PORTEUX_OPTIONAL_DIR}"; do
        [[ -d "${dir}" ]] || continue
        local f
        for f in "${dir}"/*.xzm; do
            [[ -f "${f}" ]] || continue
            local basename
            basename="$(basename "${f}")"
            if file "${f}" | grep -q "Squashfs\|squashfs"; then
                elog "  OK: ${basename}"
            else
                ewarn "  WARN: ${basename} — may not be a valid squashfs module"
            fi
        done
    done
}
