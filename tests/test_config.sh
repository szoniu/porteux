#!/usr/bin/env bash
# test_config.sh — Test config save/load round-trip
set -euo pipefail

export _PORTEUX_INSTALLER=1
export DRY_RUN=1
export NON_INTERACTIVE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT_DIR
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/config.sh"

# Test round-trip
TMPFILE=$(mktemp /tmp/porteux-test-config.XXXXXX)
trap 'rm -f "${TMPFILE}"' EXIT

# Set some values
export TARGET_DISK="/dev/sda"
export PARTITION_SCHEME="auto"
export FILESYSTEM="ext4"
export DESKTOP_VARIANT="kde"
export BOOT_MODE="normal"
export PERSISTENCE_MODE="changes"
export HOSTNAME="testbox"
export TIMEZONE="Europe/Warsaw"
export LOCALE="pl_PL.UTF-8"
export KEYMAP="pl"
export USERNAME="testuser"
export ROOT_PASSWORD_HASH='$6$test$hash'
export USER_PASSWORD_HASH='$6$test$hash2'
export USER_GROUPS="wheel,audio,video"
export NVIDIA_MODULE="no"

# Save
config_save "${TMPFILE}"

# Clear
unset TARGET_DISK PARTITION_SCHEME FILESYSTEM DESKTOP_VARIANT
unset BOOT_MODE PERSISTENCE_MODE HOSTNAME TIMEZONE LOCALE KEYMAP

# Load
config_load "${TMPFILE}"

# Verify
errors=0
[[ "${TARGET_DISK}" == "/dev/sda" ]] || { echo "FAIL: TARGET_DISK"; errors=$((errors+1)); }
[[ "${DESKTOP_VARIANT}" == "kde" ]] || { echo "FAIL: DESKTOP_VARIANT"; errors=$((errors+1)); }
[[ "${BOOT_MODE}" == "normal" ]] || { echo "FAIL: BOOT_MODE"; errors=$((errors+1)); }
[[ "${PERSISTENCE_MODE}" == "changes" ]] || { echo "FAIL: PERSISTENCE_MODE"; errors=$((errors+1)); }
[[ "${HOSTNAME}" == "testbox" ]] || { echo "FAIL: HOSTNAME"; errors=$((errors+1)); }

if [[ ${errors} -eq 0 ]]; then
    echo "PASS: Config round-trip test (all variables preserved)"
else
    echo "FAIL: ${errors} variables lost in round-trip"
    exit 1
fi

# Test validation
export DESKTOP_VARIANT="invalid"
if validate_config 2>/dev/null; then
    echo "FAIL: Validation should reject invalid DESKTOP_VARIANT"
    exit 1
else
    echo "PASS: Validation correctly rejects invalid DESKTOP_VARIANT"
fi

echo "All config tests passed."
