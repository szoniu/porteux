#!/usr/bin/env bash
# user_config.sh — User account configuration
source "${LIB_DIR}/protection.sh"

screen_user_config() {
    local msg="Configure user accounts.\n\n"
    msg+="PorteuX defaults: root/toor, guest/guest\n"
    msg+="The installer will override these on first boot."

    dialog_msgbox "User Configuration" "${msg}"

    # --- Root password ---
    local root_pw1 root_pw2
    while true; do
        root_pw1=$(dialog_passwordbox "Root Password" "Enter root password:") || return ${TUI_BACK}
        root_pw2=$(dialog_passwordbox "Root Password" "Confirm root password:") || return ${TUI_BACK}

        if [[ "${root_pw1}" == "${root_pw2}" ]]; then
            break
        fi
        dialog_msgbox "Mismatch" "Passwords do not match. Please try again."
    done

    if [[ -n "${root_pw1}" ]]; then
        ROOT_PASSWORD_HASH=$(generate_password_hash "${root_pw1}")
        export ROOT_PASSWORD_HASH
        einfo "Root password set"
    fi

    # --- Username ---
    local username
    username=$(dialog_inputbox "Username" "Enter regular user login:" \
        "${USERNAME:-user}") || return ${TUI_BACK}

    export USERNAME="${username}"
    einfo "Username: ${USERNAME}"

    # --- User password ---
    local user_pw1 user_pw2
    while true; do
        user_pw1=$(dialog_passwordbox "User Password" "Enter password for ${USERNAME}:") || return ${TUI_BACK}
        user_pw2=$(dialog_passwordbox "User Password" "Confirm password for ${USERNAME}:") || return ${TUI_BACK}

        if [[ "${user_pw1}" == "${user_pw2}" ]]; then
            break
        fi
        dialog_msgbox "Mismatch" "Passwords do not match. Please try again."
    done

    if [[ -n "${user_pw1}" ]]; then
        USER_PASSWORD_HASH=$(generate_password_hash "${user_pw1}")
        export USER_PASSWORD_HASH
        einfo "User password set"
    fi

    # --- Groups ---
    local groups
    groups=$(dialog_inputbox "Groups" "User groups (comma-separated):" \
        "${USER_GROUPS:-wheel,audio,video,input,cdrom,plugdev,lp,netdev}") || return ${TUI_BACK}

    export USER_GROUPS="${groups}"
    einfo "User groups: ${USER_GROUPS}"

    return ${TUI_NEXT}
}
