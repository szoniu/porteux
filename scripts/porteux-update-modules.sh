#!/usr/bin/env bash
# porteux-update-modules — Update PorteuX from the latest GitHub release.
#
# Three scopes:
#   (default)          check OPTIONAL .xzm modules; --download to fetch & replace
#   --upgrade-base     full BASE upgrade (kernel/core/gui/desktop) from the ISO,
#                      keeping /porteux/changes (persistence) and /porteux/optional
#   --fix-persistence  repair boot labels that lost `changes=` (rescue mode; no
#                      module is touched)
#
# Usage:
#   porteux-update-modules                         # check optional modules only
#   porteux-update-modules --download              # fetch & replace optional modules
#   porteux-update-modules --upgrade-base          # base 2.7->2.8 from a fresh ISO
#   porteux-update-modules --upgrade-base --iso /path/to.iso   # reuse a local ISO file
#   porteux-update-modules --upgrade-base --iso /mnt/sdb1      # reuse a mounted ISO tree
#   porteux-update-modules --fix-persistence       # put changes= back on every boot label
#   porteux-update-modules --fix-persistence --cfg /mnt/sda1/boot/syslinux/porteux.cfg
#   porteux-update-modules --upgrade-base --esp /mnt/sda1   # UEFI: second kernel copy
#   porteux-update-modules --upgrade-base --no-esp          # BIOS-only install
#   MODULES_DIR=/path porteux-update-modules ...   # override extra-modules location
#   BASE_DIR=/path porteux-update-modules ...      # override base-modules location
#
# THREE module directories (upstream boot/docs/cheatcodes.txt), do not conflate:
#   /porteux/base      000-kernel, 001-core, 002-gui, 002-xtra, 003-<desktop> —
#                      the release itself. Auto-loaded. Replaced only by an ISO.
#   /porteux/modules   extra modules; ALSO auto-loaded at every boot.
#   /porteux/optional  parked modules; need `activate` or the `load=` cheatcode.
#
# Optional modules carry a date stamp (08-multilanguage-current-YYYYMMDD.xzm); a
# newer release bumps that stamp. The BASE modules are NOT published as
# standalone assets — they live only inside the ISO — so moving the base across
# releases needs the ISO (--upgrade-base).
#
# SAFETY: the base modules of the RUNNING system are loop-mounted and in use;
# overwriting them on the live medium corrupts the running base. --upgrade-base
# refuses unless the target /porteux is NOT live — i.e. you booted from another
# medium (target appears under /mnt/<dev>) or used the copy2ram cheatcode (disk
# base not held open). Override with --force only if you understand the risk.
#
# NOTE ON copy2ram: `copy2ram` alone is NOT enough — the boot label must ALSO
# carry `changes=/porteux`, otherwise the session comes up without your overlay
# (no user accounts, and this very script is missing from /usr/local/bin). The
# installer writes changes= onto every persistent label; an older install may
# have it on the default label only — that is what --fix-persistence repairs.
# An overlay-independent copy of this script always sits next to the modules:
#   bash /mnt/<dev>/porteux/porteux-update-modules --help

set -Eeuo pipefail

API="${PORTEUX_RELEASE_API:-https://api.github.com/repos/porteux/porteux/releases/latest}"

# Locate the PorteuX directories on the boot partition. On a booted PorteuX
# system they are NOT at /porteux — that path is empty or absent; the boot
# partition is mounted under /mnt/<device>. An explicit override is a contract:
# if it is set but wrong, fail loudly instead of silently probing elsewhere.
_find_dir() {   # $1 = leaf (base|modules|optional), $2 = override value, $3 = override name
    local leaf="$1" override="$2" c
    if [[ -n "${override}" ]]; then
        # Validated in the main body — an `exit` here would only kill the $( )
        # subshell and the caller would silently fall through to autodetection.
        [[ -d "${override}" ]] || return 1
        echo "${override}"; return 0
    fi
    for c in "/porteux/${leaf}" /mnt/*/porteux/"${leaf}"; do
        [[ -d "${c}" ]] || continue
        compgen -G "${c}/*.xzm" >/dev/null 2>&1 || continue
        echo "${c}"; return 0
    done
    return 1
}

# Base modules (000-003). Newer PorteuX keeps them in /porteux/base; very old
# layouts (and hand-made installs) put everything in /porteux/modules, so fall
# back to a modules dir that actually holds a 003-* module.
_find_base_dir() {
    local d
    if d="$(_find_dir base "${BASE_DIR:-}" BASE_DIR)"; then echo "${d}"; return 0; fi
    # An explicit override is a contract: never quietly fall back to a probe.
    [[ -z "${BASE_DIR:-}" ]] || return 1
    for d in /porteux/modules /mnt/*/porteux/modules; do
        compgen -G "${d}/003-*.xzm" >/dev/null 2>&1 || continue
        echo "${d}"; return 0
    done
    return 1
}

