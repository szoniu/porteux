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
