#!/usr/bin/env bash
# module_select.sh — Optional PorteuX module selection
source "${LIB_DIR}/protection.sh"

screen_module_select() {
    local msg="Select optional modules to include:\n\n"
    msg+="These modules will be downloaded and placed in\n"
    msg+="/${PORTEUX_OPTIONAL_DIR}/ for manual activation.\n"

    local -a items=()

    items+=("05-devel"           "Development tools (GCC, make, git, cmake)" "off")
    items+=("08-multilanguage"   "Multi-language support (locale data)"      "off")
    items+=("0050-multilib-lite" "32-bit compatibility libraries"            "off")

    local selections
    selections=$(dialog_checklist "Optional Modules" "${msg}" "${items[@]}") || return ${TUI_BACK}

    # Parse selections
    export ENABLE_DEVEL_MODULE="no"
    export ENABLE_MULTILANG_MODULE="no"
    export ENABLE_MULTILIB_MODULE="no"

    if [[ "${selections}" == *"05-devel"* ]]; then
        export ENABLE_DEVEL_MODULE="yes"
        einfo "Development module selected"
    fi

    if [[ "${selections}" == *"08-multilanguage"* ]]; then
        export ENABLE_MULTILANG_MODULE="yes"
        einfo "Multi-language module selected"
    fi

    if [[ "${selections}" == *"0050-multilib-lite"* ]]; then
        export ENABLE_MULTILIB_MODULE="yes"
        einfo "32-bit multilib module selected"
    fi

    return ${TUI_NEXT}
}
