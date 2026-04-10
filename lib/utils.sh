#!/usr/bin/env bash
# utils.sh — Utility functions: try (interactive recovery), countdown, dependency checks
source "${LIB_DIR}/protection.sh"

# try — Execute a command with interactive recovery on failure
# Usage: try "description" command [args...]
try() {
    local desc="$1"
    shift

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would execute: $*"
        return 0
    fi

    while true; do
        einfo "Running: ${desc}"
        elog "Command: $*"

        local exit_code=0
        if [[ "${LIVE_OUTPUT:-0}" == "1" ]]; then
            # Show output on terminal AND log to file (pipeline, not process substitution)
            "$@" 2>&1 | tee -a "${LOG_FILE}" || exit_code=$?
        else
            "$@" >> "${LOG_FILE}" 2>&1 || exit_code=$?
        fi

        if [[ ${exit_code} -eq 0 ]]; then
            einfo "Success: ${desc}"
            return 0
        fi
        eerror "Failed (exit ${exit_code}): ${desc}"
        eerror "Command: $*"

        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            die "Non-interactive mode — aborting on failure: ${desc}"
        fi

        # Restore stderr for dialog UI if it was redirected (fd 4 saved by screen_progress)
        local _stderr_redirected=0
        if { true >&4; } 2>/dev/null; then
            exec 2>&4
            _stderr_redirected=1
        fi

        local choice

        if command -v "${DIALOG_CMD:-dialog}" &>/dev/null; then
            # Full dialog UI available
            choice=$(dialog_menu "Command Failed: ${desc}" \
                "retry"    "Retry the command" \
                "shell"    "Drop to a shell (type 'exit' to return)" \
                "continue" "Skip this step and continue" \
                "log"      "View last 50 lines of log" \
                "abort"    "Abort installation") || choice="abort"
        else
            # No dialog (e.g. inside chroot) — simple text menu
            echo "" >&2
            echo "=== FAILED: ${desc} ===" >&2
            echo "  (r)etry  | (s)hell  | (c)ontinue  | (a)bort" >&2
            local _reply=""
            read -r -p "Choice [r/s/c/a]: " _reply < /dev/tty || _reply="a"
            case "${_reply}" in
                r*) choice="retry" ;;
                s*) choice="shell" ;;
                c*) choice="continue" ;;
                *)  choice="abort" ;;
            esac
        fi

        case "${choice}" in
            retry)
                ewarn "Retrying: ${desc}"
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            shell)
                ewarn "Dropping to shell. Type 'exit' to return to installer."
                PS1="(porteux-installer rescue) \w \$ " bash --norc --noprofile || true
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            continue)
                ewarn "Skipping: ${desc} (user chose to continue)"
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                return 0
                ;;
            log)
                local _tmplog
                _tmplog=$(mktemp) && tail -50 "${LOG_FILE}" > "${_tmplog}" 2>/dev/null
                dialog_textbox "Log (last 50 lines)" "${_tmplog}" || true
                rm -f "${_tmplog}" 2>/dev/null
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            abort)
                die "Aborted by user after failure: ${desc}"
                ;;
        esac
    done
}

# countdown — Display a countdown timer
# Usage: countdown <seconds> <message>
countdown() {
    local seconds="${1:-${COUNTDOWN_DEFAULT}}"
    local msg="${2:-Continuing in}"

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        return 0
    fi

    local i
    for ((i = seconds; i > 0; i--)); do
        printf "\r%s %d seconds... " "${msg}" "${i}" >&2
        sleep 1
    done
    printf "\r%s\n" "$(printf '%-60s' '')" >&2
}

# check_dependencies — Verify required tools are available
check_dependencies() {
    local -a missing=()
    local dep

    local -a required_deps=(
        bash
        mkfs.ext4
        mkfs.vfat
        sfdisk
        mount
        umount
        blkid
        lsblk
        curl
        tar
        sha256sum
        chroot
    )

    for dep in "${required_deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    # dialog or whiptail
    if ! command -v dialog &>/dev/null && ! command -v whiptail &>/dev/null; then
        missing+=("dialog|whiptail")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        eerror "Missing required dependencies:"
        local m
        for m in "${missing[@]}"; do
            eerror "  - ${m}"
        done
        return 1
    fi

    einfo "All dependencies satisfied"
    return 0
}

