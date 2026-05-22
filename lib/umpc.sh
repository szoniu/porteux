#!/usr/bin/env bash
# umpc.sh — Runtime quirks for UMPCs (GPD Pocket/Win, Chuwi MiniBook X) on
# PorteuX. Panel rotation for the console + GRUB/syslinux menu is handled via
# the kernel cmdline in bootloader.sh. This module installs:
#   - ALC287 Auto-Mute disable (Pocket 4 speakers are silent without it)
#   - SDDM X11 greeter rotation (Xorg ignores the kernel panel_orientation
#     quirk, so the login screen alone stays portrait without this)
#   - POST-INSTALL note for gpd-fan-daemon (no prebuilt module ships it)
#
# PorteuX is a live, Slackware-based system: NO chroot, NO package manager,
# sysvinit (not systemd/OpenRC). So unlike the Gentoo installer:
#   - All paths are written DIRECTLY onto the mounted target, prefixed with the
#     config root (${MOUNTPOINT} or ${MOUNTPOINT}/${PORTEUX_CHANGES_DIR} when
#     persistence is enabled) — exactly like lib/system.sh does.
#   - Boot-time scripts run from the first-boot rc.porteux-setup helper (created
#     by system_create_users) which is wired into /etc/rc.d/rc.local.
#   - We do NOT install xrandr (no package manager) — we assume it ships in the
#     prebuilt GUI/desktop module and guard every use.
source "${LIB_DIR}/protection.sh"

# _umpc_config_root — Echo the directory onto which all target files are
# written. Mirrors the config_root logic in lib/system.sh: when persistence is
# enabled, config must land in the AUFS changes overlay so it survives reboots;
# otherwise it goes onto the base system.
_umpc_config_root() {
    local target="${MOUNTPOINT:?MOUNTPOINT not set}"
    if [[ "${PERSISTENCE_MODE:-changes}" == "changes" ]]; then
        echo "${target}/${PORTEUX_CHANGES_DIR}"
    else
        echo "${target}"
    fi
}

# umpc_apply_quirks — Entry point called from the install phase (after
# system_config/users, before finalize). No chroot — writes onto the mounted
# target.
umpc_apply_quirks() {
    [[ "${UMPC_DETECTED:-0}" == "1" ]] || return 0

    einfo "Applying UMPC runtime quirks for ${UMPC_VENDOR} ${UMPC_MODEL}..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would apply UMPC quirks"
        return 0
    fi

    local config_root
    config_root="$(_umpc_config_root)"

    if [[ "${UMPC_ALC287_QUIRK:-0}" == "1" ]]; then
        _umpc_install_alc287_unmute "${config_root}"
    fi

    # SDDM's X11 greeter doesn't honor the kernel panel_orientation quirk
    # (only the console + Wayland session do), so the login screen stays
    # portrait. Rotate it explicitly via xrandr in Xsetup.
    if [[ -n "${UMPC_FBCON_ROTATE:-}" ]] && [[ "${UMPC_FBCON_ROTATE}" != "0" ]]; then
        _umpc_rotate_sddm_greeter "${config_root}"
    fi

    if [[ "${UMPC_GPD_FAN:-0}" == "1" ]]; then
        _umpc_write_gpd_fan_note "${config_root}"
    fi

    # Always emit a generic UMPC summary so users see what was done
    _umpc_append_summary "${config_root}"

    einfo "UMPC quirks applied"
}

