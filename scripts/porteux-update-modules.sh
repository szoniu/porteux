#!/usr/bin/env bash
# porteux-update-modules — Update PorteuX from the latest GitHub release.
#
# Two scopes:
#   (default)        check OPTIONAL .xzm modules; --download to fetch & replace
#   --upgrade-base   full BASE upgrade (kernel/core/gui/desktop) from the ISO,
#                    keeping /porteux/changes (persistence) and /porteux/optional.
#
# Usage:
#   porteux-update-modules                         # check optional modules only
#   porteux-update-modules --download              # fetch & replace optional modules
#   porteux-update-modules --upgrade-base          # base 2.6->2.7 from a fresh ISO
#   porteux-update-modules --upgrade-base --iso /path/to.iso   # reuse a local ISO file
#   porteux-update-modules --upgrade-base --iso /mnt/sdb1      # reuse a mounted ISO tree
#   MODULES_DIR=/path porteux-update-modules ...   # override modules location
#
# Optional modules carry a date stamp (08-multilanguage-current-YYYYMMDD.xzm); a
# newer release bumps that stamp. The BASE modules (000-kernel/001-core/002-gui/
# 003-<desktop>) are NOT published as standalone assets — they live only inside
# the ISO — so moving the base across releases needs the ISO (--upgrade-base).
#
# SAFETY: the base modules of the RUNNING system are loop-mounted and in use;
# overwriting them on the live medium corrupts the running base. --upgrade-base
# refuses unless the target /porteux is NOT live — i.e. you booted from another
# medium (target appears under /mnt/<dev>) or used the copy2ram cheatcode (disk
# base not held open). Override with --force only if you understand the risk.

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

# ---- argument parsing -------------------------------------------------------
MODE="optional"        # optional | upgrade-base
DO_DOWNLOAD=0
ISO_SRC=""
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --download|-d)  DO_DOWNLOAD=1 ;;
        --upgrade-base) MODE="upgrade-base" ;;
        --iso)          shift; ISO_SRC="${1:?--iso needs a path}" ;;
        --force)        FORCE=1 ;;
        -h|--help)      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; exit 0 ;;
        *) echo "unknown arg: $1 (use --download, --upgrade-base, --iso, --force, --help)" >&2; exit 2 ;;
    esac
    shift
done

command -v curl >/dev/null || { echo "ERR: curl required" >&2; exit 1; }

MODULES_DIR="$(_find_modules_dir)" || { echo "ERR: could not locate /porteux/modules (set MODULES_DIR=/path to override)" >&2; exit 1; }

# =============================================================================
# BASE upgrade (full release bump from the ISO)
# =============================================================================
_iso_mnt=""; _iso_mounted=0
_ub_cleanup() { [[ ${_iso_mounted} -eq 1 && -n "${_iso_mnt}" ]] && { umount "${_iso_mnt}" 2>/dev/null || true; rmdir "${_iso_mnt}" 2>/dev/null || true; }; }