# Extra auto-loading modules (/porteux/modules). May legitimately be empty on a
# fresh install, so fall back to the sibling of the base dir.
_find_modules_dir() {
    local d
    if d="$(_find_dir modules "${MODULES_DIR:-}" MODULES_DIR)"; then echo "${d}"; return 0; fi
    return 1
}

# Is the running session using an on-disk persistence overlay? Returns 0 = yes.
# Reads the kernel cmdline, which is authoritative for the session we are in.
_persistence_status() {
    [[ -r /proc/cmdline ]] || { echo "unknown"; return 1; }   # not a booted Linux
    local cl; cl="$(cat /proc/cmdline)"
    if [[ "${cl}" == *"changes=EXIT:"* ]]; then echo "exit-buffer"; return 1; fi
    if [[ "${cl}" == *"changes="* ]];      then echo "on-disk";     return 0; fi
    echo "none"; return 1
}

# ---- argument parsing -------------------------------------------------------
MODE="optional"        # optional | upgrade-base | fix-persistence
DO_DOWNLOAD=0
ASSUME_YES=0
declare -a CFG_PATHS=() ESP_PATHS=()
NO_ESP=0
ISO_SRC=""
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --download|-d)      DO_DOWNLOAD=1 ;;
        --upgrade-base)     MODE="upgrade-base" ;;
        --fix-persistence)  MODE="fix-persistence" ;;
        --iso)              shift; ISO_SRC="${1:?--iso needs a path}" ;;
        --base-dir)         shift; BASE_DIR="${1:?--base-dir needs a path}" ;;
        --cfg)              shift; CFG_PATHS+=("${1:?--cfg needs a path}") ;;
        --esp)              shift; ESP_PATHS+=("${1:?--esp needs a path}") ;;
        --no-esp)           NO_ESP=1 ;;
        --yes|-y)           ASSUME_YES=1 ;;
        --modules-dir)      shift; MODULES_DIR="${1:?--modules-dir needs a path}" ;;
        --force)            FORCE=1 ;;
        -h|--help)      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; exit 0 ;;
        *) echo "unknown arg: $1 (use --download, --upgrade-base, --fix-persistence, --iso, --base-dir, --modules-dir, --esp, --no-esp, --cfg, --yes, --force, --help)" >&2; exit 2 ;;
    esac
    shift
done

command -v curl >/dev/null || { echo "ERR: curl required" >&2; exit 1; }

# An override that points nowhere must stop the run here — not fall through to
# autodetection and then operate on some other install.
for _ov in BASE_DIR MODULES_DIR; do
    if [[ -n "${!_ov:-}" && ! -d "${!_ov}" ]]; then
        echo "ERR: ${_ov}=${!_ov} is not a directory" >&2; exit 1
    fi
done
unset _ov

# Tell the user up front which session they are in — a session without an
# on-disk overlay is exactly why this script sometimes "doesn't exist".
PERSIST_STATE="$(_persistence_status || true)"
case "${PERSIST_STATE}" in
    on-disk)     ;;
    exit-buffer) echo "NOTE: this session boots with changes=EXIT: — changes live in RAM until a clean shutdown." >&2 ;;
    unknown)     ;;
    none)        echo "NOTE: this session has NO persistence (no changes= on the kernel cmdline). Anything you install now is lost at reboot; run --fix-persistence if your install lost its changes= boot parameter." >&2 ;;
esac