# _umpc_install_alc287_unmute — Auto-Mute Mode = Disabled at every boot.
# ALC287 on Pocket 4 (and many AMD Phoenix laptops) ships with Auto-Mute
# enabled by default, which routes audio nowhere unless a headphone jack
# is sensed correctly. The driver's jack detection is unreliable on this
# codec, so speakers stay silent. Fix: disable Auto-Mute via amixer at
# boot. amixer comes from alsa-utils, present in the prebuilt PorteuX system.
#
# PorteuX has no systemd/OpenRC: we drop the script onto the target and chain
# its invocation off the first-boot rc.porteux-setup helper (created by
# system_create_users and wired into rc.local). The unmute runs every boot —
# rc.porteux-setup itself early-exits after the first run, so we add a separate
# rc.local hook for the recurring amixer call.
_umpc_install_alc287_unmute() {
    local root="$1"
    einfo "  Installing ALC287 Auto-Mute disable script..."

    # The script itself — runs amixer commands. Card index 0 is the usual
    # internal HDA on these devices. Tolerate failure if the control names
    # differ on this specific codec revision.
    local sbin_dir="${root}/usr/local/sbin"
    mkdir -p "${sbin_dir}"
    local script_path="${sbin_dir}/alc287-unmute"
    cat > "${script_path}" << 'SCRIPTEOF'
#!/bin/sh
# alc287-unmute — Disable ALC287 Auto-Mute Mode and unmute Master/Speaker.
# Installed by the PorteuX installer for UMPCs with ALC287 quirks (GPD Pocket 4).
# Runs at every boot via /etc/rc.d/rc.local.
set -u

# Wait briefly for the sound card to be enumerated (race with udev on boot).
for _ in 1 2 3 4 5; do
    if [ -e /proc/asound/card0 ]; then break; fi
    sleep 1
done

# Disable Auto-Mute (the actual fix). Tolerant of missing control.
amixer -c 0 sset 'Auto-Mute Mode' Disabled >/dev/null 2>&1 || true

# Unmute and raise common output controls. PipeWire/PulseAudio set userspace
# volumes separately; this just makes sure the hardware mixer isn't gating audio.
for ctl in 'Master' 'Speaker' 'Headphone' 'PCM'; do
    amixer -c 0 sset "${ctl}" unmute >/dev/null 2>&1 || true
    amixer -c 0 sset "${ctl}" '100%' >/dev/null 2>&1 || true
done

# Persist state so alsactl restore on next boot keeps it if alsa-restore runs.
alsactl store >/dev/null 2>&1 || true

exit 0
SCRIPTEOF
    chmod 0755 "${script_path}"

    # Wire it into rc.local so it runs every boot (sysvinit). Idempotent —
    # guard against double-insertion on re-run / resume. system_create_users
    # already created (or will create) rc.local + the rc.porteux-setup hook;
    # we append our own line after it.
    local rc_local="${root}/etc/rc.d/rc.local"
    mkdir -p "$(dirname "${rc_local}")"
    if [[ -f "${rc_local}" ]]; then
        if ! grep -q "alc287-unmute" "${rc_local}" 2>/dev/null; then
            {
                echo ""
                echo "# PorteuX installer: ALC287 Auto-Mute disable (UMPC quirk)"
                echo "[ -x /usr/local/sbin/alc287-unmute ] && /usr/local/sbin/alc287-unmute"
            } >> "${rc_local}"
        fi
    else
        cat > "${rc_local}" << 'EOF'
#!/bin/sh
# rc.local — executed at the end of each multiuser runlevel

# PorteuX installer: ALC287 Auto-Mute disable (UMPC quirk)
[ -x /usr/local/sbin/alc287-unmute ] && /usr/local/sbin/alc287-unmute
EOF
    fi
    chmod 0755 "${rc_local}" 2>/dev/null || true
    einfo "  ALC287 unmute script installed (runs every boot via rc.local)"
}

# _umpc_rotate_sddm_greeter — Rotate the SDDM X11 login greeter.
# The kernel panel_orientation quirk (set in the boot cmdline) rotates the
# fbcon console and is honored by the Plasma *Wayland* session, but SDDM's
# greeter runs on Xorg, which ignores panel_orientation — so the login
# screen alone stays portrait on a UMPC. Fix: rotate it with xrandr from
# Xsetup. Two gotchas learned on a GPD Pocket 4:
#   - Xorg names the panel "eDP" (NOT the DRM name "eDP-1") — auto-detect
#     the connected output instead of hardcoding it.
#   - xrandr must be present. On PorteuX it ships in the prebuilt KDE/GUI
#     module (no package manager to install it) — Xsetup invokes it
#     defensively (command -v guard) so a missing binary fails silently
#     rather than breaking the greeter.
# fbcon rotate value -> xrandr rotation: 1=right (90 CW), 2=inverted,
# 3=left (90 CCW). Verified: Pocket 4 fbcon=rotate:1 <-> xrandr right.
_umpc_rotate_sddm_greeter() {
    local root="$1"

    # Only meaningful when SDDM is present (Plasma / KDE variant). The KDE
    # PorteuX ISO ships SDDM under /usr/share/sddm. Other desktops use a
    # Wayland greeter that honors panel_orientation on its own.
    if [[ ! -d "${root}/usr/share/sddm" ]]; then
        einfo "  No SDDM present on target — skipping greeter rotation"
        return 0
    fi

    local rot
    case "${UMPC_FBCON_ROTATE}" in
        1) rot="right" ;;
        2) rot="inverted" ;;
        3) rot="left" ;;
        *) return 0 ;;
    esac

    einfo "  Rotating SDDM greeter (xrandr --rotate ${rot})..."

    local scripts_dir="${root}/usr/share/sddm/scripts"
    mkdir -p "${scripts_dir}"
    cat > "${scripts_dir}/Xsetup" << XSETUPEOF
#!/bin/sh
# Xsetup — rotate the SDDM X11 greeter to match the UMPC panel.
# Xorg names the internal panel "eDP" (not the DRM "eDP-1"), so detect
# the connected output rather than hardcoding it. Written by the PorteuX
# installer (umpc_quirks) for UMPCs with a rotated panel. xrandr is assumed
# to be present in the prebuilt GUI module; guard so a missing binary does
# not break the greeter.
command -v xrandr >/dev/null 2>&1 || exit 0
_out=\$(xrandr | awk '/ connected/{print \$1; exit}')
[ -n "\${_out}" ] && xrandr --output "\${_out}" --rotate ${rot}
XSETUPEOF
    chmod 0755 "${scripts_dir}/Xsetup"
    einfo "  SDDM greeter rotation configured (output auto-detected, --rotate ${rot})"
}

