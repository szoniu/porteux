#!/usr/bin/env bash
# logging.sh — Logging functions with file + stderr output
source "${LIB_DIR}/protection.sh"

# Core log function
_log() {
    local level="$1" color="$2"
    shift 2
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Log to file (no colors)
    echo "[${timestamp}] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null

    # Log to stderr (with colors if terminal)
    if [[ -t 2 ]]; then
        echo -e "${color}[${level}]${RESET} ${msg}" >&2
    else
        echo "[${level}] ${msg}" >&2
    fi
}

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

elog() {
    _log "LOG" "${CYAN}" "$@"
}

einfo() {
    _log "INFO" "${GREEN}" "$@"
}

ewarn() {
    _log "WARN" "${YELLOW}" "$@"
}

eerror() {
    _log "ERROR" "${RED}" "$@"
}

# die — print error and exit
die() {
    eerror "$@"
    exit 1
}

# die_trace — print error with call stack and exit
die_trace() {
    local msg="$1"
    eerror "${msg}"
    eerror "--- Call stack ---"
    local i
    for ((i = 1; i < ${#BASH_SOURCE[@]}; i++)); do
        eerror "  ${BASH_SOURCE[$i]}:${BASH_LINENO[$((i - 1))]} in ${FUNCNAME[$i]:-main}"
    done
    eerror "------------------"
    exit 1
}

# Initialize log file
init_logging() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    : > "${LOG_FILE}"
    einfo "Logging to ${LOG_FILE}"
}

# --- Trwały log + rejestr pominiętych kroków ------------------------------
#
# Do tej pory log żył wyłącznie w /tmp, czyli na tmpfs live ISO. Po awarii,
# reboocie i `--resume` nie było ŻADNEGO logu do post-mortem — dokładnie
# wtedy, kiedy jest najbardziej potrzebny. Gdy tylko dysk docelowy jest
# zamontowany, przenosimy log na niego i dopisujemy dalej.
#
# Tryb APPEND, nie truncate: przy wznowieniu historia poprzednich przebiegów
# musi zostać, bo najciekawsze jest zwykle to, co się działo PRZED awarią.
log_relocate_to_target() {
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    mountpoint -q "${MOUNTPOINT}" 2>/dev/null || return 0

    local target_dir="${MOUNTPOINT}/porteux"
    mkdir -p "${target_dir}" 2>/dev/null || return 0

    local target="${target_dir}/porteux-installer.log"

    # Dotychczasową treść dokładamy na koniec — nie nadpisujemy tego, co
    # zostało po wcześniejszym przebiegu.
    if [[ -f "${LOG_FILE}" && "${LOG_FILE}" != "${target}" ]]; then
        cat "${LOG_FILE}" >> "${target}" 2>/dev/null || true
    fi

    LOG_FILE="${target}"
    SKIPPED_LOG="${target_dir}/porteux-installer-skipped.log"
    export LOG_FILE SKIPPED_LOG
    einfo "Log przeniesiony na dysk docelowy: ${target} (przetrwa reboot)"
}

# skipped_step_record — zapamiętaj krok, który user pominął w try().
#
# Wybór „continue" w menu recovery połyka błąd, a faza i tak kończy się
# checkpointem — niepełna instalacja wygląda potem na kompletną i nie ma po
# niej śladu poza logiem, którego nikt nie czyta. Rejestr sprawia, że
# pominięte kroki wracają na końcu jako głośne ostrzeżenie.
skipped_step_record() {
    local desc="$1"
    : "${SKIPPED_LOG:=/tmp/porteux-installer-skipped.log}"
    mkdir -p "$(dirname "${SKIPPED_LOG}")" 2>/dev/null || true
    printf '%s\n' "${desc}" >> "${SKIPPED_LOG}" 2>/dev/null || true
}

# skipped_steps_report — wypisz pominięte kroki. Zwraca 1, gdy coś pominięto,
# żeby wywołujący mógł dorzucić to do finalnego komunikatu.
skipped_steps_report() {
    local f="${SKIPPED_LOG:-/tmp/porteux-installer-skipped.log}"
    [[ -s "${f}" ]] || return 0

    local n
    n=$(wc -l < "${f}" 2>/dev/null | tr -d ' ') || n="?"
    ewarn "════════════════════════════════════════════════════════"
    ewarn "UWAGA: ${n} krok(ów) POMINIĘTO podczas instalacji."
    ewarn "System jest zainstalowany, ale NIEKOMPLETNY:"
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && ewarn "  - ${line}"
    done < "${f}"
    ewarn ""
    ewarn "Lista: ${f}"
    ewarn "════════════════════════════════════════════════════════"
    return 1
}
