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
    system_set_polkit_wheel_admin "${config_root}"
    system_set_sudoers_wheel "${config_root}"

    einfo "System configuration complete"
}

# system_set_sudoers_wheel — Let members of the wheel group run sudo with their
# own password. Needed because porteux-app-store uses `psu`, which OUTSIDE KDE
# falls back to /opt/porteux-scripts/sudo.py — that script runs `sudo -Sk true`,
# i.e. it validates the calling user against sudoers. Stock Slackware ships
# `%wheel ALL=(ALL) ALL` commented out, so a wheel user without this drop-in
# gets "input cleared" by sudo.py with no useful error. (The KDE path uses
# pkexec/polkit and is covered by system_set_polkit_wheel_admin.)
system_set_sudoers_wheel() {
    local root="$1"
    local sudoers_dir="${root}/etc/sudoers.d"
    mkdir -p "${sudoers_dir}"
    local f="${sudoers_dir}/49-porteux-wheel"
    cat > "${f}" <<'EOF'
# Wheel-group sudo access — added by the PorteuX installer.
# psu (porteux-app-store) calls sudo.py outside KDE, which validates
# the calling user via sudo — wheel members need a sudoers entry.
%wheel ALL=(ALL) ALL
EOF
    chmod 0440 "${f}" 2>/dev/null || true
    einfo "Sudoers: wheel group granted password-authenticated sudo"
}

