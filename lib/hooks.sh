#!/usr/bin/env bash
# hooks.sh — Hook system: maybe_exec 'before_X' / 'after_X'
source "${LIB_DIR}/protection.sh"

# Hooks directory
HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/hooks}"

# maybe_exec — Execute a hook if it exists
# Usage: maybe_exec 'before_install'
# Looks for: hooks/before_install.sh or hooks/before_install/
maybe_exec() {
    local hook_name="$1"
    local hook_file="${HOOKS_DIR}/${hook_name}.sh"
    local hook_dir="${HOOKS_DIR}/${hook_name}"

    # Single file hook
    if [[ -f "${hook_file}" && -x "${hook_file}" ]]; then
        einfo "Running hook: ${hook_name}"
        if ! "${hook_file}"; then
            ewarn "Hook failed: ${hook_name} (continuing)"
        fi
        return 0
    fi

    # Directory of hooks (executed in sorted order)
    if [[ -d "${hook_dir}" ]]; then
        local f
        for f in "${hook_dir}"/*.sh; do
            [[ -f "${f}" && -x "${f}" ]] || continue
            einfo "Running hook: ${hook_name}/$(basename "${f}")"
            if ! "${f}"; then
                ewarn "Hook failed: ${hook_name}/$(basename "${f}") (continuing)"
            fi
        done
        return 0
    fi

    # No hook found — that's fine
    return 0
}