# is_efi — Check if booted in EFI mode
is_efi() {
    [[ -d /sys/firmware/efi ]]
}

# is_root — Check if running as root
is_root() {
    [[ "$(id -u)" -eq 0 ]]
}

# ensure_dns — Add fallback nameserver if DNS resolution fails
ensure_dns() {
    if ! ping -c 1 -W 3 voidlinux.org &>/dev/null && ! ping -c 1 -W 3 google.com &>/dev/null; then
        # Ping failed — check if it's a DNS issue (raw IP works?)
        if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
            ewarn "DNS resolution failed, adding fallback nameserver 8.8.8.8"
            if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
                echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            fi
        fi
    fi
}

# has_network — Check basic network connectivity
has_network() {
    ping -c 1 -W 3 voidlinux.org &>/dev/null || \
    ping -c 1 -W 3 google.com &>/dev/null
}

# checkpoint_set — Mark a phase as completed
checkpoint_set() {
    local name="$1"
    mkdir -p "${CHECKPOINT_DIR}"
    touch "${CHECKPOINT_DIR}/${name}"
    einfo "Checkpoint set: ${name}"
}

# checkpoint_reached — Check if a phase is already completed
checkpoint_reached() {
    local name="$1"
    [[ -f "${CHECKPOINT_DIR}/${name}" ]]
}

# checkpoint_clear — Remove all checkpoints
checkpoint_clear() {
    rm -rf "${CHECKPOINT_DIR}"
    einfo "All checkpoints cleared"
}

# checkpoint_validate — Check if a checkpoint's artifact actually exists
# Returns 0 if checkpoint is valid, 1 if it should be re-run
checkpoint_validate() {
    local name="$1"
    case "${name}" in
        preflight)
            return 1 ;;  # always re-run (fast)
        disks)
            [[ -b "${ROOT_PARTITION:-}" ]] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null ;;
        rootfs_extract)
            [[ -f "${MOUNTPOINT}/usr/bin/xbps-install" ]] ;;
        xbps_preconfig)
            [[ -d "${MOUNTPOINT}/etc/xbps.d/" ]] ;;
        rootfs_download|rootfs_verify)
            ls "${MOUNTPOINT}"/porteux-x86_64-ROOTFS-*.tar.xz &>/dev/null 2>&1 ;;
        chroot)
            [[ -f "${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}/finalize" ]] ;;
        kernel)
            ls "${MOUNTPOINT}/boot/vmlinuz-"* &>/dev/null 2>&1 || ls /boot/vmlinuz-* &>/dev/null 2>&1 ;;
        *)
            return 0 ;;  # trust checkpoint for the rest
    esac
}

# checkpoint_migrate_to_target — Move checkpoints from /tmp to target disk
# Called after mounting filesystems so checkpoints survive reformat
checkpoint_migrate_to_target() {
    local target_dir="${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}"
    [[ "${CHECKPOINT_DIR}" == "${target_dir}" ]] && return 0
    mkdir -p "${target_dir}"
    [[ -d "${CHECKPOINT_DIR}" ]] && cp -a "${CHECKPOINT_DIR}/"* "${target_dir}/" 2>/dev/null || true
    rm -rf "${CHECKPOINT_DIR}"
    CHECKPOINT_DIR="${target_dir}"
    export CHECKPOINT_DIR
}

# --- Resume from disk ---

# RESUME_FOUND_PARTITION — partition where resume data was found
RESUME_FOUND_PARTITION=""
# RESUME_FOUND_FSTYPE — filesystem type of that partition
RESUME_FOUND_FSTYPE=""
# RESUME_HAS_CONFIG — whether config file was found alongside checkpoints
RESUME_HAS_CONFIG=0