# system_set_polkit_wheel_admin — Let members of the wheel group authenticate
# PolicyKit admin actions with their own password. The stock PorteuX rule
# (50-default.rules, patched to unix-user:root only) plus this drop-in covers
# the pkexec path used by psu inside KDE. For non-KDE desktops psu uses
# sudo.py instead — see system_set_sudoers_wheel.
system_set_polkit_wheel_admin() {
    local root="$1"
    local rules_dir="${root}/etc/polkit-1/rules.d"
    mkdir -p "${rules_dir}"
    cat > "${rules_dir}/49-wheel-admin.rules" <<'EOF'
// Wheel-group admin auth for PolicyKit — added by the PorteuX installer.
// Loaded before the stock 50-default.rules; both apply, so wheel members
// AND root can both authenticate admin actions with their own passwords.
polkit.addAdminRule(function(action, subject) {
    return ["unix-group:wheel"];
});
EOF
    einfo "PolicyKit: wheel group granted admin authentication"
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

    # X11 xkb layout — keep the desktop keyboard in sync with TTY so password
    # dialogs in X (psu, polkit, login screens) interpret keys the same way as
    # the install-time `passwd` / wizard input did. Without this, a 'pl' TTY
    # keymap with a default-us X session meant special chars in passwords were
    # mapped to different bytes → password rejected even when typed correctly.
    local xkb_layout="${keymap}"
    [[ "${xkb_layout}" == "uk" ]] && xkb_layout="gb"   # only common alias
    mkdir -p "${root}/etc/X11/xorg.conf.d"
    cat > "${root}/etc/X11/xorg.conf.d/00-keyboard.conf" <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${xkb_layout}"
EndSection
EOF

    einfo "Keymap set to ${keymap} (TTY + X11 xkb=${xkb_layout})"
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
    local user_groups="${USER_GROUPS:-wheel,audio,video,input,cdrom,plugdev,lp,netdev}"

    cat > "${firstboot_dir}/rc.porteux-setup" <<'SETUPEOF'
#!/bin/sh
# PorteuX first-boot setup (created by installer). Runs once via rc.local;
# the marker prevents re-execution. Everything is logged so silent failures
# (e.g. useradd not in PATH, chpasswd errors) are diagnosable post-boot.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LOG=/var/log/porteux-installer-firstboot.log
# Marker uses installer-specific name (NOT the bare .porteux-setup-done which
# PorteuX itself ships in its ISO/squashfs).
MARKER=/etc/.porteux-installer-firstboot-done

# Send everything to the log — make silent failures visible.
exec >>"$LOG" 2>&1
echo "[$(date '+%F %T')] === porteux first-boot setup ==="

if [ -f "$MARKER" ]; then
    echo "marker exists, skipping"
    exit 0
fi

# Ensure dirs useradd touches actually exist (PorteuX module trims some).
mkdir -p /var/spool/mail /var/mail 2>/dev/null || true

SETUPEOF

    # Set root password
    if [[ -n "${root_hash}" ]]; then
        cat >> "${firstboot_dir}/rc.porteux-setup" <<SETUPEOF
echo "setting root password..."
echo 'root:${root_hash}' | /usr/sbin/chpasswd -e
echo "  chpasswd rc=\$?"

SETUPEOF
    fi

    # Create user (absolute paths; POSIX-compatible '>/dev/null 2>&1' instead
    # of the bashism '&>/dev/null' that breaks if /bin/sh is dash).
    if [[ -n "${user_name}" && -n "${user_hash}" ]]; then
        cat >> "${firstboot_dir}/rc.porteux-setup" <<SETUPEOF
echo "creating user ${user_name} (requested groups: ${user_groups})..."
if /usr/bin/id ${user_name} >/dev/null 2>&1; then
    echo "  already exists"
else
    # Filter to groups that actually exist. Distros differ (Slackware has no
    # 'storage'/'network' groups, Void has no 'plugdev', ...); one missing
    # group makes useradd refuse the whole call (exit 6).
    real_groups=""
    for g in \$(echo "${user_groups}" | tr ',' ' '); do
        if /usr/bin/getent group "\$g" >/dev/null 2>&1; then
            real_groups="\${real_groups:+\$real_groups,}\$g"
        else
            echo "  skipping non-existent group: \$g"
        fi
    done
    echo "  effective groups: \${real_groups:-<none>}"
    if [ -n "\$real_groups" ]; then
        /usr/sbin/useradd -m -G "\$real_groups" -s /bin/bash "${user_name}"
    else
        /usr/sbin/useradd -m -s /bin/bash "${user_name}"
    fi
    echo "  useradd rc=\$?"
fi
echo "setting password for ${user_name}..."
echo '${user_name}:${user_hash}' | /usr/sbin/chpasswd -e
echo "  chpasswd rc=\$?"

SETUPEOF
    fi

    cat >> "${firstboot_dir}/rc.porteux-setup" <<'SETUPEOF'
# Always set the marker — logs above show what actually happened. Manual
# retry: rm -f /etc/.porteux-installer-firstboot-done && sh /etc/rc.d/rc.porteux-setup
touch "$MARKER"
echo "[$(date '+%F %T')] porteux first-boot setup complete"
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
    # Some variants offer a real X11/Wayland choice — honor DISPLAY_SERVER set
    # by the wizard. For Wayland-only or X11-only variants the value is forced
    # by screen_display_server, so the inner case is effectively a no-op there.
    local sddm_sess="" lightdm_sess="" lxdm_exec=""
    local ds="${DISPLAY_SERVER:-auto}"
    case "${DESKTOP_VARIANT:-kde}" in
        kde)
            case "${ds}" in
                x11)     sddm_sess="plasmax11.desktop";  lightdm_sess="plasmax11";  lxdm_exec="/usr/bin/startplasma-x11" ;;
                *)       sddm_sess="plasma.desktop";     lightdm_sess="plasma";     lxdm_exec="/usr/bin/startplasma-wayland" ;;
            esac ;;
        gnome)
            case "${ds}" in
                x11)     sddm_sess="gnome-xorg.desktop"; lightdm_sess="gnome-xorg"; lxdm_exec="/usr/bin/gnome-session" ;;
                *)       sddm_sess="gnome.desktop";     lightdm_sess="gnome";       lxdm_exec="/usr/bin/gnome-session" ;;
            esac ;;
        lxqt)
            case "${ds}" in
                wayland) sddm_sess="lxqt-wayland.desktop"; lightdm_sess="lxqt-wayland"; lxdm_exec="/usr/bin/startlxqtwayland" ;;
                *)       sddm_sess="lxqt.desktop";          lightdm_sess="lxqt";          lxdm_exec="/usr/bin/startlxqt" ;;
            esac ;;
        cosmic)   sddm_sess="cosmic.desktop";   lightdm_sess="cosmic";   lxdm_exec="" ;;
        xfce)     sddm_sess="xfce.desktop";     lightdm_sess="xfce";     lxdm_exec="/usr/bin/startxfce4" ;;
        lxde)     sddm_sess="LXDE.desktop";     lightdm_sess="LXDE";     lxdm_exec="/usr/bin/startlxde" ;;
        mate)     sddm_sess="mate.desktop";     lightdm_sess="mate";     lxdm_exec="/usr/bin/mate-session" ;;
        cinnamon) sddm_sess="cinnamon.desktop"; lightdm_sess="cinnamon"; lxdm_exec="/usr/bin/cinnamon-session" ;;
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

    einfo "Autologin configured: ${user} (SDDM/LightDM/LXDM/GDM, variant=${DESKTOP_VARIANT:-?}, ds=${ds})"
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

    # Install the post-install module-update helper TWICE, on purpose:
    #   1. ${config_root}/usr/local/bin — lands in PATH of the booted system
    #      (PorteuX squashfs has no /usr/local/bin of its own). With
    #      PERSISTENCE_MODE=changes this is inside the AUFS overlay, so it only
    #      exists in sessions that mount that overlay.
    #   2. <media>/porteux/porteux-update-modules — plain file on the partition,
    #      outside any overlay. Reachable from ANY boot (a stateless `fresh`
    #      session, another live ISO, a rescue shell) as
    #      /mnt/<dev>/porteux/porteux-update-modules. This is the copy that saves
    #      the base-upgrade route when the running session has no persistence.
    local helper_src="${SCRIPT_DIR}/scripts/porteux-update-modules.sh"
    if [[ -f "${helper_src}" ]]; then
        local helper_dst="${config_root}/usr/local/bin"
        mkdir -p "${helper_dst}"
        install -m 755 "${helper_src}" "${helper_dst}/porteux-update-modules"
        einfo "Installed porteux-update-modules to /usr/local/bin"

        install -m 755 "${helper_src}" "${target}/${PORTEUX_BASE_DIR}/porteux-update-modules"
        einfo "Installed overlay-independent copy: /${PORTEUX_BASE_DIR}/porteux-update-modules"

        cat > "${target}/${PORTEUX_BASE_DIR}/UPDATE-README.txt" <<'HELPEREOF'
PorteuX update helper — where it lives
======================================

In the running system (needs the persistence overlay mounted):
    porteux-update-modules                  # list outdated optional modules
    porteux-update-modules --download       # fetch newer optional modules
    sudo porteux-update-modules --upgrade-base   # full release bump from a new ISO

Always available, no overlay required (this partition, mounted under /mnt/<dev>):
    bash /mnt/<dev>/porteux/porteux-update-modules --help

"porteux-update-modules: command not found" means the session you booted has no
persistence layer (no changes= on that boot label). Check with:
    cat /proc/cmdline
Then either boot the label that carries changes=/porteux, or run the copy above
by absolute path. `--fix-persistence` repairs boot labels that lost changes=.
HELPEREOF
    else
        ewarn "Helper source missing: ${helper_src}"
        ewarn "Post-install updates will need a manual download of scripts/porteux-update-modules.sh"
    fi

    # Sync filesystem
    sync

    einfo "System finalization complete"
}
