#!/usr/bin/env bash
# protection.sh — Guard against direct execution of library modules
# This file must be sourced, never executed directly.

if [[ -z "${_PORTEUX_INSTALLER:-}" ]]; then
    echo "ERROR: This file must be sourced by install.sh, not executed directly." >&2
    exit 1
fi