# _scan_partition_for_resume — Check a single partition for resume data
# Usage: _scan_partition_for_resume /dev/sdX2 ext4
# Sets: _SCAN_HAS_CHECKPOINTS, _SCAN_HAS_CONFIG, _SCAN_MOUNTPOINT
_scan_partition_for_resume() {
    local part="$1"
    local fstype="$2"
    _SCAN_HAS_CHECKPOINTS=0
    _SCAN_HAS_CONFIG=0
    _SCAN_MOUNTPOINT=""

    # For testing: use fake directory instead of real mount
    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        local fake_mp="${_RESUME_TEST_DIR}/mnt/${part##*/}"
        if [[ -d "${fake_mp}${CHECKPOINT_DIR_SUFFIX}" ]] && ls "${fake_mp}${CHECKPOINT_DIR_SUFFIX}/"* &>/dev/null 2>&1; then
            _SCAN_HAS_CHECKPOINTS=1
            _SCAN_MOUNTPOINT="${fake_mp}"
        fi
        if [[ -f "${fake_mp}/tmp/porteux-installer.conf" ]]; then
            _SCAN_HAS_CONFIG=1
        fi
        return 0
    fi

    # Skip if already mounted somewhere
    if findmnt -rn -S "${part}" &>/dev/null; then
        local existing_mp
        existing_mp=$(findmnt -rn -o TARGET -S "${part}" | head -1) || true
        if [[ -n "${existing_mp}" ]]; then
            # Check in-place without mounting
            if [[ -d "${existing_mp}${CHECKPOINT_DIR_SUFFIX}" ]] && ls "${existing_mp}${CHECKPOINT_DIR_SUFFIX}/"* &>/dev/null 2>&1; then
                _SCAN_HAS_CHECKPOINTS=1
                _SCAN_MOUNTPOINT="${existing_mp}"
            fi
            if [[ -f "${existing_mp}/tmp/porteux-installer.conf" ]]; then
                _SCAN_HAS_CONFIG=1
            fi
            return 0
        fi
    fi

    local mp
    mp=$(mktemp -d "${TMPDIR:-/tmp}/porteux-resume-scan.XXXXXX")

    local mounted=0
    if mount -o ro "${part}" "${mp}" 2>/dev/null; then
        mounted=1
    elif [[ "${fstype}" == "btrfs" ]]; then
        # Btrfs: try mounting default subvolume @
        if mount -o ro,subvol=@ "${part}" "${mp}" 2>/dev/null; then
            mounted=1
        fi
    fi

    if [[ ${mounted} -eq 1 ]]; then
        if [[ -d "${mp}${CHECKPOINT_DIR_SUFFIX}" ]] && ls "${mp}${CHECKPOINT_DIR_SUFFIX}/"* &>/dev/null 2>&1; then
            _SCAN_HAS_CHECKPOINTS=1
            _SCAN_MOUNTPOINT="${mp}"
        fi
        if [[ -f "${mp}/tmp/porteux-installer.conf" ]]; then
            _SCAN_HAS_CONFIG=1
        fi
        umount "${mp}" 2>/dev/null || true
    fi

    rmdir "${mp}" 2>/dev/null || true
    return 0
}

# _recover_resume_data — Copy checkpoints and config from partition
# Usage: _recover_resume_data /dev/sdX2 ext4
_recover_resume_data() {
    local part="$1"
    local fstype="$2"

    # For testing: use fake directory instead of real mount
    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        local fake_mp="${_RESUME_TEST_DIR}/mnt/${part##*/}"
        mkdir -p "${CHECKPOINT_DIR}"
        cp -a "${fake_mp}${CHECKPOINT_DIR_SUFFIX}/"* "${CHECKPOINT_DIR}/" 2>/dev/null || true
        if [[ -f "${fake_mp}/tmp/porteux-installer.conf" ]]; then
            (umask 077; cp "${fake_mp}/tmp/porteux-installer.conf" "${CONFIG_FILE}")
        fi
        return 0
    fi

    local mp
    mp=$(mktemp -d "${TMPDIR:-/tmp}/porteux-resume-recover.XXXXXX")
    local mounted=0

    if findmnt -rn -S "${part}" &>/dev/null; then
        local existing_mp
        existing_mp=$(findmnt -rn -o TARGET -S "${part}" | head -1) || true
        if [[ -n "${existing_mp}" ]]; then
            mp="${existing_mp}"
            mounted=2  # already mounted, don't unmount
        fi
    fi

    if [[ ${mounted} -eq 0 ]]; then
        if mount -o ro "${part}" "${mp}" 2>/dev/null; then
            mounted=1
        elif [[ "${fstype}" == "btrfs" ]]; then
            if mount -o ro,subvol=@ "${part}" "${mp}" 2>/dev/null; then
                mounted=1
            fi
        fi
    fi

    if [[ ${mounted} -gt 0 ]]; then
        mkdir -p "${CHECKPOINT_DIR}"
        cp -a "${mp}${CHECKPOINT_DIR_SUFFIX}/"* "${CHECKPOINT_DIR}/" 2>/dev/null || true
        einfo "Recovered checkpoints from ${part}"

        if [[ -f "${mp}/tmp/porteux-installer.conf" ]]; then
            (umask 077; cp "${mp}/tmp/porteux-installer.conf" "${CONFIG_FILE}")
            einfo "Recovered config from ${part}"
        fi

        [[ ${mounted} -eq 1 ]] && umount "${mp}" 2>/dev/null || true
    fi

    [[ ${mounted} -ne 2 ]] && rmdir "${mp}" 2>/dev/null || true
    return 0
}

