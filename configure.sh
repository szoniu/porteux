#!/usr/bin/env bash
# configure.sh — Run only the TUI configuration wizard
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install.sh" --configure "$@"
