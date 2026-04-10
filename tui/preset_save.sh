#!/usr/bin/env bash
# preset_save.sh — Export configuration as a reusable preset
source "${LIB_DIR}/protection.sh"

screen_preset_save() {
    if ! dialog_yesno "Save Preset" "Save current configuration as a reusable preset?"; then
        return ${TUI_NEXT}
    fi

    local default_path="/root/porteux-preset-$(date +%Y%m%d).conf"
    local file
    file=$(dialog_inputbox "Preset File" "Save preset to:" "${default_path}") || return ${TUI_NEXT}

    preset_export "${file}"
    dialog_msgbox "Preset Saved" "Configuration saved to:\n${file}\n\nReuse with:\n  ./install.sh --config ${file}"

    return ${TUI_NEXT}
}
