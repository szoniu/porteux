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
    locale=$(dialog_menu "Locale" "Select system locale:" \
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

    # --- Keymap ---
    local keymap
    keymap=$(dialog_menu "Keymap" "Select console keymap:" \
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

    return ${TUI_NEXT}
}