# try_resume_from_disk — Scan all partitions for resume data (checkpoints + config)
# Returns: 0 = config + checkpoints found, 1 = only checkpoints, 2 = nothing found
# Sets: RESUME_FOUND_PARTITION, RESUME_HAS_CONFIG
try_resume_from_disk() {
    RESUME_FOUND_PARTITION=""
    RESUME_HAS_CONFIG=0

    einfo "Scanning partitions for previous installation data..."

    local found_part="" found_fstype="" found_config=0

    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        # Testing mode: read fake partition list
        local part fstype
        while IFS=' ' read -r part fstype; do
            [[ -z "${part}" || -z "${fstype}" ]] && continue
            case "${fstype}" in
                ext4|ext3|xfs|btrfs) ;;
                *) continue ;;
            esac
            _scan_partition_for_resume "${part}" "${fstype}"
            if [[ ${_SCAN_HAS_CHECKPOINTS} -eq 1 ]]; then
                found_part="${part}"
                found_fstype="${fstype}"
                found_config=${_SCAN_HAS_CONFIG}
                break
            fi
        done < "${_RESUME_TEST_DIR}/partitions.list"
    else
        local part fstype
        while IFS=' ' read -r part fstype; do
            [[ -z "${part}" || -z "${fstype}" ]] && continue
            case "${fstype}" in
                ext4|ext3|xfs|btrfs) ;;
                *) continue ;;
            esac
            _scan_partition_for_resume "${part}" "${fstype}"
            if [[ ${_SCAN_HAS_CHECKPOINTS} -eq 1 ]]; then
                found_part="${part}"
                found_fstype="${fstype}"
                found_config=${_SCAN_HAS_CONFIG}
                break
            fi
        done < <(lsblk -lno PATH,FSTYPE 2>/dev/null || true)
    fi

    if [[ -z "${found_part}" ]]; then
        ewarn "No previous installation data found on any partition"
        return 2
    fi

    einfo "Found resume data on ${found_part} (${found_fstype})"
    RESUME_FOUND_PARTITION="${found_part}"
    RESUME_FOUND_FSTYPE="${found_fstype}"
    export RESUME_FOUND_PARTITION RESUME_FOUND_FSTYPE

    _recover_resume_data "${found_part}" "${found_fstype}"

    if [[ ${found_config} -eq 1 ]]; then
        RESUME_HAS_CONFIG=1
        export RESUME_HAS_CONFIG
        einfo "Resume: config + checkpoints recovered from ${found_part}"
        return 0
    else
        RESUME_HAS_CONFIG=0
        export RESUME_HAS_CONFIG
        ewarn "Resume: checkpoints recovered but no config found on ${found_part}"
        return 1
    fi
}

# --- Config inference from installed partition ---

