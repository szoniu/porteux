#!/usr/bin/env bash
# preset_load.sh — Load a saved preset configuration
source "${LIB_DIR}/protection.sh"

screen_preset_load() {
    local choice
    choice=$(dialog_menu "Load Preset" "Would you like to load a saved configuration?" \
        "skip"   "Start fresh (no preset)" \
        "file"   "Load from file" \
        "browse" "Browse example presets") || return ${TUI_BACK}

    case "${choice}" in
        skip)
            einfo "Starting fresh configuration"
            ;;
        file)
            local preset_dir="/root"
            # Auto-select latest preset
            local latest=""
            latest=$(ls -t "${preset_dir}"/porteux-preset-*.conf 2>/dev/null | head -1)

            local file
            file=$(dialog_inputbox "Preset File" "Enter preset file path:" \
                "${latest:-/root/porteux-preset.conf}") || return ${TUI_BACK}

            if [[ -f "${file}" ]]; then
                preset_import "${file}"
                einfo "Preset loaded from ${file}"

                if dialog_yesno "Skip to Summary" \
                    "Preset loaded. Skip configuration screens and go to summary?"; then
                    export _PRESET_SKIP_TO_USER=1
                fi
            else
                dialog_msgbox "Error" "File not found: ${file}"
                return ${TUI_BACK}
            fi
            ;;
        browse)
            local -a presets=()
            local f
            for f in "${SCRIPT_DIR}/presets"/*.conf "${SCRIPT_DIR}/presets"/*.conf.example; do
                [[ -f "${f}" ]] || continue
                presets+=("$(basename "${f}")" "$(head -5 "${f}" | grep '^# ' | tail -1 | sed 's/^# //')")
            done

            if [[ ${#presets[@]} -eq 0 ]]; then
                dialog_msgbox "No Presets" "No example presets found in presets/ directory."
                return ${TUI_BACK}
            fi

            local selected
            selected=$(dialog_menu "Example Presets" "Select a preset:" "${presets[@]}") || return ${TUI_BACK}
            preset_import "${SCRIPT_DIR}/presets/${selected}"
            einfo "Preset loaded: ${selected}"
            ;;
    esac

    return ${TUI_NEXT}
}
