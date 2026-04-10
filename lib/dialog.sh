#!/usr/bin/env bash
# dialog.sh — Dialog/whiptail wrapper, navigation stack, wizard runner
source "${LIB_DIR}/protection.sh"

# --- Gum bundled backend ---

# Extract gum binary from bundled tarball in data/gum.tar.gz
_extract_bundled_gum() {
    # Already extracted and working?
    if [[ -x "${GUM_CACHE_DIR}/gum" ]]; then
        return 0
    fi

    local tarball="${DATA_DIR}/gum.tar.gz"
    if [[ ! -f "${tarball}" ]]; then
        return 1
    fi

    mkdir -p "${GUM_CACHE_DIR}"
    if ! tar xzf "${tarball}" -C "${GUM_CACHE_DIR}" \
        "gum_${GUM_VERSION}_Linux_x86_64/gum" 2>/dev/null; then
        return 1
    fi

    # Move binary from subdirectory to cache root
    mv "${GUM_CACHE_DIR}/gum_${GUM_VERSION}_Linux_x86_64/gum" \
       "${GUM_CACHE_DIR}/gum" 2>/dev/null || true
    rmdir "${GUM_CACHE_DIR}/gum_${GUM_VERSION}_Linux_x86_64" 2>/dev/null || true
    chmod +x "${GUM_CACHE_DIR}/gum"

    # Verify it runs
    if ! "${GUM_CACHE_DIR}/gum" --version &>/dev/null; then
        rm -f "${GUM_CACHE_DIR}/gum"
        return 1
    fi
    return 0
}

# Try to enable gum backend. Returns 0 if gum is available, 1 otherwise.
_try_gum_backend() {
    # Opt-out via env
    if [[ "${GUM_BACKEND:-}" == "0" ]]; then
        return 1
    fi

    # System gum?
    if command -v gum &>/dev/null; then
        GUM_CMD="$(command -v gum)"
        return 0
    fi

    # Cached from previous extraction?
    if [[ -x "${GUM_CACHE_DIR}/gum" ]]; then
        GUM_CMD="${GUM_CACHE_DIR}/gum"
        export PATH="${GUM_CACHE_DIR}:${PATH}"
        return 0
    fi

    # Extract from bundled tarball
    if _extract_bundled_gum; then
        GUM_CMD="${GUM_CACHE_DIR}/gum"
        export PATH="${GUM_CACHE_DIR}:${PATH}"
        return 0
    fi

    return 1
}

# Set gum theme env vars to match existing dialogrc dark theme
_setup_gum_theme() {
    # Tell termenv we have a dark background — prevents OSC 11 terminal queries
    # that cause phantom input in gum's bubbletea (auto-selecting menus, garbage in inputs)
    export COLORFGBG="15;0"

    # Disable terminal echo for the entire gum session.
    # gum (bubbletea/termenv) sends OSC 11 and CPR queries to the terminal.
    # When gum choose has piped stdin, termenv can't read the OSC 11 response
    # (it arrives on /dev/tty, not the pipe). The response stays in /dev/tty buffer
    # and is: (1) echoed on screen as garbage, (2) read by bubbletea as phantom input.
    # With echo off, responses are never displayed. _gum_drain_tty removes them
    # from the input buffer before each interactive gum command.
    # gum handles its own raw mode internally; echo is restored by cleanup or on exit.
    stty -echo </dev/tty 2>/dev/null || true
    _GUM_ECHO_OFF=1

    # Accent: cyan (6), text: white (7), bg: default terminal
    export GUM_CHOOSE_CURSOR_FOREGROUND="6"
    export GUM_CHOOSE_HEADER_FOREGROUND="6"
    export GUM_CHOOSE_SELECTED_FOREGROUND="0"
    export GUM_CHOOSE_SELECTED_BACKGROUND="6"
    export GUM_CHOOSE_UNSELECTED_FOREGROUND="7"
    export GUM_CONFIRM_SELECTED_FOREGROUND="0"
    export GUM_CONFIRM_SELECTED_BACKGROUND="6"
    export GUM_CONFIRM_UNSELECTED_FOREGROUND="7"
    export GUM_INPUT_CURSOR_FOREGROUND="6"
    export GUM_INPUT_PROMPT_FOREGROUND="6"
    export GUM_INPUT_WIDTH="60"
}