# _partition_to_disk — Strip partition suffix to get disk device
# /dev/sda2 -> /dev/sda, /dev/nvme0n1p3 -> /dev/nvme0n1, /dev/mmcblk0p1 -> /dev/mmcblk0
_partition_to_disk() {
    local part="$1"
    if [[ "${part}" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${part}" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${part}" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "${part}"
    fi
}

# _resolve_uuid — Resolve UUID to device path (test-aware)
_resolve_uuid() {
    local uuid="$1"
    if [[ -n "${_INFER_UUID_MAP:-}" && -f "${_INFER_UUID_MAP}" ]]; then
        sed -n "s/^${uuid} //p" "${_INFER_UUID_MAP}" || true
    else
        blkid -U "${uuid}" 2>/dev/null || true
    fi
}

# _infer_from_fstab — Parse /etc/fstab for partition and filesystem info
_infer_from_fstab() {
    local mp="$1"
    local fstab="${mp}/etc/fstab"
    [[ -f "${fstab}" ]] || return 0

    local line dev mpoint fstype opts rest
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue

        read -r dev mpoint fstype opts rest <<< "${line}" || true
        [[ -z "${dev}" || -z "${mpoint}" ]] && continue

        # Resolve UUID= to device path
        if [[ "${dev}" =~ ^UUID=(.+)$ ]]; then
            local uuid="${BASH_REMATCH[1]}"
            local resolved
            resolved=$(_resolve_uuid "${uuid}")
            [[ -n "${resolved}" ]] && dev="${resolved}"
        fi

        case "${mpoint}" in
            /)
                if [[ -n "${dev}" && ! "${dev}" =~ ^UUID= ]]; then
                    ROOT_PARTITION="${dev}"
                    export ROOT_PARTITION
                fi
                case "${fstype}" in
                    ext4|xfs)
                        FILESYSTEM="${fstype}"
                        export FILESYSTEM
                        ;;
                    btrfs)
                        FILESYSTEM="btrfs"
                        export FILESYSTEM
                        # Collect btrfs subvolume mappings from fstab
                        if [[ "${opts}" =~ subvol=([^,]+) ]]; then
                            local _subvol="${BASH_REMATCH[1]}"
                            local _mpt="${mpoint}"
                            if [[ -z "${BTRFS_SUBVOLUMES:-}" ]]; then
                                BTRFS_SUBVOLUMES="${_subvol}:${_mpt}"
                            else
                                BTRFS_SUBVOLUMES="${BTRFS_SUBVOLUMES}:${_subvol}:${_mpt}"
                            fi
                            export BTRFS_SUBVOLUMES
                        fi
                        ;;
                esac
                ;;
            /boot/efi|/boot|/efi)
                if [[ "${fstype}" == "vfat" && -n "${dev}" && ! "${dev}" =~ ^UUID= ]]; then
                    ESP_PARTITION="${dev}"
                    export ESP_PARTITION
                fi
                ;;
        esac

        # Collect btrfs subvolume mappings for non-root mount points
        if [[ "${fstype}" == "btrfs" && "${mpoint}" != "/" && "${opts}" =~ subvol=([^,]+) ]]; then
            local _subvol="${BASH_REMATCH[1]}"
            if [[ -n "${BTRFS_SUBVOLUMES:-}" ]]; then
                BTRFS_SUBVOLUMES="${BTRFS_SUBVOLUMES}:${_subvol}:${mpoint}"
                export BTRFS_SUBVOLUMES
            fi
        fi

        # Swap detection by fstype
        if [[ "${fstype}" == "swap" && -n "${dev}" && ! "${dev}" =~ ^UUID= ]]; then
            SWAP_PARTITION="${dev}"
            SWAP_TYPE="partition"
            export SWAP_PARTITION SWAP_TYPE
        fi
    done < "${fstab}"
}

