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

    # Locale data is not "optional" when a non-English locale was chosen — wire it
    # up first so it auto-loads at boot (handles its own DRY-RUN reporting).
    modules_ensure_locale_support

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

# _locale_needs_i18n — True (0) when LOCALE is outside the base glibc set.
# PorteuX's base system only generates C / en_US locales (see 001-core glibc
# SUPPORTED-LOCALES upstream); every other locale (pl_PL, de_DE, en_GB, ru_RU...)
# needs the glibc-i18n data that ships in the 08-multilanguage module.
_locale_needs_i18n() {
    case "${LOCALE:-en_US.UTF-8}" in
        C|C.UTF-8|POSIX|en_US|en_US.*) return 1 ;;
        *) return 0 ;;
    esac
}

# modules_ensure_locale_support — When a non-base locale was selected, make the
# language data actually available at FIRST boot by placing 08-multilanguage in
# the auto-loading modules dir (NOT optional/, which needs a manual `activate`).
# Without this, setting LANG=pl_PL.UTF-8 just yields "Cannot set LC_ALL to default
# locale" and the system falls back to C.
modules_ensure_locale_support() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    _locale_needs_i18n || return 0

    einfo "Locale '${LOCALE:-}' needs glibc-i18n — ensuring 08-multilanguage auto-loads"

    local modules_dir="${target}/${PORTEUX_MODULES_DIR}"
    mkdir -p "${modules_dir}"

    # Already shipped in the base modules / previously placed?
    local existing
    for existing in "${modules_dir}"/08-multilanguage*.xzm; do
        if [[ -f "${existing}" ]]; then
            einfo "  08-multilanguage already present in auto-loading modules"
            return 0
        fi
    done

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would auto-load 08-multilanguage for locale ${LOCALE:-} into /${PORTEUX_MODULES_DIR}"
        return 0
    fi

    if _download_optional_module "08-multilanguage" "${modules_dir}"; then
        einfo "  08-multilanguage placed in auto-loading modules for locale ${LOCALE:-}"
    else
        ewarn "  Could not fetch 08-multilanguage — locale ${LOCALE:-} may fall back to C"
        ewarn "  After boot, download it and run: activate 08-multilanguage"
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

    # Resolve the real asset URL from the GitHub release. Module filenames carry a
    # date stamp (e.g. 05-devel-current-20260228.xzm), so they can't be hardcoded.
    local module_url
    module_url=$(porteux_resolve_asset_url "/${module_name}-.*\.xzm$" || true)

    if [[ -z "${module_url}" ]]; then
        ewarn "  Could not resolve URL for ${module_name} module (may need manual download)"
        return 1
    fi

    local out="${target_dir}/$(basename "${module_url}")"
    # Retry + resume so big modules (locale = 165 MB) survive flaky downloads.
    # -C - resumes a partial file; --retry-all-errors covers transient HTTP/net hiccups.
    if curl -fsSL -C - --connect-timeout 10 --max-time 600 \
        --retry 5 --retry-delay 5 --retry-all-errors \
        -o "${out}" "${module_url}" 2>/dev/null; then
        einfo "  Downloaded: $(basename "${out}")"
        return 0
    else
        ewarn "  Could not download ${module_name} module (may need manual download)"
        # Don't leave a partial file behind — it would fool a later run into
        # thinking the module is already there.
        [[ -f "${out}" && ! -s "${out}" ]] && rm -f "${out}"
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

    # The NVIDIA driver is published as a .zip asset (e.g. nvidia-driver-current.zip)
    # that contains the .xzm module(s), not a bare .xzm.
    local nvidia_url
    nvidia_url=$(porteux_resolve_asset_url "/nvidia-driver.*\.(zip|xzm)$" || true)

    if [[ -z "${nvidia_url}" ]]; then
        ewarn "  Could not resolve NVIDIA driver URL (may need manual download)"
        return 1
    fi

    local out="${target_dir}/$(basename "${nvidia_url}")"
    if ! curl -fsSL -C - --connect-timeout 10 --max-time 900 \
        --retry 5 --retry-delay 5 --retry-all-errors \
        -o "${out}" "${nvidia_url}" 2>/dev/null; then
        ewarn "  Could not download NVIDIA driver (may need manual download)"
        [[ -f "${out}" && ! -s "${out}" ]] && rm -f "${out}"
        return 1
    fi

    case "${out}" in
        *.xzm)
            einfo "  Downloaded: $(basename "${out}")"
            return 0
            ;;
        *.zip)
            if command -v unzip &>/dev/null; then
                if unzip -o -j "${out}" '*.xzm' -d "${target_dir}" &>/dev/null; then
                    rm -f "${out}"
                    einfo "  Downloaded and extracted NVIDIA driver module(s)"
                    return 0
                fi
                ewarn "  Downloaded NVIDIA zip but found no .xzm inside: ${out}"
                return 1
            fi
            ewarn "  Downloaded NVIDIA zip to ${out} — install 'unzip' or extract the .xzm manually"
            return 1
            ;;
    esac
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