upgrade_base() {
    [[ $(id -u) -eq 0 ]] || { echo "ERR: --upgrade-base needs root (writes base modules + boot files)" >&2; exit 1; }
    trap _ub_cleanup EXIT

    local porteux_root media
    porteux_root="$(cd "${MODULES_DIR}/.." && pwd)"   # e.g. /mnt/sdb1/porteux
    media="$(cd "${porteux_root}/.." && pwd)"          # e.g. /mnt/sdb1

    # Detect the installed desktop variant from the 003-<desktop> base module so
    # we fetch the matching ISO (kde/xfce/lxqt/cinnamon/mate/gnome/lxde/cosmic).
    local base003 variant
    base003="$(ls "${MODULES_DIR}"/003-*.xzm 2>/dev/null | head -n1 || true)"
    [[ -n "${base003}" ]] || { echo "ERR: no 003-<desktop> base module in ${MODULES_DIR} — is this a PorteuX install?" >&2; exit 1; }
    variant="$(basename "${base003}" | sed -E 's/^003-([a-z]+)-.*/\1/')"
    echo "Target media:   ${media}"
    echo "PorteuX dir:    ${porteux_root}"
    echo "Detected DE:    ${variant}"

    # ---- safety gate: never overwrite base modules that are in active use -----
    local live=0 f
    if command -v losetup >/dev/null 2>&1; then
        local backing; backing="$(losetup -a 2>/dev/null || true)"
        for f in "${MODULES_DIR}"/000-*.xzm "${MODULES_DIR}"/001-*.xzm \
                 "${MODULES_DIR}"/002-*.xzm "${MODULES_DIR}"/003-*.xzm; do
            [[ -e "$f" ]] || continue
            if grep -qF "$(realpath "$f")" <<<"${backing}"; then live=1; break; fi
        done
    else
        live=1   # can't prove it's idle → treat as live unless forced
    fi
    if [[ ${live} -eq 1 && ${FORCE} -ne 1 ]]; then
        cat >&2 <<EOF
ERR: the base modules under ${MODULES_DIR} are loop-mounted / in use (or cannot be
     proven idle). Overwriting them on the LIVE system corrupts the running base.
     Do one of:
       - boot from the new PorteuX ISO/USB, then run this against the OTHER disk
         (its /porteux appears under /mnt/<dev>), or
       - boot the current system with the 'copy2ram' cheatcode (disk base not held), or
       - re-run with --force if you understand the risk.
EOF
        exit 1
    fi

    # ---- obtain the ISO --------------------------------------------------------
    if [[ -n "${ISO_SRC}" && -d "${ISO_SRC}" ]]; then
        _iso_mnt="${ISO_SRC}"                         # already-mounted ISO tree
        echo "Using mounted ISO tree: ${_iso_mnt}"
    else
        local iso_file="${ISO_SRC}"
        if [[ -z "${iso_file}" ]]; then
            echo "Resolving ${variant} ISO from ${API} ..."
            local json url
            json="$(curl -fsSL --connect-timeout 10 --max-time 30 \
                --retry 5 --retry-delay 3 --retry-all-errors "${API}")"
            url="$(printf '%s' "${json}" \
                | grep -oP '"browser_download_url":\s*"\K[^"]+' \
                | grep -iE "/porteux-.*-${variant}-.*-x86_64\.iso$" | head -n1 || true)"
            [[ -n "${url}" ]] || { echo "ERR: no ${variant} ISO in the latest release" >&2; exit 1; }
            iso_file="${media}/tmp/$(basename "${url}")"
            mkdir -p "${media}/tmp"
            echo "Downloading $(basename "${url}") (>1 GB, needs free space on ${media}) ..."
            curl -fSL -C - --connect-timeout 10 --max-time 3600 \
                --retry 5 --retry-delay 5 --retry-all-errors \
                --progress-bar -o "${iso_file}" "${url}"
        fi
        [[ -f "${iso_file}" ]] || { echo "ERR: ISO not found: ${iso_file}" >&2; exit 1; }
        _iso_mnt="$(mktemp -d)"; _iso_mounted=1
        mount -o loop,ro "${iso_file}" "${_iso_mnt}"
    fi

    [[ -d "${_iso_mnt}/porteux/modules" ]] || { echo "ERR: ${_iso_mnt}/porteux/modules missing — not a PorteuX ISO?" >&2; exit 1; }

    # ---- back up the current base + boot --------------------------------------
    local stamp bak; stamp="$(date +%Y%m%d-%H%M%S)"
    bak="${porteux_root}/.upgrade-backup-${stamp}"
    mkdir -p "${bak}/modules" "${bak}/boot-syslinux" "${bak}/EFI-BOOT"
    echo "Backing up old base -> ${bak}"
    for f in "${MODULES_DIR}"/000-*.xzm "${MODULES_DIR}"/001-*.xzm \
             "${MODULES_DIR}"/002-*.xzm "${MODULES_DIR}"/003-*.xzm; do
        [[ -e "$f" ]] && mv "$f" "${bak}/modules/"
    done
    [[ -d "${media}/boot/syslinux" ]] && cp -a "${media}/boot/syslinux/vmlinuz" "${media}/boot/syslinux/"initrd.* "${bak}/boot-syslinux/" 2>/dev/null || true
    [[ -d "${media}/EFI/BOOT" ]] && cp -a "${media}/EFI/BOOT/." "${bak}/EFI-BOOT/" 2>/dev/null || true

    # ---- install the new base + boot ------------------------------------------
    echo "Installing new base modules ..."
    cp -v "${_iso_mnt}/porteux/modules/"*.xzm "${MODULES_DIR}/"

    if [[ -d "${media}/boot/syslinux" ]]; then
        echo "Installing new kernel + initrd ..."
        cp -v "${_iso_mnt}/boot/syslinux/vmlinuz" "${media}/boot/syslinux/"
        cp -v "${_iso_mnt}/boot/syslinux/"initrd.* "${media}/boot/syslinux/"
    else
        echo "WARN: ${media}/boot/syslinux not found — copy the new vmlinuz/initrd to your boot dir manually."
    fi

    if [[ -d "${_iso_mnt}/EFI/BOOT" && -d "${media}/EFI/BOOT" ]]; then
        echo "Refreshing EFI loader ..."
        cp -rL "${_iso_mnt}/EFI/BOOT/." "${media}/EFI/BOOT/"
    elif [[ -d "${_iso_mnt}/EFI/BOOT" ]]; then
        echo "WARN: no ${media}/EFI/BOOT here. If you boot via a separate ESP, copy"
        echo "      ${_iso_mnt}/EFI/BOOT/* onto that ESP manually."
    fi
    # NOTE: porteux.cfg is intentionally KEPT — it holds YOUR DEFAULT/changes/login
    # boot settings. New ISO cheatcodes (e.g. kvm.enable_virt_at_load=0) are not
    # merged; add them by hand if you need them.

    sync
    _ub_cleanup

    cat <<EOF

Base upgraded for variant '${variant}'. Kept: /porteux/changes (persistence) and
/porteux/optional. Reboot to load the new base.

If the new base misbehaves (e.g. a stale 2.6 changes overlay clashes with 2.7
libraries), roll back in one shot:
  rm -f ${MODULES_DIR}/000-*.xzm ${MODULES_DIR}/001-*.xzm ${MODULES_DIR}/002-*.xzm ${MODULES_DIR}/003-*.xzm && \\
    mv ${bak}/modules/*.xzm ${MODULES_DIR}/ && \\
    cp -a ${bak}/boot-syslinux/. ${media}/boot/syslinux/ && \\
    cp -a ${bak}/EFI-BOOT/. ${media}/EFI/BOOT/ 2>/dev/null; sync

Once 2.7 is confirmed good, reclaim space: rm -rf ${bak}
EOF
}

if [[ "${MODE}" == "upgrade-base" ]]; then
    upgrade_base
    exit 0
fi

# =============================================================================
# OPTIONAL-module update (date-stamped assets in the release)
# =============================================================================
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