# _infer_from_xbps_conf — Parse /etc/xbps.d/*.conf for mirror URL and nonfree repo
_infer_from_xbps_conf() {
    local mp="$1"
    local confdir="${mp}/etc/xbps.d"
    [[ -d "${confdir}" ]] || return 0

    local f line
    for f in "${confdir}"/*.conf; do
        [[ -f "${f}" ]] || continue
        while IFS= read -r line; do
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue

            # repository= lines contain mirror URLs
            if [[ "${line}" =~ ^repository= ]]; then
                local url="${line#repository=}"
                # Check for nonfree repo
                if [[ "${url}" == *"/nonfree"* ]]; then
                    ENABLE_NONFREE="yes"
                    export ENABLE_NONFREE
                fi
                # Extract base mirror URL (strip /current, /current/nonfree etc.)
                if [[ -z "${MIRROR_URL:-}" && "${url}" != *"/nonfree"* ]]; then
                    # e.g. https://repo-default.voidlinux.org/current -> https://repo-default.voidlinux.org
                    local base_url="${url%/current*}"
                    if [[ -n "${base_url}" ]]; then
                        MIRROR_URL="${base_url}"
                        export MIRROR_URL
                    fi
                fi
            fi
        done < "${f}"
    done
}

# _infer_from_rc_conf — Parse /etc/rc.conf for HOSTNAME, KEYMAP, TIMEZONE
_infer_from_rc_conf() {
    local mp="$1"
    local rcconf="${mp}/etc/rc.conf"
    [[ -f "${rcconf}" ]] || return 0

    local line varname value
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue
        [[ "${line}" == *=* ]] || continue

        varname="${line%%=*}"
        value="${line#*=}"
        # Strip surrounding quotes
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        case "${varname}" in
            HOSTNAME)
                if [[ -n "${value}" && -z "${HOSTNAME:-}" ]]; then
                    HOSTNAME="${value}"
                    export HOSTNAME
                fi
                ;;
            KEYMAP)
                if [[ -n "${value}" && -z "${KEYMAP:-}" ]]; then
                    KEYMAP="${value}"
                    export KEYMAP
                fi
                ;;
            TIMEZONE)
                if [[ -n "${value}" && -z "${TIMEZONE:-}" ]]; then
                    TIMEZONE="${value}"
                    export TIMEZONE
                fi
                ;;
        esac
    done < "${rcconf}"
}

# _infer_from_hostname — Read hostname from system config
_infer_from_hostname() {
    local mp="$1"

    # Already set (e.g. from rc.conf)?
    [[ -n "${HOSTNAME:-}" ]] && return 0

    # /etc/hostname (standard)
    if [[ -f "${mp}/etc/hostname" ]]; then
        local h
        h=$(sed -n '/^[[:space:]]*$/d; /^[[:space:]]*#/d; p; q' "${mp}/etc/hostname") || true
        h="${h%%[[:space:]]*}"
        if [[ -n "${h}" ]]; then
            HOSTNAME="${h}"
            export HOSTNAME
            return 0
        fi
    fi
}

# _infer_from_timezone — Read timezone
_infer_from_timezone() {
    local mp="$1"

    # Already set (e.g. from rc.conf)?
    [[ -n "${TIMEZONE:-}" ]] && return 0

    if [[ -f "${mp}/etc/timezone" ]]; then
        local tz
        tz=$(sed -n '/^[[:space:]]*$/d; /^[[:space:]]*#/d; p; q' "${mp}/etc/timezone") || true
        tz="${tz%%[[:space:]]*}"
        if [[ -n "${tz}" ]]; then
            TIMEZONE="${tz}"
            export TIMEZONE
            return 0
        fi
    fi

    # Fallback: readlink /etc/localtime
    if [[ -L "${mp}/etc/localtime" ]]; then
        local target
        target=$(readlink "${mp}/etc/localtime" 2>/dev/null) || true
        if [[ "${target}" == *zoneinfo/* ]]; then
            TIMEZONE="${target#*zoneinfo/}"
            export TIMEZONE
            return 0
        fi
    fi
}

# _infer_from_locale — Read locale from /etc/default/libc-locales (PorteuX glibc)
_infer_from_locale() {
    local mp="$1"
    local localefile="${mp}/etc/default/libc-locales"
    [[ -f "${localefile}" ]] || return 0

    local line
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue
        # First uncommented line, e.g. "pl_PL.UTF-8 UTF-8"
        local loc="${line%% *}"
        if [[ -n "${loc}" ]]; then
            LOCALE="${loc}"
            export LOCALE
            return 0
        fi
    done < "${localefile}"
}

# _infer_from_keymap — Read keymap from /etc/rc.conf or /etc/vconsole.conf
_infer_from_keymap() {
    local mp="$1"

    # Already set (e.g. from rc.conf)?
    [[ -n "${KEYMAP:-}" ]] && return 0

    # Fallback: /etc/vconsole.conf (systemd-compatible)
    if [[ -f "${mp}/etc/vconsole.conf" ]]; then
        local km
        km=$(sed -n "s/^KEYMAP=[\"']*\([^\"']*\).*/\1/p; T; q" "${mp}/etc/vconsole.conf") || true
        if [[ -n "${km}" ]]; then
            KEYMAP="${km}"
            export KEYMAP
            return 0
        fi
    fi
}

