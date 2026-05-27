#!/usr/bin/env bash
# system.sh — System configuration for PorteuX
# PorteuX is Slackware-based; configuration goes into /etc/ within changes overlay
source "${LIB_DIR}/protection.sh"

# system_configure — Apply system configuration to the target
# When persistence is enabled, changes go to the changes directory (AUFS overlay)
# When persistence is disabled, changes go directly to the base system
system_configure() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    einfo "Configuring system..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would configure system"
        return 0
    fi

    # Determine where to write configuration
    # If persistence is enabled, write to changes overlay so config survives reboots
    local config_root="${target}"
    if [[ "${PERSISTENCE_MODE:-changes}" == "changes" ]]; then
        config_root="${target}/${PORTEUX_CHANGES_DIR}"
        mkdir -p "${config_root}/etc"
    fi

    system_set_hostname "${config_root}"
    system_set_timezone "${config_root}"
    system_set_locale "${config_root}"
    system_set_keymap "${config_root}"
    system_set_term_fallback "${config_root}"

    einfo "System configuration complete"
}

# system_set_term_fallback — Install a profile.d hook that maps unknown TERMs
# to a known-good one (xterm-256color). Without this, SSHing in from modern
# terminals like Ghostty/Kitty/WezTerm — whose terminfo entries aren't shipped
# in PorteuX — makes less/man/loginctl fail with "unknown terminal type".
system_set_term_fallback() {
    local root="$1"
    mkdir -p "${root}/etc/profile.d"
    cat > "${root}/etc/profile.d/zz-porteux-term-fallback.sh" <<'TERMSH'
# PorteuX installer: fall back to a known TERM when the client sent one we
# don't have terminfo for (Ghostty/Kitty/WezTerm/... over SSH). Interactive
# shells only — never touch TERM in scripts.

case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
[ -n "${TERM:-}" ] || return 0 2>/dev/null || exit 0

_porteux_term_known() {
    if command -v infocmp >/dev/null 2>&1; then
        infocmp "$1" >/dev/null 2>&1
    elif command -v tput >/dev/null 2>&1; then
        tput -T "$1" longname >/dev/null 2>&1
    else
        return 0
    fi
}

if ! _porteux_term_known "${TERM}"; then
    _orig="${TERM}"
    for _fb in xterm-256color xterm vt100; do
        if _porteux_term_known "${_fb}"; then
            export TERM="${_fb}"
            [ -t 2 ] && printf '[porteux] TERM=%s has no terminfo entry; using %s\n' "${_orig}" "${_fb}" >&2
            break
        fi
    done
    unset _orig _fb
fi
unset -f _porteux_term_known
TERMSH
    chmod +x "${root}/etc/profile.d/zz-porteux-term-fallback.sh"
    einfo "TERM fallback hook installed (handles SSH from ghostty/kitty/wezterm)"
}

# system_set_hostname — Set system hostname
system_set_hostname() {
    local root="$1"
    local hostname="${HOSTNAME:-porteux}"

    einfo "Setting hostname: ${hostname}"

    mkdir -p "${root}/etc"

    # /etc/HOSTNAME (Slackware convention)
    echo "${hostname}" > "${root}/etc/HOSTNAME"

    # /etc/hostname (standard)
    echo "${hostname}" > "${root}/etc/hostname"

    # /etc/hosts
    cat > "${root}/etc/hosts" <<EOF
127.0.0.1       localhost
127.0.1.1       ${hostname}
::1             localhost ip6-localhost ip6-loopback
EOF

    einfo "Hostname set to ${hostname}"
}

# system_set_timezone — Set timezone
system_set_timezone() {
    local root="$1"
    local tz="${TIMEZONE:-UTC}"

    einfo "Setting timezone: ${tz}"

    mkdir -p "${root}/etc"

    # Slackware uses /etc/localtime symlink
    if [[ -f "${root}/usr/share/zoneinfo/${tz}" ]]; then
        ln -sf "/usr/share/zoneinfo/${tz}" "${root}/etc/localtime"
    elif [[ -f "/usr/share/zoneinfo/${tz}" ]]; then
        # Copy from host if target doesn't have zoneinfo yet
        cp "/usr/share/zoneinfo/${tz}" "${root}/etc/localtime"
    fi

    # Also write to /etc/timezone for compatibility
    echo "${tz}" > "${root}/etc/timezone"

    # Slackware timeconfig
    mkdir -p "${root}/etc/localtime-copied-from"
    echo "${tz}" > "${root}/etc/localtime-copied-from/.tz"

    einfo "Timezone set to ${tz}"
}

# system_set_locale — Set system locale
system_set_locale() {
    local root="$1"
    local locale="${LOCALE:-en_US.UTF-8}"

    einfo "Setting locale: ${locale}"

    mkdir -p "${root}/etc/profile.d"

    # Slackware uses /etc/profile.d/lang.sh for locale
    cat > "${root}/etc/profile.d/lang.sh" <<EOF
#!/bin/sh
export LANG=${locale}
export LC_ALL=${locale}
EOF
    chmod +x "${root}/etc/profile.d/lang.sh"

    # Also create lang.csh for C shell users
    cat > "${root}/etc/profile.d/lang.csh" <<EOF
#!/bin/csh
setenv LANG ${locale}
setenv LC_ALL ${locale}
EOF
    chmod +x "${root}/etc/profile.d/lang.csh"

    einfo "Locale set to ${locale}"
}

