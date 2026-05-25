#!/usr/bin/env bash
# desktop_select.sh — PorteuX desktop variant selection (8 options)
source "${LIB_DIR}/protection.sh"

screen_desktop_select() {
    local choice
    choice=$(dialog_radiolist "Desktop Environment" \
        "kde"      "KDE Plasma — full-featured, modern desktop"        "on" \
        "xfce"     "Xfce — lightweight, traditional desktop"           "off" \
        "lxqt"     "LXQt — ultra-lightweight Qt desktop (3s boot)"     "off" \
        "cinnamon" "Cinnamon — elegant, Windows-like experience"       "off" \
        "mate"     "MATE — classic GNOME 2 fork"                       "off" \
        "gnome"    "GNOME — modern, touch-friendly desktop"            "off" \
        "lxde"     "LXDE — minimal GTK desktop"                        "off" \
        "cosmic"   "COSMIC — System76's new Rust-based desktop"        "off") || return ${TUI_BACK}

    export DESKTOP_VARIANT="${choice}"
    einfo "Desktop variant: ${DESKTOP_VARIANT}"

    # Resolve ISO URL based on selection
    iso_get_url

    return ${TUI_NEXT}
}