# _infer_kernel_type — Detect kernel type from installed xbps packages
_infer_kernel_type() {
    local mp="$1"
    local pkgdb="${mp}/var/db/xbps"
    [[ -d "${pkgdb}" ]] || return 0

    # Check for linux-lts package (e.g. .linux-lts-6.1.XXX_1.x86_64.plist)
    if ls "${pkgdb}"/.linux-lts-* &>/dev/null 2>&1; then
        KERNEL_TYPE="lts"
        export KERNEL_TYPE
        return 0
    fi

    # Check for Surface-patched kernel (vmlinuz with "surface" in name)
    local vmlinuz
    for vmlinuz in "${mp}"/boot/vmlinuz-*surface*; do
        if [[ -f "${vmlinuz}" ]]; then
            KERNEL_TYPE="surface-patched"
            export KERNEL_TYPE
            return 0
        fi
    done

    # Check for default linux package (e.g. .linux-6.x.y_1.x86_64.plist)
    # PorteuX's mainline kernel package is "linux" (no "mainline" suffix)
    if ls "${pkgdb}"/.linux-[0-9]* &>/dev/null 2>&1; then
        KERNEL_TYPE="mainline"
        export KERNEL_TYPE
        return 0
    fi
}

# _infer_swap_type — Detect swap type if fstab didn't have swap partition
_infer_swap_type() {
    local mp="$1"

    # Already set from fstab?
    [[ -n "${SWAP_TYPE:-}" ]] && return 0

    # zramen runit service (PorteuX zram)
    if [[ -d "${mp}/etc/sv/zramen" ]]; then
        SWAP_TYPE="zram"
        export SWAP_TYPE
        return 0
    fi

    # zram service symlink in runsvdir
    if [[ -L "${mp}/var/service/zramen" ]] || [[ -L "${mp}/etc/runit/runsvdir/default/zramen" ]]; then
        SWAP_TYPE="zram"
        export SWAP_TYPE
        return 0
    fi

    # swap file
    if [[ -f "${mp}/var/swapfile" ]] || [[ -f "${mp}/swapfile" ]]; then
        SWAP_TYPE="file"
        export SWAP_TYPE
        return 0
    fi

    SWAP_TYPE="none"
    export SWAP_TYPE
}

# _infer_partition_scheme — Determine if auto or dual-boot
_infer_partition_scheme() {
    local esp_disk="" root_disk=""

    if [[ -n "${ESP_PARTITION:-}" ]]; then
        esp_disk=$(_partition_to_disk "${ESP_PARTITION}")
    fi
    if [[ -n "${TARGET_DISK:-}" ]]; then
        root_disk="${TARGET_DISK}"
    fi

    if [[ -n "${esp_disk}" && -n "${root_disk}" && "${esp_disk}" != "${root_disk}" ]]; then
        PARTITION_SCHEME="dual-boot"
        ESP_REUSE="yes"
        export PARTITION_SCHEME ESP_REUSE
    else
        PARTITION_SCHEME="auto"
        export PARTITION_SCHEME
    fi
}

# _infer_sufficient_config — Check if inferred config has minimum required vars
# PorteuX always uses runit — no INIT_SYSTEM requirement
_infer_sufficient_config() {
    [[ -n "${ROOT_PARTITION:-}" ]] || return 1
    [[ -n "${ESP_PARTITION:-}" ]] || return 1
    [[ -n "${FILESYSTEM:-}" ]] || return 1
    [[ -n "${TARGET_DISK:-}" ]] || return 1
    return 0
}

# _infer_surface_from_installed — Detect Surface tools from installed system
_infer_surface_from_installed() {
    local mp="$1"

    # Check for iptsd binary or runit service
    if [[ -x "${mp}/usr/bin/iptsd" ]] || [[ -d "${mp}/etc/sv/iptsd" ]]; then
        ENABLE_IPTSD="yes"
        export ENABLE_IPTSD
    fi
}