# system_set_keymap — Set console keymap
system_set_keymap() {
    local root="$1"
    local keymap="${KEYMAP:-us}"

    einfo "Setting keymap: ${keymap}"

    mkdir -p "${root}/etc/rc.d"

    # Pass the keymap by NAME and let loadkeys resolve it from the keymaps tree.
    # Hardcoding i386/qwerty/<name>.map.gz breaks every non-qwerty layout
    # (azerty/qwertz/dvorak, jp106, ...). 'loadkeys pl' / 'loadkeys jp106'
    # searches all subdirs, so it works for the layouts this installer offers.
    cat > "${root}/etc/rc.d/rc.keymap" <<EOF
#!/bin/sh
# Load the keyboard map. Available maps: /usr/share/kbd/keymaps
if [ -x /usr/bin/loadkeys ]; then
    /usr/bin/loadkeys ${keymap}
fi
EOF
    chmod +x "${root}/etc/rc.d/rc.keymap" 2>/dev/null || true

    # vconsole.conf for compatibility
    echo "KEYMAP=${keymap}" > "${root}/etc/vconsole.conf"

    einfo "Keymap set to ${keymap}"
}

# system_create_users — Create user accounts
# PorteuX default credentials: guest/guest, root/toor
# We override these with user-specified values
system_create_users() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    einfo "Configuring user accounts..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would create users"
        return 0
    fi

    # Determine config root (for persistence)
    local config_root="${target}"
    if [[ "${PERSISTENCE_MODE:-changes}" == "changes" ]]; then
        config_root="${target}/${PORTEUX_CHANGES_DIR}"
    fi

    # Create a script that will run on first boot to set up users
    # This is needed because PorteuX is a live system — /etc/passwd is in a squashfs module
    # Changes to users need to go through the changes overlay
    local firstboot_dir="${config_root}/etc/rc.d"
    mkdir -p "${firstboot_dir}"

    local root_hash="${ROOT_PASSWORD_HASH:-}"
    local user_name="${USERNAME:-user}"
    local user_hash="${USER_PASSWORD_HASH:-}"
    local user_groups="${USER_GROUPS:-wheel,audio,video,input,storage,network}"

    cat > "${firstboot_dir}/rc.porteux-setup" <<'SETUPEOF'
#!/bin/sh
# PorteuX first-boot setup (created by installer)
# This script runs once to configure users

# Marker is INSTALLER-specific (not the bare ".porteux-setup-done" which
# PorteuX itself ships in its ISO/squashfs — that name collides, making the
# script see "already done" on first boot and skip user creation).
MARKER="/etc/.porteux-installer-firstboot-done"
if [ -f "$MARKER" ]; then
    exit 0
fi

SETUPEOF

    # Set root password
    if [[ -n "${root_hash}" ]]; then
        cat >> "${firstboot_dir}/rc.porteux-setup" <<SETUPEOF
# Set root password
echo 'root:${root_hash}' | chpasswd -e 2>/dev/null

SETUPEOF
    fi

    # Create user
    if [[ -n "${user_name}" && -n "${user_hash}" ]]; then
        cat >> "${firstboot_dir}/rc.porteux-setup" <<SETUPEOF
# Create user: ${user_name}
if ! id "${user_name}" &>/dev/null; then
    useradd -m -G ${user_groups} -s /bin/bash "${user_name}"
fi
echo '${user_name}:${user_hash}' | chpasswd -e 2>/dev/null

SETUPEOF
    fi

    cat >> "${firstboot_dir}/rc.porteux-setup" <<'SETUPEOF'
# Mark setup as done
touch "$MARKER"
echo "PorteuX user setup complete."
SETUPEOF

    chmod +x "${firstboot_dir}/rc.porteux-setup"

    # Also inject into rc.local for auto-execution
    local rc_local="${config_root}/etc/rc.d/rc.local"
    mkdir -p "$(dirname "${rc_local}")"
    if [[ -f "${rc_local}" ]]; then
        if ! grep -q "rc.porteux-setup" "${rc_local}" 2>/dev/null; then
            echo "" >> "${rc_local}"
            echo "# PorteuX installer user setup" >> "${rc_local}"
            echo "[ -x /etc/rc.d/rc.porteux-setup ] && /etc/rc.d/rc.porteux-setup" >> "${rc_local}"
        fi
    else
        cat > "${rc_local}" <<'EOF'
#!/bin/sh
# rc.local — executed at the end of each multiuser runlevel

# PorteuX installer user setup
[ -x /etc/rc.d/rc.porteux-setup ] && /etc/rc.d/rc.porteux-setup
EOF
        chmod +x "${rc_local}"
    fi

    # Auto-login the created user instead of the default 'guest'
    if [[ -n "${user_name}" ]]; then
        _configure_autologin "${config_root}" "${user_name}"
    fi

    einfo "User configuration prepared (will apply on first boot)"
}

