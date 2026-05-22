#!/usr/bin/env bash
# constants.sh — Global constants for the PorteuX installer
source "${LIB_DIR}/protection.sh"

readonly INSTALLER_VERSION="1.0.0"
readonly INSTALLER_NAME="PorteuX TUI Installer"

# Paths (use defaults, allow override from environment)
: "${MOUNTPOINT:=/mnt/porteux}"
: "${LOG_FILE:=/tmp/porteux-installer.log}"
: "${CHECKPOINT_DIR:=/tmp/porteux-installer-checkpoints}"
: "${CHECKPOINT_DIR_SUFFIX:=/tmp/porteux-installer-checkpoints}"
: "${CONFIG_FILE:=/tmp/porteux-installer.conf}"

# PorteuX ISO URLs
readonly PORTEUX_DOWNLOAD_BASE="https://sourceforge.net/projects/porteux/files"
readonly PORTEUX_GITHUB_RELEASES="https://github.com/porteux/porteux/releases"

# Available desktop variants (ISO names)
readonly -a PORTEUX_DESKTOPS=(
    "cinnamon"
    "cosmic"
    "gnome"
    "kde"
    "lxde"
    "lxqt"
    "mate"
    "xfce"
)

# Optional modules available for download
readonly -a PORTEUX_OPTIONAL_MODULES=(
    "05-devel"
    "08-multilanguage"
    "0050-multilib-lite"
)

# PorteuX directory structure on target
readonly PORTEUX_BASE_DIR="porteux"
readonly PORTEUX_MODULES_DIR="${PORTEUX_BASE_DIR}/modules"
readonly PORTEUX_OPTIONAL_DIR="${PORTEUX_BASE_DIR}/optional"
# Persistence: the boot parameter points at the BASE directory (changes=EXIT:/porteux);
# PorteuX itself creates a "changes" subdirectory inside it for the AUFS overlay (see
# upstream porteux.cfg + boot/docs/cheatcodes.txt). PORTEUX_CHANGES_DIR is therefore
# where the installer pre-seeds config (it IS that overlay subdir), while
# PORTEUX_PERSISTENCE_DIR is what goes into the changes= boot parameter.
readonly PORTEUX_PERSISTENCE_DIR="${PORTEUX_BASE_DIR}"
readonly PORTEUX_CHANGES_DIR="${PORTEUX_BASE_DIR}/changes"
readonly PORTEUX_BOOT_DIR="boot"

# Partition sizes (MiB)
readonly ESP_SIZE_MIB=512
readonly SWAP_DEFAULT_SIZE_MIB=4096
readonly PORTEUX_MIN_SIZE_MIB=4096  # 4 GiB minimum for PorteuX

# GPT partition type GUIDs (for sfdisk)
readonly GPT_TYPE_EFI="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
readonly GPT_TYPE_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
readonly GPT_TYPE_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"

# Timeouts
readonly COUNTDOWN_DEFAULT=10
readonly DIALOG_TIMEOUT=0

# Gum (bundled TUI backend)
: "${GUM_VERSION:=0.17.0}"
: "${GUM_CACHE_DIR:=/tmp/porteux-installer-gum}"

# Exit codes for TUI screens
readonly TUI_NEXT=0
readonly TUI_BACK=1
readonly TUI_ABORT=2

# Checkpoint names (single-process — no chroot phases)
readonly -a CHECKPOINTS=(
    "preflight"
    "disks"
    "iso_download"
    "iso_verify"
    "iso_extract"
    "bootloader"
    "persistence"
    "optional_modules"
    "system_config"
    "users"
    "umpc_quirks"
    "finalize"
)

# Configuration variable names (for save/load)
readonly -a CONFIG_VARS=(
    # Disk
    TARGET_DISK
    PARTITION_SCHEME
    FILESYSTEM
    SWAP_TYPE
    SWAP_SIZE_MIB
    ESP_PARTITION
    ESP_REUSE
    ROOT_PARTITION
    SWAP_PARTITION

    # PorteuX-specific
    DESKTOP_VARIANT
    ISO_URL
    BOOT_MODE
    PERSISTENCE_MODE
    PERSISTENCE_SIZE_MIB
    ENABLE_DEVEL_MODULE
    ENABLE_MULTILANG_MODULE
    ENABLE_MULTILIB_MODULE
    NVIDIA_MODULE

    # System
    HOSTNAME
    TIMEZONE
    LOCALE
    KEYMAP

    # User
    ROOT_PASSWORD_HASH
    USERNAME
    USER_PASSWORD_HASH
    USER_GROUPS

    # GPU
    GPU_VENDOR
    GPU_DEVICE_ID
    GPU_DEVICE_NAME
    GPU_DRIVER
    HYBRID_GPU
    IGPU_VENDOR
    IGPU_DEVICE_NAME
    DGPU_VENDOR
    DGPU_DEVICE_NAME

    # Hardware detection
    ASUS_ROG_DETECTED
    WINDOWS_DETECTED
    LINUX_DETECTED
    DETECTED_OSES_SERIALIZED
    BLUETOOTH_DETECTED
    FINGERPRINT_DETECTED
    THUNDERBOLT_DETECTED
    SENSORS_DETECTED
    WEBCAM_DETECTED
    WWAN_DETECTED
    SURFACE_DETECTED
    SURFACE_MODEL

    # UMPC (GPD Pocket/Win, Chuwi MiniBook X)
    UMPC_DETECTED
    UMPC_VENDOR
    UMPC_MODEL
    UMPC_PANEL_ORIENTATION
    UMPC_VIDEO_CONNECTOR
    UMPC_FBCON_ROTATE
    UMPC_ALC287_QUIRK
    UMPC_GPD_FAN

    # Dual-boot
    SHRINK_PARTITION
    SHRINK_PARTITION_FSTYPE
    SHRINK_NEW_SIZE_MIB
)
