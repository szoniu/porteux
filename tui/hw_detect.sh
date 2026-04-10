#!/usr/bin/env bash
# hw_detect.sh — Hardware detection summary
source "${LIB_DIR}/protection.sh"

screen_hw_detect() {
    dialog_infobox "Hardware Detection" "Detecting hardware..."

    detect_all_hardware

    local summary
    summary=$(get_hardware_summary)

    dialog_msgbox "Hardware Detection" "Detected hardware:\n\n${summary}"

    return ${TUI_NEXT}
}