# _umpc_write_gpd_fan_note — Append manual install instructions for
# gpd-fan-daemon to /root/POST-INSTALL-NOTES.txt. No prebuilt PorteuX module
# ships it, and there is no package manager post-install, so we cannot
# auto-install. Without the daemon, fans run on ACPI defaults — usable but
# louder than Windows. The enable step uses Slackware/sysvinit conventions
# (an executable /etc/rc.d/rc.<service> script).
_umpc_write_gpd_fan_note() {
    local root="$1"
    einfo "  Writing GPD fan daemon POST-INSTALL note..."

    mkdir -p "${root}/root"
    local notes="${root}/root/POST-INSTALL-NOTES.txt"
    touch "${notes}"
    chmod 0600 "${notes}"

    cat >> "${notes}" << NOTEEOF

=== GPD Fan Control (${UMPC_MODEL}) ===

The installer did NOT install a userspace fan daemon — no prebuilt PorteuX
module ships gpd-fan-daemon, and PorteuX has no package manager post-install.
Fans currently run on ACPI table defaults: usable, but louder/more aggressive
than under Windows.

To set up smarter fan curves manually post-install (requires the 05-devel
module activated for a compiler + git):

1. Kernel module (gpd-fan) — build against the running kernel headers:
     git clone https://github.com/Cryolitia/gpd-fan-driver
     cd gpd-fan-driver
     make
     make install      # or insmod ./gpd-fan.ko to test
     depmod -a

2. Userspace daemon (gpd-fan-daemon) — needs Rust/cargo:
     git clone https://github.com/Cryolitia/gpd-fan-daemon
     cd gpd-fan-daemon
     cargo build --release
     install -m 0755 target/release/gpd-fan-daemon /usr/local/sbin/

3. Enable the daemon (Slackware / sysvinit) — upstream ships only a systemd
   unit, so create a Slackware-style rc.d service. Paste this block
   flush-left:

cat > /etc/rc.d/rc.gpd-fan-daemon << 'EOF'
#!/bin/sh
# rc.gpd-fan-daemon — GPD fan curve daemon (sysvinit / Slackware)
case "\$1" in
  start)
    echo "Starting gpd-fan-daemon..."
    /usr/local/sbin/gpd-fan-daemon &
    ;;
  stop)
    echo "Stopping gpd-fan-daemon..."
    pkill -f /usr/local/sbin/gpd-fan-daemon
    ;;
  restart)
    \$0 stop; sleep 1; \$0 start
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart}"
    ;;
esac
EOF
chmod 0755 /etc/rc.d/rc.gpd-fan-daemon

   Then start it on boot by adding to /etc/rc.d/rc.local:
     [ -x /etc/rc.d/rc.gpd-fan-daemon ] && /etc/rc.d/rc.gpd-fan-daemon start

For temperature/fan monitoring without the daemon:
     sensors-detect --auto
     sensors

NOTEEOF
}

# _umpc_append_summary — Document everything we applied so the user can
# audit it after reboot.
_umpc_append_summary() {
    local root="$1"

    mkdir -p "${root}/root"
    local notes="${root}/root/POST-INSTALL-NOTES.txt"
    touch "${notes}"
    chmod 0600 "${notes}"

    cat >> "${notes}" << NOTEEOF

=== UMPC Quirks Applied (${UMPC_VENDOR} ${UMPC_MODEL}) ===

NOTEEOF

    if [[ -n "${UMPC_PANEL_ORIENTATION:-}" ]]; then
        cat >> "${notes}" << NOTEEOF
- Panel rotation: added to the kernel boot parameters (syslinux APPEND for
  BIOS, GRUB linux line for EFI):
    fbcon=rotate:${UMPC_FBCON_ROTATE} video=${UMPC_VIDEO_CONNECTOR}:panel_orientation=${UMPC_PANEL_ORIENTATION}
  If rotation is wrong: try left_side_up instead of right_side_up, or
  change fbcon=rotate to 3. Edit /boot/syslinux/porteux.cfg (BIOS) or the
  GRUB grub.cfg on the ESP (EFI), then reboot.

NOTEEOF
    fi

    if [[ "${UMPC_ALC287_QUIRK:-0}" == "1" ]]; then
        cat >> "${notes}" << NOTEEOF
- ALC287 speakers: alc287-unmute script installed
  (/usr/local/sbin/alc287-unmute, runs at every boot via /etc/rc.d/rc.local)
  If still quiet: 'alsamixer' -> F6 select card -> unmute everything,
  then 'alsactl store'.

NOTEEOF
    fi
}
