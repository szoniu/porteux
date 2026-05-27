#!/usr/bin/env bash
# display_server.sh — Choose X11 vs Wayland session
# Some PorteuX variants give a real choice (KDE / GNOME / LXQt). Others are
# effectively single-server (XFCE/MATE/Cinnamon/LXDE → X11 only, COSMIC →
# Wayland only) — for those we just inform and lock the value.
source "${LIB_DIR}/protection.sh"

screen_display_server() {
    local variant="${DESKTOP_VARIANT:-kde}"

    case "${variant}" in
        cosmic)
            dialog_msgbox "Display Server" \
                "COSMIC is Wayland-only on PorteuX.\n\nDisplay server set to: wayland"
            export DISPLAY_SERVER="wayland"
            return "${TUI_NEXT}"
            ;;
        xfce|mate|cinnamon|lxde)
            dialog_msgbox "Display Server" \
"${variant^^} has no mature Wayland session in PorteuX — using X11.

Display server set to: x11"
            export DISPLAY_SERVER="x11"
            return "${TUI_NEXT}"
            ;;
    esac

    # KDE / GNOME / LXQt — real choice. 'auto' picks the desktop's natural
    # default (Plasma 6 → Wayland, GNOME → Wayland, LXQt → X11 since its
    # Wayland session is still experimental).
    local choice
    choice=$(dialog_radiolist "Display Server" \
        "auto"    "Auto — pick the variant's default (recommended)" "on"  \
        "wayland" "Wayland — modern, HiDPI/touch friendly"           "off" \
        "x11"     "X11 — classic, broader app/driver compatibility"  "off") \
        || return "${TUI_BACK}"

    export DISPLAY_SERVER="${choice}"
    einfo "Display server: ${choice}"
    return "${TUI_NEXT}"
}
