#!/usr/bin/env bash
# gpu_database.sh — GPU vendor detection and NVIDIA generation database for Void Linux
source "${LIB_DIR}/protection.sh"

# PCI Vendor IDs
readonly GPU_VENDOR_NVIDIA="10de"
readonly GPU_VENDOR_AMD="1002"
readonly GPU_VENDOR_INTEL="8086"

# NVIDIA device ID ranges by generation (approximate, for kernel-open support detection)
# Turing (RTX 20xx, GTX 16xx) — 1e00-2200 — supports kernel-open
# Ampere (RTX 30xx) — 2200-2700 — supports kernel-open
# Ada Lovelace (RTX 40xx) — 2700-2900 — supports kernel-open (recommended)
# Blackwell (RTX 50xx) — 2900+ — supports kernel-open (recommended)

# nvidia_generation — Determine NVIDIA GPU generation from device ID
# Returns: "turing", "ampere", "ada", "blackwell", "pre-turing", or "unknown"
nvidia_generation() {
    local device_id="$1"
    # Convert hex to decimal for comparison
    local dec_id
    dec_id=$((16#${device_id}))

    if (( dec_id >= 0x2900 )); then
        echo "blackwell"
    elif (( dec_id >= 0x2700 )); then
        echo "ada"
    elif (( dec_id >= 0x2200 )); then
        echo "ampere"
    elif (( dec_id >= 0x1e00 )); then
        echo "turing"
    elif (( dec_id >= 0x1380 )); then
        echo "pre-turing"  # Maxwell/Pascal
    else
        echo "pre-turing"
    fi
}

# nvidia_supports_open_kernel — Check if GPU supports nvidia-open kernel module
# Turing and newer support it, Ada+ it's recommended
nvidia_supports_open_kernel() {
    local device_id="$1"
    local gen
    gen=$(nvidia_generation "${device_id}")
    case "${gen}" in
        turing|ampere|ada|blackwell) return 0 ;;
        *) return 1 ;;
    esac
}

# nvidia_prefers_open_kernel — Check if nvidia-open is recommended (Ada+)
nvidia_prefers_open_kernel() {
    local device_id="$1"
    local gen
    gen=$(nvidia_generation "${device_id}")
    case "${gen}" in
        ada|blackwell) return 0 ;;
        *) return 1 ;;
    esac
}

# get_gpu_recommendation — Get driver recommendation for detected GPU
# Usage: get_gpu_recommendation <vendor_id> <device_id>
# Prints: "driver_package|use_open_kernel(yes/no)"
#
# Void driver packages:
#   nvidia  — proprietary NVIDIA driver (from nonfree repo)
#   mesa-dri — Mesa DRI drivers for AMD/Intel (already in base)
get_gpu_recommendation() {
    local vendor_id="$1" device_id="${2:-0000}"

    case "${vendor_id}" in
        "${GPU_VENDOR_NVIDIA}")
            local use_open="no"
            if nvidia_supports_open_kernel "${device_id}"; then
                use_open="yes"
            fi
            echo "nvidia|${use_open}"
            ;;
        "${GPU_VENDOR_AMD}")
            echo "mesa-dri|no"
            ;;
        "${GPU_VENDOR_INTEL}")
            echo "mesa-dri|no"
            ;;
        *)
            echo "mesa-dri|no"
            ;;
    esac
}

# get_hybrid_gpu_recommendation — Get driver packages for hybrid GPU setups
# Usage: get_hybrid_gpu_recommendation <igpu_vendor> <dgpu_vendor>
# Prints: description of driver combination
get_hybrid_gpu_recommendation() {
    local igpu="$1" dgpu="$2"

    case "${igpu}+${dgpu}" in
        intel+nvidia)   echo "mesa-dri + nvidia" ;;
        amd+nvidia)     echo "mesa-dri + nvidia" ;;
        intel+amd)      echo "mesa-dri" ;;
        amd+amd)        echo "mesa-dri" ;;
        *)              echo "mesa-dri" ;;
    esac
}