# =============================================================================
# Rescue mode: put `changes=` back on boot labels that lost it
# =============================================================================
# Why this exists: the AUFS overlay (/porteux/changes) holds EVERYTHING the
# installer configured — accounts, passwords, sudoers/polkit, and this script in
# /usr/local/bin. A boot label without `changes=` starts a session where none of
# that exists. Upstream ships `changes=` on the `graphical` label only, so a boot
# menu entry like `Copy To RAM` silently drops the overlay.
fix_persistence() {
    [[ $(id -u) -eq 0 || "${ALLOW_NONROOT_FIX:-0}" == "1" ]] || { echo "ERR: --fix-persistence needs root (rewrites porteux.cfg)" >&2; exit 1; }
    local base="${PORTEUX_CHANGES_BASE:-/porteux}"
    local -a cfgs=() search=()
    local c
    # Explicit --cfg wins (also lets you repair an install mounted elsewhere);
    # otherwise probe every syslinux config an install can have: the data
    # partition's copy and the ESP's copy (both must agree — the firmware reads
    # the ESP one, a BIOS boot reads the other).
    if [[ ${#CFG_PATHS[@]} -gt 0 ]]; then
        search=("${CFG_PATHS[@]}")
    else
        search=(/boot/syslinux/porteux.cfg /mnt/*/boot/syslinux/porteux.cfg \
                /mnt/*/boot/efi/boot/syslinux/porteux.cfg /boot/efi/boot/syslinux/porteux.cfg)
    fi
    for c in "${search[@]}"; do
        [[ -f "${c}" ]] || continue
        grep -q '^[[:space:]]*APPEND' "${c}" 2>/dev/null || continue
        cfgs+=("${c}")
    done
    [[ ${#cfgs[@]} -gt 0 ]] || { echo "ERR: no syslinux porteux.cfg found (looked in: ${search[*]}). Point at it with --cfg /mnt/<dev>/boot/syslinux/porteux.cfg" >&2; exit 1; }

    echo "Boot configs to repair:"
    printf '  %s\n' "${cfgs[@]}"
    # More than one candidate found by probing means we might be touching a
    # DIFFERENT PorteuX install (second disk, another USB). Make that a decision.
    if [[ ${#CFG_PATHS[@]} -eq 0 && ${#cfgs[@]} -gt 1 && ${ASSUME_YES} -ne 1 ]]; then
        echo "ERR: more than one install found. Re-run with --yes to repair all of them," >&2
        echo "     or name the one you mean with --cfg <path>." >&2
        exit 1
    fi

    # LOGIN_USER=<name> re-applies the autologin cheatcode while we are here;
    # unset means "leave whatever login= the labels already carry".
    local login_param=""
    [[ -n "${LOGIN_USER:-}" ]] && login_param="login=${LOGIN_USER}"
    local rc=0
    for c in "${cfgs[@]}"; do
        # cp -f, never cp -a: the ESP copy lives on FAT32, where --preserve=all
        # fails with "Operation not permitted".
        if ! cp -f "${c}" "${c}.bak-$(date +%Y%m%d-%H%M%S)"; then
            echo "WARN: cannot write a backup next to ${c} — skipping it" >&2
            rc=1; continue
        fi
        awk -v changes_param="changes=${base}" -v login_param="${login_param}" '
        BEGIN { curlabel="" }
        {
            line=$0
            if (toupper($1)=="LABEL") { curlabel=$2 }
            if (toupper($1)=="APPEND") {
                rest=substr(line, index(line,$1)+length($1))
                gsub(/[[:space:]]+changes=[^[:space:]]+/, "", rest)
                sub(/^changes=[^[:space:]]+[[:space:]]*/, "", rest)
                if (login_param != "") {
                    gsub(/[[:space:]]+login=[^[:space:]]+/, "", rest)
                    sub(/^login=[^[:space:]]+[[:space:]]*/, "", rest)
                }
                # `fresh` labels are stateless by design (baseonly norootcopy).
                if (tolower(curlabel) !~ /fresh/) {
                    if (login_param != "") { rest=" " login_param rest }
                    rest=" " changes_param rest
                }
                line="APPEND" rest
            }
            print line
        }' "${c}" > "${c}.new" || true
        # Never install an empty or label-less result over a working boot config —
        # this is the rescue tool; producing an unbootable machine here is the one
        # failure it must not have.
        if [[ -s "${c}.new" ]] && grep -q '^[[:space:]]*LABEL' "${c}.new"; then
            cat "${c}.new" > "${c}"
            rm -f "${c}.new"
            echo "fixed: ${c}  (backup: ${c}.bak-*)"
            grep -nE '^(DEFAULT|LABEL|APPEND)' "${c}" | sed 's/^/    /'
        else
            rm -f "${c}.new"
            echo "ERR: rewriting ${c} produced an empty/label-less result — left unchanged" >&2
            rc=1
        fi
    done
    sync
    echo
    echo "Reboot for this to take effect. Every non-'fresh' label now mounts ${base}/changes."
    return ${rc}
}

if [[ "${MODE}" == "fix-persistence" ]]; then
    fix_persistence
    exit 0
fi

# =============================================================================
# BASE upgrade (full release bump from the ISO)
# =============================================================================
_iso_mnt=""; _iso_mounted=0
# Must return 0 even when there is nothing to unmount: this runs as the last
# statement before the success banner, and under `set -e` a trailing `[[ ]] &&`
# that evaluates false would abort the script AFTER the base was swapped —
# swallowing the rollback instructions.
_ub_cleanup() {
    [[ ${_iso_mounted} -eq 1 && -n "${_iso_mnt}" ]] || return 0
    umount "${_iso_mnt}" 2>/dev/null || true
    rmdir "${_iso_mnt}" 2>/dev/null || true
    return 0
}

upgrade_base() {
    [[ $(id -u) -eq 0 ]] || { echo "ERR: --upgrade-base needs root (writes base modules + boot files)" >&2; exit 1; }
    trap _ub_cleanup EXIT

    # The base lives in /porteux/base — NOT /porteux/modules (that one holds
    # extra auto-loading modules). Resolving the wrong one is why an upgrade
    # used to bail out with "is this a PorteuX install?".
    BASE_MODULES_DIR="$(_find_base_dir)" || {
        cat >&2 <<'EOF'
ERR: could not locate the PorteuX base modules (000-kernel/001-core/002-gui/
     003-<desktop>). They normally sit in /porteux/base on the boot partition,
     which appears under /mnt/<device> once booted. Point at it explicitly:
       porteux-update-modules --upgrade-base --base-dir /mnt/<dev>/porteux/base
EOF
        exit 1
    }

    local porteux_root media
    porteux_root="$(cd "${BASE_MODULES_DIR}/.." && pwd)"   # e.g. /mnt/sdb1/porteux
    media="$(cd "${porteux_root}/.." && pwd)"               # e.g. /mnt/sdb1

    # Detect the installed desktop variant from the 003-<desktop> base module so
    # we fetch the matching ISO (kde/xfce/lxqt/cinnamon/mate/gnome/lxde/cosmic).
    # Parse without assuming the version format: 003-kde-6.7.4-current-*.xzm.
    local base003 variant
    base003="$(ls "${BASE_MODULES_DIR}"/003-*.xzm 2>/dev/null | head -n1 || true)"
    [[ -n "${base003}" ]] || { echo "ERR: no 003-<desktop> base module in ${BASE_MODULES_DIR} — is this a PorteuX install?" >&2; exit 1; }
    variant="$(basename "${base003}" .xzm)"; variant="${variant#003-}"; variant="${variant%%-*}"
    [[ -n "${variant}" ]] || { echo "ERR: could not parse the desktop variant from $(basename "${base003}")" >&2; exit 1; }
    echo "Target media:   ${media}"
    echo "PorteuX dir:    ${porteux_root}"
    echo "Base modules:   ${BASE_MODULES_DIR}"
    echo "Detected DE:    ${variant}"

    # ---- safety gate: never overwrite base modules that are in active use -----
    local live=0 f
    if command -v losetup >/dev/null 2>&1; then
        local backing; backing="$(losetup -a 2>/dev/null || true)"
        for f in "${BASE_MODULES_DIR}"/000-*.xzm "${BASE_MODULES_DIR}"/001-*.xzm \
                 "${BASE_MODULES_DIR}"/002-*.xzm "${BASE_MODULES_DIR}"/003-*.xzm; do
            [[ -e "$f" ]] || continue
            if grep -qF "$(realpath "$f")" <<<"${backing}"; then live=1; break; fi
        done
    else
        live=1   # can't prove it's idle → treat as live unless forced
    fi
    if [[ ${live} -eq 1 && ${FORCE} -ne 1 ]]; then
        cat >&2 <<EOF
ERR: the base modules under ${BASE_MODULES_DIR} are loop-mounted / in use (or cannot be
     proven idle). Overwriting them on the LIVE system corrupts the running base.
     Do one of:
       - boot from the new PorteuX ISO/USB, then run this against the OTHER disk
         (its /porteux appears under /mnt/<dev>), or
       - reboot the current system with the 'copy2ram' cheatcode ADDED to your own
         boot label (Esc → highlight your entry → Tab → append " copy2ram"); do
         NOT pick the stock "Copy To RAM" menu entry unless it carries
         changes=/porteux, or the session comes up without your overlay, or
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
            url="$(printf '%s' "${json}" | tr ',' '\n' \
                | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
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

    # ISO layout: the release's base modules are in /porteux/base (older ISOs
    # shipped them in /porteux/modules — accept both).
    local iso_base=""
    if compgen -G "${_iso_mnt}/porteux/base/003-*.xzm" >/dev/null 2>&1; then
        iso_base="${_iso_mnt}/porteux/base"
    elif compgen -G "${_iso_mnt}/porteux/modules/003-*.xzm" >/dev/null 2>&1; then
        iso_base="${_iso_mnt}/porteux/modules"
    else
        echo "ERR: no 003-*.xzm under ${_iso_mnt}/porteux/{base,modules} — not a PorteuX ISO?" >&2; exit 1
    fi
    echo "ISO base dir:   ${iso_base}"

    # ---- which media carry boot files -----------------------------------------
    # A UEFI install made by this installer keeps a SECOND copy of the kernel:
    # the installer copies boot/syslinux and EFI/BOOT onto the ESP (a separate
    # FAT32 partition), and the firmware boots THAT copy. Upgrading only the data
    # partition leaves the old vmlinuz+initrd in charge of a new base — the
    # running kernel then has no matching /lib/modules and the system is dead on
    # arrival. So collect every medium that holds a bootable copy.
    local -a boot_roots=("${media}")
    local c r
    for c in "${ESP_PATHS[@]+"${ESP_PATHS[@]}"}" "${media}/boot/efi" /boot/efi /mnt/*/boot/efi /mnt/*; do
        [[ -d "${c}" ]] || continue
        [[ -f "${c}/EFI/BOOT/bootx64.efi" || -d "${c}/boot/syslinux" ]] || continue
        r="$(cd "${c}" && pwd)"
        [[ "${r}" == "${media}" ]] && continue
        # only real second copies: must carry a kernel or the loader
        [[ -f "${r}/boot/syslinux/vmlinuz" || -f "${r}/EFI/BOOT/bootx64.efi" ]] || continue
        case " ${boot_roots[*]} " in *" ${r} "*) continue ;; esac
        boot_roots+=("${r}")
    done

    if [[ ${#boot_roots[@]} -eq 1 && -d /sys/firmware/efi && ${NO_ESP} -ne 1 && ${FORCE} -ne 1 ]]; then
        cat >&2 <<EOF
ERR: this machine booted in UEFI mode and no ESP with PorteuX boot files was found
     besides ${media}. On a UEFI install the firmware loads vmlinuz/initrd from the
     ESP, so upgrading only ${media} would leave the OLD kernel driving the NEW
     base — an unbootable system. Nothing has been changed yet. Do one of:
       - mount the ESP and point at it:  --esp /mnt/<esp>
       - mount it anywhere under /mnt and re-run (it is auto-detected)
       - if this install really boots via BIOS/syslinux only:  --no-esp
EOF
        exit 1
    fi
    echo "Boot media:     ${boot_roots[*]}"

    # ---- back up the current base + boot --------------------------------------
    local stamp bak; stamp="$(date +%Y%m%d-%H%M%S)"
    bak="${porteux_root}/.upgrade-backup-${stamp}"
    mkdir -p "${bak}/modules"
    echo "Backing up old base -> ${bak}"

    # Enough room for the new base before we move the old one out of the way?
    local need avail
    need="$(du -sk "${iso_base}" 2>/dev/null | cut -f1 || echo 0)"
    avail="$(df -Pk "${BASE_MODULES_DIR}" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
    if [[ "${need}" =~ ^[0-9]+$ && "${avail}" =~ ^[0-9]+$ && ${need} -gt 0 ]]; then
        if (( avail < need * 11 / 10 )); then
            echo "ERR: not enough free space on $(dirname "${BASE_MODULES_DIR}"): need ~$((need/1024)) MiB (+10%), have $((avail/1024)) MiB." >&2
            echo "     Nothing has been changed. Free some space (old .upgrade-backup-* dirs?) and re-run." >&2
            exit 1
        fi
    fi

    # Per-medium backup of the boot files, BEFORE anything is overwritten.
    local slug i=0
    declare -a bak_slugs=()
    for r in "${boot_roots[@]}"; do
        slug="boot-$((i++))"
        bak_slugs+=("${slug}")
        mkdir -p "${bak}/${slug}"
        printf '%s\n' "${r}" > "${bak}/${slug}/.origin"
        if [[ -d "${r}/boot/syslinux" ]]; then
            mkdir -p "${bak}/${slug}/boot-syslinux"
            # cp -rL, never cp -a: an ESP is FAT32 and --preserve=all fails there.
            cp -rL "${r}/boot/syslinux/vmlinuz" "${bak}/${slug}/boot-syslinux/" 2>/dev/null || true
            cp -rL "${r}/boot/syslinux/"initrd.* "${bak}/${slug}/boot-syslinux/" 2>/dev/null || true
            if [[ -f "${r}/boot/syslinux/vmlinuz" && ! -f "${bak}/${slug}/boot-syslinux/vmlinuz" ]]; then
                echo "ERR: could not back up ${r}/boot/syslinux/vmlinuz — refusing to upgrade without a rollback." >&2
                exit 1
            fi
        fi
        if [[ -d "${r}/EFI/BOOT" ]]; then
            mkdir -p "${bak}/${slug}/EFI-BOOT"
            cp -rL "${r}/EFI/BOOT/." "${bak}/${slug}/EFI-BOOT/" 2>/dev/null || true
        fi
    done

    # Rollback text is printed on success AND from the ERR trap, so an abort in
    # the middle of the swap never leaves the user without recovery instructions.
    _ub_rollback_hint() {
        local j=0 rr
        echo
        echo "ROLLBACK (restores the previous base and boot files):"
        echo "  rm -f ${BASE_MODULES_DIR}/000-*.xzm ${BASE_MODULES_DIR}/001-*.xzm ${BASE_MODULES_DIR}/002-*.xzm ${BASE_MODULES_DIR}/003-*.xzm"
        echo "  mv ${bak}/modules/*.xzm ${BASE_MODULES_DIR}/"
        for rr in "${boot_roots[@]}"; do
            echo "  cp -rL ${bak}/boot-${j}/boot-syslinux/. ${rr}/boot/syslinux/  2>/dev/null"
            echo "  cp -rL ${bak}/boot-${j}/EFI-BOOT/. ${rr}/EFI/BOOT/           2>/dev/null"
            j=$((j+1))
        done
        echo "  sync"
    }

    for f in "${BASE_MODULES_DIR}"/000-*.xzm "${BASE_MODULES_DIR}"/001-*.xzm \
             "${BASE_MODULES_DIR}"/002-*.xzm "${BASE_MODULES_DIR}"/003-*.xzm; do
        [[ -e "$f" ]] && mv "$f" "${bak}/modules/"
    done
    # From here on the install is mid-swap: any abort must print the rollback.
    trap '_ub_rollback_hint >&2' ERR

    # ---- install the new base + boot ------------------------------------------
    echo "Installing new base modules ..."
    cp -v "${iso_base}/"*.xzm "${BASE_MODULES_DIR}/"

    for r in "${boot_roots[@]}"; do
        if [[ -d "${r}/boot/syslinux" ]]; then
            echo "Installing new kernel + initrd -> ${r}/boot/syslinux ..."
            cp -rL "${_iso_mnt}/boot/syslinux/vmlinuz" "${r}/boot/syslinux/"
            cp -rL "${_iso_mnt}/boot/syslinux/"initrd.* "${r}/boot/syslinux/"
        fi
        if [[ -d "${_iso_mnt}/EFI/BOOT" && -d "${r}/EFI/BOOT" ]]; then
            echo "Refreshing EFI loader -> ${r}/EFI/BOOT ..."
            cp -rL "${_iso_mnt}/EFI/BOOT/." "${r}/EFI/BOOT/"
        fi
    done
    # NOTE: porteux.cfg is intentionally KEPT — it holds YOUR DEFAULT/changes/login
    # boot settings. New ISO cheatcodes (e.g. kvm.enable_virt_at_load=0) are not
    # merged; add them by hand if you need them.

    sync
    trap - ERR
    _ub_cleanup

    cat <<EOF

Base upgraded for variant '${variant}'. Kept: /porteux/changes (persistence),
/porteux/modules and /porteux/optional. Boot files refreshed on: ${boot_roots[*]}
Reboot to load the new base.
EOF
    echo
    echo "If the new base misbehaves (e.g. a stale overlay clashes with new libraries):"
    _ub_rollback_hint
    echo
    echo "Once the new release is confirmed good, reclaim space: rm -rf ${bak}"
}

if [[ "${MODE}" == "upgrade-base" ]]; then
    upgrade_base
    exit 0
fi

# =============================================================================
# OPTIONAL-module update (date-stamped assets in the release)
# =============================================================================
# Scan BOTH auto-loading extras (/porteux/modules) and parked ones
# (/porteux/optional): date-stamped assets can sit in either, and replacing a
# module in place keeps its load semantics unchanged.
declare -a SCAN_DIRS=()
if d="$(_find_modules_dir)"; then SCAN_DIRS+=("${d}"); fi
if d="$(_find_dir optional "" OPTIONAL_DIR)"; then SCAN_DIRS+=("${d}"); fi
if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
    cat >&2 <<'EOF'
ERR: could not locate /porteux/modules or /porteux/optional (no *.xzm found).
     On a booted PorteuX they live on the boot partition under /mnt/<device>.
     Override with: MODULES_DIR=/mnt/<dev>/porteux/modules porteux-update-modules
     Note: this mode updates OPTIONAL modules only. The base (000-003) lives in
     /porteux/base and moves only with --upgrade-base.
EOF
    exit 1
fi
MODULES_DIR="${SCAN_DIRS[0]}"

if [[ ${DO_DOWNLOAD} -eq 1 && $(id -u) -ne 0 ]]; then
    echo "ERR: --download needs root (writing to ${SCAN_DIRS[*]})" >&2; exit 1
fi

echo "Querying ${API} ..."
json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    --retry 5 --retry-delay 3 --retry-all-errors "${API}")
[[ -n "${json}" ]] || { echo "ERR: empty API response" >&2; exit 1; }

# Portable extraction: `grep -oP` is GNU-only and silently yields nothing on a
# BSD/busybox grep, which reads exactly like "the release has no assets".
_asset_urls() {   # $1 = json, $2 = suffix filter (e.g. .xzm)
    printf '%s' "$1" | tr ',' '\n' \
        | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | grep -E "\\${2}\$" || true
}
mapfile -t urls < <(_asset_urls "${json}" ".xzm")
[[ ${#urls[@]} -gt 0 ]] || { echo "ERR: no .xzm assets found in the latest release (API response unusable?)" >&2; exit 1; }

# Helper: strip "-current-YYYYMMDD.xzm" → return name prefix.
_prefix() { echo "$1" | sed -E 's/-current-[0-9]+\.xzm$//'; }
_date()   { local d; d="$(echo "$1" | sed -n 's/.*-\([0-9]\{8\}\)\.xzm$/\1/p')"; echo "${d:-0}"; }

shopt -s nullglob
declare -a updates=() candidates=()
for scan_dir in "${SCAN_DIRS[@]}"; do
    for f in "${scan_dir}"/*.xzm; do
        [[ -f "${f}" ]] && candidates+=("${f}")
    done
done
if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "No .xzm modules found in ${SCAN_DIRS[*]} — nothing to check."; exit 0
fi
for local_path in "${candidates[@]}"; do
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
    echo "All modules in ${SCAN_DIRS[*]} are up to date."
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
    new_path="$(dirname "${old_path}")/$(basename "${url}")"
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