# _infer_secureboot_from_installed — Detect Secure Boot setup from installed system
_infer_secureboot_from_installed() {
    local mp="$1"

    # Check for MOK keys
    if [[ -f "${mp}/root/secureboot/MOK.priv" ]]; then
        ENABLE_SECUREBOOT="yes"
        export ENABLE_SECUREBOOT
        return 0
    fi

    # Check for shim on ESP
    if [[ -f "${mp}/boot/efi/EFI/PorteuX/shimx64.efi" ]]; then
        ENABLE_SECUREBOOT="yes"
        export ENABLE_SECUREBOOT
        return 0
    fi

    # Check for kernel signing hook
    if [[ -f "${mp}/etc/kernel.d/post-install/20-secureboot-sign" ]]; then
        ENABLE_SECUREBOOT="yes"
        export ENABLE_SECUREBOOT
        return 0
    fi
}

# infer_config_from_partition — Read config from an installed system's files
# Usage: infer_config_from_partition /dev/sdX2 ext4
# Returns: 0 = sufficient config inferred, 1 = insufficient
infer_config_from_partition() {
    local part="$1"
    local fstype="$2"
    local mp="" need_unmount=0

    # Set direct values from arguments
    ROOT_PARTITION="${part}"
    FILESYSTEM="${fstype}"
    TARGET_DISK=$(_partition_to_disk "${part}")
    export ROOT_PARTITION FILESYSTEM TARGET_DISK

    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        mp="${_RESUME_TEST_DIR}/mnt/${part##*/}"
    else
        # Try to find/mount the partition
        if findmnt -rn -S "${part}" &>/dev/null; then
            mp=$(findmnt -rn -o TARGET -S "${part}" | head -1) || true
        fi
        if [[ -z "${mp}" ]]; then
            mp=$(mktemp -d "${TMPDIR:-/tmp}/porteux-infer.XXXXXX")
            if mount -o ro "${part}" "${mp}" 2>/dev/null; then
                need_unmount=1
            elif [[ "${fstype}" == "btrfs" ]]; then
                if mount -o ro,subvol=@ "${part}" "${mp}" 2>/dev/null; then
                    need_unmount=1
                fi
            fi
        fi
    fi

    # Run all inference helpers (each is defensive — missing file = skip)
    _infer_from_fstab "${mp}"
    _infer_from_xbps_conf "${mp}"
    _infer_from_rc_conf "${mp}"
    _infer_from_hostname "${mp}"
    _infer_from_timezone "${mp}"
    _infer_from_locale "${mp}"
    _infer_from_keymap "${mp}"
    _infer_kernel_type "${mp}"
    _infer_swap_type "${mp}"
    _infer_surface_from_installed "${mp}"
    _infer_secureboot_from_installed "${mp}"
    _infer_partition_scheme

    # Cleanup
    if [[ ${need_unmount} -eq 1 ]]; then
        umount "${mp}" 2>/dev/null || true
        rmdir "${mp}" 2>/dev/null || true
    elif [[ -z "${_RESUME_TEST_DIR:-}" && -d "${mp}" ]]; then
        rmdir "${mp}" 2>/dev/null || true
    fi

    if _infer_sufficient_config; then
        einfo "Config inference: sufficient configuration inferred from ${part}"
        return 0
    else
        ewarn "Config inference: insufficient data from ${part}"
        return 1
    fi
}

# bytes_to_human — Convert bytes to human readable
bytes_to_human() {
    local bytes="$1"
    if ((bytes >= 1073741824)); then
        printf "%.1f GiB" "$(echo "scale=1; ${bytes}/1073741824" | bc)"
    elif ((bytes >= 1048576)); then
        printf "%.1f MiB" "$(echo "scale=1; ${bytes}/1048576" | bc)"
    elif ((bytes >= 1024)); then
        printf "%.1f KiB" "$(echo "scale=1; ${bytes}/1024" | bc)"
    else
        printf "%d B" "${bytes}"
    fi
}

# get_cpu_count — Number of CPUs
get_cpu_count() {
    nproc 2>/dev/null || echo 4
}

# generate_password_hash — Create SHA-512 password hash
generate_password_hash() {
    local password="$1"
    openssl passwd -6 -stdin <<< "${password}" 2>/dev/null || \
    VOID_PW="${password}" python3 -c "import hashlib, os, base64; pw=os.environ['VOID_PW'].encode(); salt=os.urandom(16); h=hashlib.sha512(salt+pw).digest(); print('\$6\$'+base64.b64encode(salt).decode()[:16]+'\$'+base64.b64encode(h).decode()[:86])" 2>/dev/null
}
