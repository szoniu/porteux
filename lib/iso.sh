#!/usr/bin/env bash
# iso.sh — PorteuX ISO download, verification, and extraction
source "${LIB_DIR}/protection.sh"

# PORTEUX_RELEASE_API — GitHub "latest release" endpoint. PorteuX ISOs and
# optional .xzm modules are published as assets here, with date/version stamps in
# their filenames, so download URLs must be resolved from this metadata rather
# than constructed by hand.
: "${PORTEUX_RELEASE_API:=https://api.github.com/repos/porteux/porteux/releases/latest}"

# porteux_resolve_asset_url — Resolve a release asset's download URL by filename.
# $1: extended-regex matched (case-insensitive) against each browser_download_url.
# Echoes the first matching URL and returns 0; returns 1 on no match / no network.
porteux_resolve_asset_url() {
    local pattern="$1"
    command -v curl &>/dev/null || return 1

    # Cache the API response across calls — multiple modules + the ISO each call
    # this; one API hit (with retries) beats N (and the GitHub anon rate-limit).
    if [[ -z "${_PORTEUX_RELEASE_JSON:-}" ]]; then
        _PORTEUX_RELEASE_JSON=$(curl -fsSL --connect-timeout 10 --max-time 30 \
            --retry 5 --retry-delay 3 --retry-all-errors \
            "${PORTEUX_RELEASE_API}" 2>/dev/null || true)
        export _PORTEUX_RELEASE_JSON
    fi
    [[ -n "${_PORTEUX_RELEASE_JSON}" ]] || return 1

    local url
    url=$(printf '%s' "${_PORTEUX_RELEASE_JSON}" \
        | grep -oP '"browser_download_url":\s*"\K[^"]+' \
        | grep -iE "${pattern}" \
        | head -n1 || true)

    [[ -n "${url}" ]] || return 1
    printf '%s\n' "${url}"
}

# iso_get_url — Determine the ISO download URL for the selected desktop variant
# Sets: ISO_URL, ISO_FILENAME
#
# PorteuX ISO filenames embed the desktop-app version, e.g.
#   porteux-2.6-current-lxqt-2.3.0-x86_64.iso
# That version segment (here "2.3.0") differs per variant AND per release, so the
# filename CANNOT be reconstructed from variant + tag alone. We therefore query
# the GitHub release assets and pick the one matching the chosen variant, using
# its real browser_download_url.
iso_get_url() {
    local variant="${DESKTOP_VARIANT:?DESKTOP_VARIANT not set}"

    einfo "Resolving ISO URL for variant: ${variant}"

    if [[ -n "${ISO_URL:-}" ]]; then
        if [[ "${_ISO_AUTORESOLVED_VARIANT:-}" == "${variant}" ]]; then
            # Already auto-resolved for this exact variant — reuse.
            ISO_FILENAME="$(basename "${ISO_URL}")"
            return 0
        elif [[ -z "${_ISO_AUTORESOLVED_VARIANT:-}" ]]; then
            # URL came from a preset/env, not our own resolution — honor it verbatim.
            ISO_FILENAME="$(basename "${ISO_URL}")"
            einfo "Using custom ISO URL: ${ISO_URL}"
            return 0
        fi
        # Auto-resolved for a DIFFERENT variant (user changed DE via Back) — re-resolve.
        ISO_URL=""
    fi

    if ! command -v curl &>/dev/null; then
        die "curl is required to resolve the PorteuX ISO download URL"
    fi

    # Pick the asset whose filename matches porteux-...-<variant>-...-x86_64.iso
    ISO_URL=$(porteux_resolve_asset_url "/porteux-.*-${variant}-.*-x86_64\.iso$" || true)

    if [[ -z "${ISO_URL:-}" ]]; then
        # In dry-run we tolerate a missing/unreachable API (download is simulated).
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            ewarn "Could not resolve ISO URL for '${variant}' (dry-run): using placeholder"
            ISO_FILENAME="porteux-${variant}-x86_64.iso"
            ISO_URL="https://github.com/porteux/porteux/releases/download/UNKNOWN/${ISO_FILENAME}"
            _ISO_AUTORESOLVED_VARIANT="${variant}"
            export ISO_URL ISO_FILENAME _ISO_AUTORESOLVED_VARIANT
            return 0
        fi
        die "Could not resolve a PorteuX ISO for variant '${variant}' from ${PORTEUX_RELEASE_API}.
Check network connectivity, or set a custom ISO_URL before running."
    fi

    ISO_FILENAME="$(basename "${ISO_URL}")"
    _ISO_AUTORESOLVED_VARIANT="${variant}"
    export ISO_URL ISO_FILENAME _ISO_AUTORESOLVED_VARIANT

    einfo "ISO URL: ${ISO_URL}"
    einfo "ISO filename: ${ISO_FILENAME}"
}

