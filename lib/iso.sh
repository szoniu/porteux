#!/usr/bin/env bash
# iso.sh — PorteuX ISO download, verification, and extraction
source "${LIB_DIR}/protection.sh"

# iso_get_url — Determine the ISO download URL for the selected desktop variant
# Sets: ISO_URL, ISO_FILENAME
iso_get_url() {
    local variant="${DESKTOP_VARIANT:?DESKTOP_VARIANT not set}"

    einfo "Resolving ISO URL for variant: ${variant}"

    # If user provided a custom URL, use it
    if [[ -n "${ISO_URL:-}" ]]; then
        ISO_FILENAME="$(basename "${ISO_URL}")"
        einfo "Using custom ISO URL: ${ISO_URL}"
        return 0
    fi

    # PorteuX ISOs are hosted on SourceForge
    # Pattern: PorteuX-<variant>-v<version>-x86_64.iso
    # We try to detect the latest version from GitHub releases
    local latest_tag=""
    if command -v curl &>/dev/null; then
        latest_tag=$(curl -fsSL --max-time 10 \
            "https://api.github.com/repos/porteux/porteux/releases/latest" 2>/dev/null \
            | grep -oP '"tag_name":\s*"\K[^"]+' || true)
    fi

    if [[ -z "${latest_tag}" ]]; then
        latest_tag="v3.0"
        ewarn "Could not detect latest version, using default: ${latest_tag}"
    fi

    ISO_FILENAME="PorteuX-${variant}-${latest_tag}-x86_64.iso"
    ISO_URL="${PORTEUX_DOWNLOAD_BASE}/${latest_tag}/${ISO_FILENAME}/download"
    export ISO_URL ISO_FILENAME

    einfo "ISO URL: ${ISO_URL}"
    einfo "ISO filename: ${ISO_FILENAME}"
}

# iso_download — Download the PorteuX ISO
# Expects: ISO_URL, ISO_FILENAME, MOUNTPOINT
iso_download() {
    local download_dir="${MOUNTPOINT}/tmp"
    mkdir -p "${download_dir}"

    local iso_path="${download_dir}/${ISO_FILENAME}"

    # Check for existing download (resume support)
    if [[ -f "${iso_path}" ]]; then
        einfo "ISO already exists: ${iso_path}"
        ISO_FILE="${iso_path}"
        export ISO_FILE
        return 0
    fi

    einfo "Downloading ISO: ${ISO_FILENAME}"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would download ${ISO_URL} → ${iso_path}"
        ISO_FILE="${iso_path}"
        export ISO_FILE
        return 0
    fi

    try "Downloading PorteuX ISO" \
        curl -fSL --progress-bar -o "${iso_path}" "${ISO_URL}"

    ISO_FILE="${iso_path}"
    export ISO_FILE

    einfo "ISO downloaded: ${iso_path}"
}

# iso_verify — Verify ISO integrity (if checksum available)
iso_verify() {
    local iso_path="${ISO_FILE:?ISO_FILE not set}"

    einfo "Verifying ISO integrity..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would verify ISO"
        return 0
    fi

    if [[ ! -f "${iso_path}" ]]; then
        die "ISO file not found: ${iso_path}"
    fi

    # Try to download checksums
    local checksum_url="${PORTEUX_DOWNLOAD_BASE}/${DESKTOP_VARIANT}/sha256sum.txt"
    local checksum_file="${iso_path}.sha256"

    if curl -fsSL --max-time 10 -o "${checksum_file}" "${checksum_url}" 2>/dev/null; then
        local expected_hash
        expected_hash=$(grep "${ISO_FILENAME}" "${checksum_file}" | awk '{print $1}')
        if [[ -n "${expected_hash}" ]]; then
            local actual_hash
            actual_hash=$(sha256sum "${iso_path}" | awk '{print $1}')
            if [[ "${actual_hash}" == "${expected_hash}" ]]; then
                einfo "SHA256 verification passed"
            else
                eerror "SHA256 mismatch!"
                eerror "  Expected: ${expected_hash}"
                eerror "  Actual:   ${actual_hash}"
                return 1
            fi
        else
            ewarn "Checksum not found for ${ISO_FILENAME}, skipping verification"
        fi
        rm -f "${checksum_file}"
    else
        ewarn "Could not download checksums, skipping verification"
    fi

    # Basic sanity check: file size should be > 100MB
    local size_bytes
    size_bytes=$(stat -c%s "${iso_path}" 2>/dev/null || stat -f%z "${iso_path}" 2>/dev/null || echo 0)
    local min_size=$((100 * 1024 * 1024))
    if [[ ${size_bytes} -lt ${min_size} ]]; then
        eerror "ISO file is suspiciously small (${size_bytes} bytes)"
        return 1
    fi

    einfo "ISO verification passed (${size_bytes} bytes)"
}

# iso_extract — Extract ISO contents to the target partition
# Expects: ISO_FILE, MOUNTPOINT
iso_extract() {
    local iso_path="${ISO_FILE:?ISO_FILE not set}"
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    einfo "Extracting ISO to ${target}..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would extract ${iso_path} → ${target}"
        return 0
    fi

    # Create mount point for ISO
    local iso_mount
    iso_mount=$(mktemp -d "${TMPDIR:-/tmp}/porteux-iso-mount.XXXXXX")

    try "Mounting ISO" mount -o loop,ro "${iso_path}" "${iso_mount}"

    # Copy all contents from ISO to target
    einfo "Copying ISO contents to target..."
    try "Extracting ISO contents" cp -a "${iso_mount}/." "${target}/"

    # Unmount ISO
    try "Unmounting ISO" umount "${iso_mount}"
    rmdir "${iso_mount}"

    # Clean up downloaded ISO to save space
    rm -f "${iso_path}"

    # Verify key directories exist
    if [[ ! -d "${target}/${PORTEUX_MODULES_DIR}" ]]; then
        ewarn "Creating modules directory: ${target}/${PORTEUX_MODULES_DIR}"
        mkdir -p "${target}/${PORTEUX_MODULES_DIR}"
    fi

    if [[ ! -d "${target}/${PORTEUX_OPTIONAL_DIR}" ]]; then
        mkdir -p "${target}/${PORTEUX_OPTIONAL_DIR}"
    fi

    einfo "ISO extracted successfully"
}

# _find_iso_file — Find existing ISO file on disk (for resume)
_find_iso_file() {
    local search_dir="${MOUNTPOINT}/tmp"

    if [[ -d "${search_dir}" ]]; then
        local f
        for f in "${search_dir}"/PorteuX-*.iso; do
            if [[ -f "${f}" ]]; then
                ISO_FILE="${f}"
                ISO_FILENAME="$(basename "${f}")"
                export ISO_FILE ISO_FILENAME
                einfo "Found existing ISO: ${ISO_FILE}"
                return 0
            fi
        done
    fi

    return 1
}