# Detect dialog backend
_detect_dialog_backend() {
    if _try_gum_backend; then
        DIALOG_CMD="gum"
    elif command -v dialog &>/dev/null; then
        DIALOG_CMD="dialog"
    elif command -v whiptail &>/dev/null; then
        DIALOG_CMD="whiptail"
    else
        die "Neither gum, dialog, nor whiptail found. Install one of them."
    fi
    export DIALOG_CMD
}

# Dialog dimensions
readonly DIALOG_HEIGHT=22
readonly DIALOG_WIDTH=76
readonly DIALOG_LIST_HEIGHT=14

# Initialize dialog backend
init_dialog() {
    _detect_dialog_backend
    einfo "Using dialog backend: ${DIALOG_CMD}"

    case "${DIALOG_CMD}" in
        gum)
            _setup_gum_theme
            ;;
        dialog)
            local rc_file="${DATA_DIR}/dialogrc"
            if [[ -f "${rc_file}" ]]; then
                export DIALOGRC="${rc_file}"
            fi
            ;;
    esac
}

# --- Gum helpers ---

# Drain pending terminal responses (OSC 11, CPR) from /dev/tty input buffer.
# gum's termenv/bubbletea query the terminal; when stdin is piped (gum choose),
# responses land on /dev/tty and are read by bubbletea as phantom keystrokes.
# _gum_time_ms — Current time in milliseconds (for phantom ESC detection)
# Uses EPOCHREALTIME (bash 5.0+) for sub-second precision; falls back to SECONDS.
# Phantom ESC arrives in <50ms, real user ESC takes >200ms — 150ms threshold.
_gum_time_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        # EPOCHREALTIME uses locale decimal separator (dot or comma)
        local _rt="${EPOCHREALTIME//,/.}"
        local _s="${_rt%%.*}"
        local _f="${_rt#*.}"
        _f="${_f:0:3}"
        while [[ ${#_f} -lt 3 ]]; do _f+="0"; done
        echo "$(( _s * 1000 + 10#${_f} ))"
    else
        echo "$(( SECONDS * 1000 ))"
    fi
}

# Phantom ESC threshold in milliseconds (150ms: phantom <50ms, real user >200ms)
_GUM_PHANTOM_ESC_MS=150

# With echo off (set in _setup_gum_theme), responses don't display on screen,
# but they still sit in the input buffer — this function removes them.
_gum_drain_tty() {
    # Flush pending terminal responses (CPR, OSC 11) from /dev/tty input buffer.
    # gum/bubbletea sends cursor position queries; responses linger in the buffer
    # and get picked up by the next gum command as phantom keystrokes/pre-fill text.
    # Two rounds: responses may arrive with variable latency (especially after
    # complex gum commands like checklist with many items).
    local _round
    for _round in 1 2; do
        sleep 0.15
        dd if=/dev/tty of=/dev/null bs=4096 count=100 iflag=nonblock 2>/dev/null || true
    done
    while read -t 0.1 -rsn 1 _ </dev/tty 2>/dev/null; do :; done
}

# Backtitle bar at top of screen — matches dialog's backtitle
_gum_backtitle() {
    gum style --foreground 6 --bold --width "${DIALOG_WIDTH}" \
        "${INSTALLER_NAME} v${INSTALLER_VERSION}"
    echo ""
}

# Styled box with rounded border and cyan header — matches dialogrc theme
_gum_style_box() {
    local title="$1" text="$2"
    local body
    body=$(echo -e "${text}")
    local content
    content=$(printf '%s\n\n%s' "$(gum style --bold --foreground 6 "${title}")" "${body}")
    gum style --border rounded --border-foreground 6 \
        --padding "1 2" --width "${DIALOG_WIDTH}" \
        "${content}"
}

# --- Primitives ---

# dialog_infobox — Display a message without waiting for input (returns immediately)
dialog_infobox() {
    local title="$1" text="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle
        _gum_style_box "${title}" "${text}"
        return 0
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --infobox "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_msgbox — Display a message box
dialog_msgbox() {
    local title="$1" text="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle
        _gum_style_box "${title}" "${text}"
        echo ""
        gum style --foreground 8 --italic "  Press any key to continue (ESC to go back)..."
        _gum_drain_tty
        # Read keypress, filtering out terminal escape responses (OSC 11, CPR)
        while true; do
            local _key=""
            read -rsn1 _key </dev/tty
            if [[ "${_key}" == $'\e' ]]; then
                # Check if more bytes follow (= escape sequence, not standalone ESC)
                local _seq=""
                read -rsn20 -t 0.05 _seq </dev/tty 2>/dev/null || true
                if [[ -z "${_seq}" ]]; then
                    # Standalone ESC — user pressed ESC
                    return 1
                fi
                # Terminal response (e.g. ]11;rgb:... or [3;1R) — ignore, retry
                continue
            fi
            # Regular key — continue
            return 0
        done
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --msgbox "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_yesno — Ask yes/no question. Returns 0=yes, 1=no
dialog_yesno() {
    local title="$1" text="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        local _gum_rc=0 _gum_attempt _choice
        for _gum_attempt in 1 2 3; do
            printf '\033[H\033[2J' >/dev/tty
            _gum_backtitle
            _gum_style_box "${title}" "${text}"
            echo ""
            _gum_drain_tty
            local _t0; _t0=$(_gum_time_ms)
            _gum_rc=0
            _choice=$(printf 'Yes\nNo\n' | gum choose \
                --cursor "▸ " --cursor.foreground 6 \
                --selected.foreground 0 --selected.background 6 \
                --no-show-help \
                ) || _gum_rc=$?
            if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} && ${_gum_attempt} -lt 3 ]]; then
                # Exited in <=1s — likely phantom ESC from terminal response
                continue
            fi
            break
        done
        if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} ]]; then
            # All retries exhausted by phantom ESC — fallback to plain prompt
            _gum_drain_tty
            stty echo </dev/tty 2>/dev/null || true
            local _key=""
            while true; do
                printf '  [Y]es / [N]o: ' >/dev/tty
                read -rsn1 _key </dev/tty
                echo "" >/dev/tty
                case "${_key}" in
                    [Yy]) stty -echo </dev/tty 2>/dev/null || true; return 0 ;;
                    [Nn]|$'\e'|"") stty -echo </dev/tty 2>/dev/null || true; return 1 ;;
                esac
            done
        fi
        # ESC/Ctrl+C/abort → return 128 (distinguishable from No=1)
        [[ ${_gum_rc} -ne 0 ]] && return 128
        # Yes=0, No=1
        [[ "${_choice}" == "Yes" ]] && return 0 || return 1
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --yesno "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_inputbox — Get text input. Prints result to stdout.
dialog_inputbox() {
    local title="$1" text="$2" default="${3:-}"
    local result
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle >/dev/tty
        _gum_style_box "${title}" "${text}" >/dev/tty
        echo "" >/dev/tty
        local _gum_rc=0 _gum_attempt
        for _gum_attempt in 1 2 3; do
            _gum_drain_tty
            local _t0; _t0=$(_gum_time_ms)
            _gum_rc=0
            result=$(gum input --value "${default}" --width 60 \
                --prompt.foreground 6 --cursor.foreground 6 \
                </dev/tty) || _gum_rc=$?
            if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} && ${_gum_attempt} -lt 3 ]]; then
                # Phantom ESC from terminal response — drain and retry
                continue
            fi
            break
        done
        if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} ]]; then
            # All retries exhausted by phantom ESC — fallback to plain read
            _gum_drain_tty
            stty echo </dev/tty 2>/dev/null || true
            if [[ -n "${default}" ]]; then
                printf '  [%s]: ' "${default}" >/dev/tty
            else
                printf '  > ' >/dev/tty
            fi
            IFS= read -r result </dev/tty || true
            [[ -z "${result}" ]] && result="${default}"
            stty -echo </dev/tty 2>/dev/null || true
        elif [[ ${_gum_rc} -ne 0 ]]; then
            return ${_gum_rc}
        fi
        echo "${result}"
        return 0
    elif [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --inputbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${default}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --inputbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${default}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_passwordbox — Get password input
dialog_passwordbox() {
    local title="$1" text="$2"
    local result
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle >/dev/tty
        _gum_style_box "${title}" "${text}" >/dev/tty
        echo "" >/dev/tty
        local _gum_rc=0 _gum_attempt
        for _gum_attempt in 1 2 3; do
            _gum_drain_tty
            local _t0; _t0=$(_gum_time_ms)
            _gum_rc=0
            result=$(gum input --password --width 60 \
                --prompt.foreground 6 --cursor.foreground 6 \
                </dev/tty) || _gum_rc=$?
            if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} && ${_gum_attempt} -lt 3 ]]; then
                # Phantom ESC from terminal response — drain and retry
                continue
            fi
            break
        done
        if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} ]]; then
            # All retries exhausted by phantom ESC — fallback to plain read
            _gum_drain_tty
            printf '  Password: ' >/dev/tty
            IFS= read -rs result </dev/tty || true
            echo "" >/dev/tty
        elif [[ ${_gum_rc} -ne 0 ]]; then
            return ${_gum_rc}
        fi
        echo "${result}"
        return 0
    elif [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --insecure --passwordbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --passwordbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_menu — Display a menu. Prints selected tag to stdout.
# Usage: dialog_menu "title" "tag1" "desc1" "tag2" "desc2" ...
dialog_menu() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle >/dev/tty
        # Build display lines "tag — desc" and parallel tag array
        local -a gum_tags=() gum_lines=()
        local i
        for (( i=0; i<${#items[@]}; i+=2 )); do
            gum_tags+=("${items[i]}")
            gum_lines+=("${items[i]} — ${items[i+1]}")
        done
        local header
        header=$(gum style --foreground 6 --bold "  ${title}")
        local _gum_rc=0 _gum_attempt selected_line
        for _gum_attempt in 1 2 3; do
            _gum_drain_tty
            local _t0; _t0=$(_gum_time_ms)
            _gum_rc=0
            selected_line=$(printf '%s\n' "${gum_lines[@]}" | \
                gum choose --header "${header}" \
                    --height "${DIALOG_LIST_HEIGHT}" \
                    --no-show-help \
                    --cursor "▸ " \
                    --cursor.foreground 6 \
                    --selected.foreground 0 --selected.background 6 \
                ) || _gum_rc=$?
            if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} && ${_gum_attempt} -lt 3 ]]; then
                continue
            fi
            break
        done
        if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} ]]; then
            # All retries exhausted — fallback to numbered list
            _gum_drain_tty
            stty echo </dev/tty 2>/dev/null || true
            local k
            for (( k=0; k<${#gum_lines[@]}; k++ )); do
                printf '  %d) %s\n' "$(( k + 1 ))" "${gum_lines[k]}" >/dev/tty
            done
            local _pick=""
            while true; do
                printf '  Select [1-%d]: ' "${#gum_lines[@]}" >/dev/tty
                read -r _pick </dev/tty || true
                if [[ "${_pick}" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#gum_lines[@]} )); then
                    break
                fi
            done
            stty -echo </dev/tty 2>/dev/null || true
            echo "${gum_tags[$(( _pick - 1 ))]}"
            return 0
        fi
        [[ ${_gum_rc} -ne 0 ]] && return ${_gum_rc}
        # Map selected line back to tag
        local j
        for (( j=0; j<${#gum_lines[@]}; j++ )); do
            if [[ "${gum_lines[j]}" == "${selected_line}" ]]; then
                echo "${gum_tags[j]}"
                return 0
            fi
        done
        echo "${selected_line}"
        return 0
    fi

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --menu "Choose an option:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --menu "Choose an option:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_radiolist — Display a radio list. Prints selected tag to stdout.
# Usage: dialog_radiolist "title" "tag1" "desc1" "on/off" "tag2" "desc2" "on/off" ...
dialog_radiolist() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle >/dev/tty
        # Build display lines "tag — desc" and parallel tag array
        local -a gum_tags=() gum_lines=()
        local preselected_line=""
        local i
        for (( i=0; i<${#items[@]}; i+=3 )); do
            gum_tags+=("${items[i]}")
            gum_lines+=("${items[i]} — ${items[i+1]}")
            if [[ "${items[i+2]}" == "on" ]]; then
                preselected_line="${items[i]} — ${items[i+1]}"
            fi
        done
        local header
        header=$(gum style --foreground 6 --bold "  ${title}")
        local -a gum_args=(
            --header "${header}"
            --height "${DIALOG_LIST_HEIGHT}"
            --no-show-help
            --cursor "▸ "
            --cursor.foreground 6
            --selected.foreground 0 --selected.background 6
        )
        if [[ -n "${preselected_line}" ]]; then
            gum_args+=(--selected "${preselected_line}")
        fi
        local _gum_rc=0 _gum_attempt selected_line
        for _gum_attempt in 1 2 3; do
            _gum_drain_tty
            local _t0; _t0=$(_gum_time_ms)
            _gum_rc=0
            selected_line=$(printf '%s\n' "${gum_lines[@]}" | \
                gum choose "${gum_args[@]}") || _gum_rc=$?
            if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} && ${_gum_attempt} -lt 3 ]]; then
                continue
            fi
            break
        done
        if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} ]]; then
            # All retries exhausted — fallback to numbered list
            _gum_drain_tty
            stty echo </dev/tty 2>/dev/null || true
            local k
            for (( k=0; k<${#gum_lines[@]}; k++ )); do
                printf '  %d) %s\n' "$(( k + 1 ))" "${gum_lines[k]}" >/dev/tty
            done
            local _pick=""
            while true; do
                printf '  Select [1-%d]: ' "${#gum_lines[@]}" >/dev/tty
                read -r _pick </dev/tty || true
                if [[ "${_pick}" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#gum_lines[@]} )); then
                    break
                fi
            done
            stty -echo </dev/tty 2>/dev/null || true
            echo "${gum_tags[$(( _pick - 1 ))]}"
            return 0
        fi
        [[ ${_gum_rc} -ne 0 ]] && return ${_gum_rc}
        # Map selected line back to tag
        local j
        for (( j=0; j<${#gum_lines[@]}; j++ )); do
            if [[ "${gum_lines[j]}" == "${selected_line}" ]]; then
                echo "${gum_tags[j]}"
                return 0
            fi
        done
        echo "${selected_line}"
        return 0
    fi

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --radiolist "Select one:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --radiolist "Select one:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_checklist — Display a checklist. Prints selected tags to stdout.
# Usage: dialog_checklist "title" "tag1" "desc1" "on/off" ...
dialog_checklist() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle >/dev/tty
        # Build display lines "tag — desc" and parallel tag array
        local -a gum_tags=() gum_lines=()
        local -a preselected_lines=()
        local i
        for (( i=0; i<${#items[@]}; i+=3 )); do
            gum_tags+=("${items[i]}")
            gum_lines+=("${items[i]} — ${items[i+1]}")
            if [[ "${items[i+2]}" == "on" ]]; then
                preselected_lines+=("${items[i]} — ${items[i+1]}")
            fi
        done
        local header
        header=$(gum style --foreground 6 --bold "  ${title}")
        local -a gum_args=(
            --no-limit
            --header "${header}"
            --height "${DIALOG_LIST_HEIGHT}"
            --no-show-help
            --cursor "▸ "
            --cursor.foreground 6
            --selected.foreground 0 --selected.background 6
        )
        if [[ ${#preselected_lines[@]} -gt 0 ]]; then
            local sel_joined
            sel_joined=$(printf '%s,' "${preselected_lines[@]}")
            sel_joined="${sel_joined%,}"
            gum_args+=(--selected "${sel_joined}")
        fi
        local _gum_rc=0 _gum_attempt selected_output _t0
        for _gum_attempt in 1 2 3; do
            _gum_drain_tty
            _t0=$(_gum_time_ms)
            _gum_rc=0
            selected_output=$(printf '%s\n' "${gum_lines[@]}" | \
                gum choose "${gum_args[@]}") || _gum_rc=$?
            if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} && ${_gum_attempt} -lt 3 ]]; then
                continue
            fi
            break
        done
        if [[ ${_gum_rc} -ne 0 && $(( $(_gum_time_ms) - _t0 )) -le ${_GUM_PHANTOM_ESC_MS} ]]; then
            # All retries exhausted — fallback to numbered multi-select list
            _gum_drain_tty
            stty echo </dev/tty 2>/dev/null || true
            local k
            for (( k=0; k<${#gum_lines[@]}; k++ )); do
                local _mark=" "
                local _m
                for _m in "${preselected_lines[@]}"; do
                    [[ "${_m}" == "${gum_lines[k]}" ]] && _mark="*"
                done
                printf '  %d) [%s] %s\n' "$(( k + 1 ))" "${_mark}" "${gum_lines[k]}" >/dev/tty
            done
            printf '  Enter numbers (comma/space-separated), or Enter for defaults: ' >/dev/tty
            local _picks=""
            read -r _picks </dev/tty || true
            local -a selected_tags=()
            if [[ -z "${_picks}" ]]; then
                # Use defaults (preselected)
                local _m2
                for _m2 in "${preselected_lines[@]}"; do
                    local _j2
                    for (( _j2=0; _j2<${#gum_lines[@]}; _j2++ )); do
                        [[ "${gum_lines[_j2]}" == "${_m2}" ]] && selected_tags+=("${gum_tags[_j2]}")
                    done
                done
            else
                local _num
                for _num in ${_picks//,/ }; do
                    if [[ "${_num}" =~ ^[0-9]+$ ]] && (( _num >= 1 && _num <= ${#gum_lines[@]} )); then
                        selected_tags+=("${gum_tags[$(( _num - 1 ))]}")
                    fi
                done
            fi
            stty -echo </dev/tty 2>/dev/null || true
            echo "${selected_tags[*]}"
            return 0
        fi
        [[ ${_gum_rc} -ne 0 ]] && return ${_gum_rc}
        # Map each selected line back to its tag
        local -a selected_tags=()
        local line j
        while IFS= read -r line; do
            for (( j=0; j<${#gum_lines[@]}; j++ )); do
                if [[ "${gum_lines[j]}" == "${line}" ]]; then
                    selected_tags+=("${gum_tags[j]}")
                    break
                fi
            done
        done <<< "${selected_output}"
        echo "${selected_tags[*]}"
        return 0
    fi

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --checklist "Select items:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --checklist "Select items:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_gauge — Display a progress gauge
# Usage: dialog_gauge "title" "text" <percentage>
# Reads percentage updates from stdin (echo "50" | dialog_gauge ...)
dialog_gauge() {
    local title="$1" text="$2" percent="${3:-0}"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        # Read percentages from stdin, render progress bar in styled box
        local line pct bar_len filled empty bar
        local width=50
        while IFS= read -r line; do
            pct="${line//[!0-9]/}"
            [[ -z "${pct}" ]] && continue
            (( pct > 100 )) && pct=100
            bar_len=$(( width * pct / 100 ))
            filled=$(printf '%*s' "${bar_len}" '' | tr ' ' '█')
            empty=$(printf '%*s' $(( width - bar_len )) '' | tr ' ' '░')
            bar="${filled}${empty} ${pct}%"
            printf '\033[H\033[2J' >/dev/tty
            _gum_backtitle >/dev/tty
            _gum_style_box "${title}" "${text}\n\n${bar}" >/dev/tty
        done
        return 0
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --gauge "${text}" \
        8 "${DIALOG_WIDTH}" "${percent}"
}

# dialog_textbox — Display a text file in a scrollable box
dialog_textbox() {
    local title="$1" file="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle >/dev/tty
        gum style --foreground 6 --bold "  ${title}" >/dev/tty
        echo "" >/dev/tty
        _gum_drain_tty
        gum pager < "${file}"
        return 0
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --textbox "${file}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_prgbox — Run a command and show output in a box
dialog_prgbox() {
    local title="$1"
    shift
    local cmd
    cmd=$(printf '%q ' "$@")
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        # Run command, capture output, show in pager (like whiptail fallback)
        local output
        output=$("$@" 2>&1) || true
        printf '\033[H\033[2J' >/dev/tty
        _gum_backtitle >/dev/tty
        gum style --foreground 6 --bold "  ${title}" >/dev/tty
        echo "" >/dev/tty
        _gum_drain_tty
        echo "${output}" | gum pager
        return 0
    elif [[ "${DIALOG_CMD}" == "dialog" ]]; then
        "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --prgbox "${cmd}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
    else
        # whiptail doesn't have prgbox, fall back to msgbox
        local output
        output=$("$@" 2>&1) || true
        dialog_msgbox "${title}" "${output}"
    fi
}

# --- Wizard navigation ---

# Navigation stack for wizard
declare -a _WIZARD_SCREENS=()
_WIZARD_INDEX=0

# register_wizard_screens — Set the ordered list of screen functions
register_wizard_screens() {
    _WIZARD_SCREENS=("$@")
    _WIZARD_INDEX=0
}

# run_wizard — Execute the wizard, handling back/next/abort navigation
run_wizard() {
    local total=${#_WIZARD_SCREENS[@]}

    if [[ ${total} -eq 0 ]]; then
        die "No wizard screens registered"
    fi

    while (( _WIZARD_INDEX < total )); do
        local screen_func="${_WIZARD_SCREENS[${_WIZARD_INDEX}]}"

        elog "Running wizard screen ${_WIZARD_INDEX}/${total}: ${screen_func}"

        # Clear terminal to prevent flicker between screens
        printf '\033[H\033[2J' >/dev/tty 2>/dev/null || clear 2>/dev/null

        local rc=0
        "${screen_func}" || rc=$?

        case ${rc} in
            "${TUI_NEXT}"|0)
                (( _WIZARD_INDEX++ )) || true

                # Preset skip: after disk_select, jump to summary
                # (disk_select must run — TARGET_DISK/ESP are hardware-specific, not in preset)
                # All other settings (users, packages, desktop) are preserved from preset
                if [[ "${_PRESET_SKIP_TO_USER:-0}" == "1" && "${screen_func}" == "screen_disk_select" ]]; then
                    local skip_idx
                    for (( skip_idx = _WIZARD_INDEX; skip_idx < total; skip_idx++ )); do
                        if [[ "${_WIZARD_SCREENS[${skip_idx}]}" == "screen_summary" ]]; then
                            _WIZARD_INDEX=${skip_idx}
                            einfo "Preset skip: jumping to summary"
                            break
                        fi
                    done
                    unset _PRESET_SKIP_TO_USER
                fi
                ;;
            "${TUI_BACK}"|1)
                if (( _WIZARD_INDEX > 0 )); then
                    (( _WIZARD_INDEX-- )) || true
                else
                    ewarn "Already at first screen"
                fi
                ;;
            "${TUI_ABORT}"|2)
                if dialog_yesno "Abort Installation" \
                    "Are you sure you want to abort the installation?"; then
                    die "Installation aborted by user"
                fi
                ;;
            *)
                eerror "Unknown return code ${rc} from ${screen_func}"
                ;;
        esac
    done

    einfo "Wizard completed"
}

# dialog_nav_menu — Menu with Back/Abort options built-in
# Returns selection via stdout, handles Cancel=back
dialog_nav_menu() {
    local title="$1"
    shift

    local result
    result=$(dialog_menu "${title}" "$@") || {
        # Cancel pressed — treat as back
        return "${TUI_BACK}"
    }
    echo "${result}"
    return "${TUI_NEXT}"
}