# _configure_autologin — Make the display manager log in the installer-created
# user automatically (PorteuX otherwise auto-logins 'guest'). Each DM reads only
# its own config, so writing configs for all major DMs is safe — only the one
# the variant actually ships will take effect:
#   - SDDM    (KDE / LXQt)      → drop-in
#   - LightDM (XFCE/MATE/Cinn.) → drop-in
#   - LXDM    (LXDE)            → full conf (no drop-in support; overlays the
#                                 squashfs file)
#   - GDM     (GNOME)           → full custom.conf (same caveat)
# A wrong session value at worst degrades to the DM greeter, never a black screen.
_configure_autologin() {
    local config_root="$1" user="$2"

    # Per-variant session names / launchers for each DM family.
    local sddm_sess="" lightdm_sess="" lxdm_exec=""
    case "${DESKTOP_VARIANT:-kde}" in
        kde)      sddm_sess="plasma.desktop";   lightdm_sess="plasma";   lxdm_exec="/usr/bin/startplasma-x11" ;;
        lxqt)     sddm_sess="lxqt.desktop";     lightdm_sess="lxqt";     lxdm_exec="/usr/bin/startlxqt" ;;
        xfce)     sddm_sess="xfce.desktop";     lightdm_sess="xfce";     lxdm_exec="/usr/bin/startxfce4" ;;
        lxde)     sddm_sess="LXDE.desktop";     lightdm_sess="LXDE";     lxdm_exec="/usr/bin/startlxde" ;;
        mate)     sddm_sess="mate.desktop";     lightdm_sess="mate";     lxdm_exec="/usr/bin/mate-session" ;;
        gnome)    sddm_sess="gnome.desktop";    lightdm_sess="gnome";    lxdm_exec="/usr/bin/gnome-session" ;;
        cinnamon) sddm_sess="cinnamon.desktop"; lightdm_sess="cinnamon"; lxdm_exec="/usr/bin/cinnamon-session" ;;
        cosmic)   sddm_sess="cosmic.desktop";   lightdm_sess="cosmic";   lxdm_exec="" ;;
    esac

    # --- SDDM drop-in ---
    local sddm_dir="${config_root}/etc/sddm.conf.d"
    mkdir -p "${sddm_dir}"
    # zz- prefix → read last, overrides upstream guest autologin.
    {
        echo "# Auto-login configured by the PorteuX installer"
        echo "[Autologin]"
        echo "User=${user}"
        [[ -n "${sddm_sess}" ]] && echo "Session=${sddm_sess}"
        echo "Relogin=false"
    } > "${sddm_dir}/zz-porteux-installer-autologin.conf"

    # --- LightDM drop-in (/etc/lightdm/lightdm.conf.d/*.conf is supported) ---
    local lightdm_dir="${config_root}/etc/lightdm/lightdm.conf.d"
    mkdir -p "${lightdm_dir}"
    {
        echo "# Auto-login configured by the PorteuX installer"
        echo "[Seat:*]"
        echo "autologin-user=${user}"
        echo "autologin-user-timeout=0"
        [[ -n "${lightdm_sess}" ]] && echo "autologin-session=${lightdm_sess}"
    } > "${lightdm_dir}/50-porteux-installer-autologin.conf"

    # --- LXDM (no drop-in support; overlay a minimal lxdm.conf) ---
    local lxdm_dir="${config_root}/etc/lxdm"
    mkdir -p "${lxdm_dir}"
    {
        echo "# Auto-login configured by the PorteuX installer"
        echo "[base]"
        echo "autologin=${user}"
        [[ -n "${lxdm_exec}" ]] && echo "session=${lxdm_exec}"
        echo "[server]"
        echo "arg=/usr/bin/X"
    } > "${lxdm_dir}/lxdm.conf"

    # --- GDM (single custom.conf; same caveat as LXDM) ---
    local gdm_dir="${config_root}/etc/gdm"
    mkdir -p "${gdm_dir}"
    {
        echo "# Auto-login configured by the PorteuX installer"
        echo "[daemon]"
        echo "AutomaticLoginEnable=true"
        echo "AutomaticLogin=${user}"
    } > "${gdm_dir}/custom.conf"

    einfo "Autologin configured: ${user} (SDDM/LightDM/LXDM/GDM, variant=${DESKTOP_VARIANT:-?})"
}

# system_finalize — Final system configuration
system_finalize() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"

    einfo "Finalizing system configuration..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would finalize system"
        return 0
    fi

    # Ensure all directories have correct permissions
    local config_root="${target}"
    if [[ "${PERSISTENCE_MODE:-changes}" == "changes" ]]; then
        config_root="${target}/${PORTEUX_CHANGES_DIR}"
    fi

    # Set proper permissions on sensitive files
    if [[ -f "${config_root}/etc/rc.d/rc.porteux-setup" ]]; then
        chmod 700 "${config_root}/etc/rc.d/rc.porteux-setup"
    fi

    # Create optional directories
    mkdir -p "${target}/${PORTEUX_OPTIONAL_DIR}"

    # Sync filesystem
    sync

    einfo "System finalization complete"
}
