#!/usr/bin/env bash
# locale_config.sh — Timezone, locale, and keymap selection
source "${LIB_DIR}/protection.sh"

screen_locale_config() {
    # --- Timezone ---
    local tz
    tz=$(dialog_inputbox "Timezone" \
        "Enter timezone (e.g. Europe/Warsaw, America/New_York):\n\nTip: ls /usr/share/zoneinfo/" \
        "${TIMEZONE:-Europe/Warsaw}") || return ${TUI_BACK}

    export TIMEZONE="${tz}"
    # Set live TZ for correct timestamps
    export TZ="${tz}"
    einfo "Timezone: ${TIMEZONE}"

    # --- Locale ---
    local locale
    locale=$(dialog_menu "Locale" \
        "en_US.UTF-8" "English (US)" \
        "en_GB.UTF-8" "English (UK)" \
        "pl_PL.UTF-8" "Polish" \
        "de_DE.UTF-8" "German" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        "it_IT.UTF-8" "Italian" \
        "pt_BR.UTF-8" "Portuguese (Brazil)" \
        "ru_RU.UTF-8" "Russian" \
        "ja_JP.UTF-8" "Japanese" \
        "zh_CN.UTF-8" "Chinese (Simplified)" \
        "ko_KR.UTF-8" "Korean" \
        "custom"       "Enter custom locale") || return ${TUI_BACK}

    if [[ "${locale}" == "custom" ]]; then
        locale=$(dialog_inputbox "Custom Locale" \
            "Enter locale (format: xx_XX.UTF-8):" \
            "${LOCALE:-en_US.UTF-8}") || return ${TUI_BACK}
    fi

    export LOCALE="${locale}"
    einfo "Locale: ${LOCALE}"

    # PorteuX's base system only ships C / en_US locales. For anything else the
    # installer auto-includes the 08-multilanguage module (glibc-i18n) so the
    # locale actually works on first boot — tell the user so it isn't a surprise.
    if _locale_needs_i18n; then
        dialog_msgbox "Language data" \
"Locale ${LOCALE} is not part of PorteuX's base system.

The installer will automatically download the 08-multilanguage
module (glibc-i18n) and set it to load at boot, so ${LOCALE}
works out of the box. This needs network access during install."
    fi

    # --- Keymap ---
    local keymap
    keymap=$(dialog_menu "Keymap" \
        "us"    "English (US)" \
        "uk"    "English (UK)" \
        "pl"    "Polish" \
        "de"    "German" \
        "fr"    "French" \
        "es"    "Spanish" \
        "it"    "Italian" \
        "pt"    "Portuguese" \
        "ru"    "Russian" \
        "jp106" "Japanese" \
        "custom" "Enter custom keymap") || return ${TUI_BACK}

    if [[ "${keymap}" == "custom" ]]; then
        keymap=$(dialog_inputbox "Custom Keymap" \
            "Enter keymap name:" \
            "${KEYMAP:-us}") || return ${TUI_BACK}
    fi

    export KEYMAP="${keymap}"
    einfo "Keymap: ${KEYMAP}"

    # Apply the keymap to the running install environment immediately, so
    # passwords typed in later wizard screens (user_config) are recorded with
    # the SAME byte mapping the booted system will use. Without this, picking
    # a non-default keymap silently desynced install-time vs runtime passwords
    # — and X-side prompts (psu, polkit) later refused the right password.
    if command -v loadkeys &>/dev/null && [[ -t 1 ]]; then
        loadkeys "${KEYMAP}" 2>/dev/null || true
    fi

    return ${TUI_NEXT}
}
