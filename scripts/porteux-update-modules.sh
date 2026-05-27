#!/usr/bin/env bash
# porteux-update-modules — Check for newer PorteuX modules in the latest GitHub
# release; optionally download them to /porteux/modules/ and remove the older
# versions. Run as root on the booted PorteuX system.
#
# Usage:
#   porteux-update-modules                  # check only — show what's outdated
#   porteux-update-modules --download       # also fetch & replace
#   MODULES_DIR=/path porteux-update-modules ...   # override modules location
#
# PorteuX module filenames carry a date stamp:
#     003-lxqt-2.3.0-current-20260228.xzm
# A newer release for the same prefix bumps that stamp (and possibly the app
# version segment). We match by the prefix BEFORE "-current-YYYYMMDD.xzm" and
# pick the newest date for each.

set -Eeuo pipefail

API="${PORTEUX_RELEASE_API:-https://api.github.com/repos/porteux/porteux/releases/latest}"

# Locate the boot partition's /porteux/modules. On a booted PorteuX system the
# modules don't live at /porteux/modules — that path is empty / doesn't exist.
# They sit on the boot partition mounted under /mnt/<device>/porteux/modules.
# Honor MODULES_DIR override first, otherwise probe likely locations.
_find_modules_dir() {
    [[ -n "${MODULES_DIR:-}" && -d "${MODULES_DIR}" ]] && { echo "${MODULES_DIR}"; return 0; }
    local c
    for c in /porteux/modules /mnt/*/porteux/modules; do
        [[ -d "${c}" ]] || continue
        # require at least one .xzm so we don't latch onto an empty stub
        compgen -G "${c}/*.xzm" >/dev/null 2>&1 || continue
        echo "${c}"; return 0
    done
    return 1
}
MODULES_DIR="$(_find_modules_dir)" || { echo "ERR: could not locate /porteux/modules (set MODULES_DIR=/path to override)" >&2; exit 1; }

DO_DOWNLOAD=0
case "${1:-}" in
    --download|-d) DO_DOWNLOAD=1 ;;
    -h|--help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "") ;;
    *) echo "unknown arg: $1 (use --download or --help)" >&2; exit 2 ;;
esac

command -v curl >/dev/null || { echo "ERR: curl required" >&2; exit 1; }
if [[ ${DO_DOWNLOAD} -eq 1 && $(id -u) -ne 0 ]]; then
    echo "ERR: --download needs root (writing to ${MODULES_DIR})" >&2; exit 1
fi

echo "Querying ${API} ..."
json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    --retry 5 --retry-delay 3 --retry-all-errors "${API}")
[[ -n "${json}" ]] || { echo "ERR: empty API response" >&2; exit 1; }

mapfile -t urls < <(printf '%s' "${json}" \
    | grep -oP '"browser_download_url":\s*"\K[^"]+\.xzm')
[[ ${#urls[@]} -gt 0 ]] || { echo "No .xzm assets in the latest release."; exit 0; }

# Helper: strip "-current-YYYYMMDD.xzm" → return name prefix.
_prefix() { echo "$1" | sed -E 's/-current-[0-9]+\.xzm$//'; }
_date()   { echo "$1" | grep -oP '[0-9]{8}(?=\.xzm$)' || echo 0; }

shopt -s nullglob
declare -a updates=()
for local_path in "${MODULES_DIR}"/*.xzm; do
    lname=$(basename "${local_path}")
    lprefix=$(_prefix "${lname}")
    ldate=$(_date "${lname}")
    for url in "${urls[@]}"; do
        rname=$(basename "${url}")
        rprefix=$(_prefix "${rname}")
        if [[ "${rprefix}" == "${lprefix}" ]]; then
            rdate=$(_date "${rname}")
            if [[ "${rdate}" > "${ldate}" ]]; then
                updates+=("${lprefix}|${ldate}|${rdate}|${url}|${local_path}")
            fi
            break
        fi
    done
done

if [[ ${#updates[@]} -eq 0 ]]; then
    echo "All ${MODULES_DIR} modules are up to date."
    exit 0
fi

echo
echo "Updates available:"
printf '  %-50s %-10s -> %s\n' "MODULE" "INSTALLED" "LATEST"
for u in "${updates[@]}"; do
    IFS='|' read -r prefix ld rd _ _ <<< "${u}"
    printf '  %-50s %-10s -> %s\n' "${prefix}" "${ld}" "${rd}"
done

if [[ ${DO_DOWNLOAD} -ne 1 ]]; then
    echo
    echo "Re-run with --download to fetch them (then reboot)."
    exit 0
fi

echo
for u in "${updates[@]}"; do
    IFS='|' read -r prefix ld rd url old_path <<< "${u}"
    new_path="${MODULES_DIR}/$(basename "${url}")"
    echo "↓ ${prefix}: ${ld} -> ${rd}"
    curl -fSL -C - --connect-timeout 10 --max-time 900 \
        --retry 5 --retry-delay 5 --retry-all-errors \
        --progress-bar -o "${new_path}" "${url}"
    if [[ "${old_path}" != "${new_path}" && -f "${old_path}" ]]; then
        rm -f "${old_path}" && echo "  removed old: $(basename "${old_path}")"
    fi
done

sync
echo
echo "Done. Reboot to load the new modules."
