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

    einfo "System configuration complete"
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

    mkdir -p "${root}/etc"

    # Slackware uses /etc/rc.d/rc.keymap or keymap setting in rc.conf
    if [[ -f "${root}/etc/rc.d/rc.keymap" ]]; then
        sed -i "s|/usr/share/kbd/keymaps/.*|/usr/share/kbd/keymaps/i386/qwerty/${keymap}.map.gz|" \
            "${root}/etc/rc.d/rc.keymap" 2>/dev/null || true
    fi

    # Create rc.keymap if it doesn't exist
    cat > "${root}/etc/rc.d/rc.keymap" <<EOF
#!/bin/sh
# Load the keyboard map. More strokes at:
# /usr/share/kbd/keymaps
if [ -x /usr/bin/loadkeys ]; then
    /usr/bin/loadkeys /usr/share/kbd/keymaps/i386/qwerty/${keymap}.map.gz
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

MARKER="/etc/.porteux-setup-done"
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

    einfo "User configuration prepared (will apply on first boot)"
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