# _iso_ensure_filename — derive ISO_FILENAME from ISO_URL when unset.
# The URL resolver sets ISO_FILENAME during the wizard, but only ISO_URL is a
# CONFIG_VAR — so --install/resume (which load from the saved config) never get
# ISO_FILENAME and would hit "unbound variable" under set -u. Derive it here.
_iso_ensure_filename() {
    [[ -n "${ISO_FILENAME:-}" ]] && return 0
    [[ -n "${ISO_URL:-}" ]] || die "ISO_URL not set — cannot derive ISO filename"
    ISO_FILENAME="$(basename "${ISO_URL}")"
    export ISO_FILENAME
}

# iso_download — Download the PorteuX ISO
# Expects: ISO_URL, MOUNTPOINT (derives ISO_FILENAME from ISO_URL if unset)
iso_download() {
    _iso_ensure_filename
    local download_dir="${MOUNTPOINT}/tmp"
    mkdir -p "${download_dir}"

    local iso_path="${download_dir}/${ISO_FILENAME}"
    ISO_FILE="${iso_path}"
    export ISO_FILE

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would download ${ISO_URL} → ${iso_path}"
        return 0
    fi

    # If a (possibly partial) file exists, compare its size to the remote:
    # skip if already complete, otherwise resume the rest. Never blindly trust
    # an existing file — an interrupted download leaves a truncated ISO.
    if [[ -f "${iso_path}" ]]; then
        local remote_size local_size
        remote_size=$(curl -fsSLI "${ISO_URL}" 2>/dev/null \
            | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v}')
        local_size=$(stat -c%s "${iso_path}" 2>/dev/null || echo 0)
        if [[ -n "${remote_size}" && "${local_size}" == "${remote_size}" ]]; then
            einfo "ISO already complete (${local_size} bytes): ${iso_path}"
            return 0
        fi
        einfo "Resuming partial ISO download (${local_size}/${remote_size:-?} bytes)..."
    else
        einfo "Downloading ISO: ${ISO_FILENAME}"
    fi

    # -C - resumes from where a previous attempt stopped; --retry rides out
    # transient drops; try's "Retry" also resumes (same flags).
    try "Downloading PorteuX ISO" \
        curl -fSL -C - --retry 5 --retry-delay 3 --progress-bar \
            -o "${iso_path}" "${ISO_URL}"

    einfo "ISO downloaded: ${iso_path}"
}

# iso_verify — Verify ISO integrity (if checksum available)
iso_verify() {
    _iso_ensure_filename
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
    # Checksum lives alongside the ISO (same path prefix as iso_get_url)
    local iso_dir
    iso_dir=$(dirname "${ISO_URL:-}")
    local checksum_url="${iso_dir}/sha256sum.txt"
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
        # Real PorteuX ISO filenames are lowercase: porteux-<ver>-current-<variant>-...iso
        for f in "${search_dir}"/porteux-*.iso; do
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
