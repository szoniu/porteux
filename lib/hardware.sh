#!/usr/bin/env bash
# hardware.sh — Hardware detection: CPU, GPU, disks, ESP, installed OSes, peripherals
source "${LIB_DIR}/protection.sh"

# --- CPU Detection ---

# detect_cpu — Detect CPU vendor, model name, core count
# No CPU_MARCH detection (Void uses binary packages, not source-compiled)
detect_cpu() {
    CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}') || CPU_VENDOR="unknown"
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}') || CPU_MODEL="unknown"
    CPU_CORES=$(nproc 2>/dev/null) || CPU_CORES=4

    export CPU_VENDOR CPU_MODEL CPU_CORES

    einfo "CPU: ${CPU_MODEL}"
    einfo "CPU cores: ${CPU_CORES}"
}

# --- GPU Detection ---

# _classify_gpu_vendor — Return vendor name from PCI vendor ID
_classify_gpu_vendor() {
    case "$1" in
        "${GPU_VENDOR_NVIDIA}") echo "nvidia" ;;
        "${GPU_VENDOR_AMD}")    echo "amd" ;;
        "${GPU_VENDOR_INTEL}")  echo "intel" ;;
        *)                      echo "unknown" ;;
    esac
}

# detect_gpu — Detect all GPUs, classify iGPU/dGPU, detect hybrid setups
detect_gpu() {
    GPU_VENDOR=""
    GPU_DEVICE_ID=""
    GPU_DEVICE_NAME=""
    GPU_DRIVER=""
    GPU_USE_NVIDIA_OPEN="no"
    HYBRID_GPU="no"
    IGPU_VENDOR=""
    IGPU_DEVICE_NAME=""
    DGPU_VENDOR=""
    DGPU_DEVICE_NAME=""

    # Collect all GPU lines from lspci
    local -a gpu_lines=()
    local line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        gpu_lines+=("${line}")
    done < <(lspci -nn 2>/dev/null | grep -i 'vga\|3d\|display' || true)

    if [[ ${#gpu_lines[@]} -eq 0 ]]; then
        ewarn "No GPU detected via lspci"
        GPU_VENDOR="unknown"
        GPU_DRIVER="mesa-dri"
        export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER GPU_USE_NVIDIA_OPEN
        export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME
        return
    fi

    # Parse each GPU: extract PCI slot, vendor ID, device ID, name
    local -a gpu_slots=() gpu_vendor_ids=() gpu_device_ids=() gpu_names=() gpu_vendors=()
    local gpu_line
    for gpu_line in "${gpu_lines[@]}"; do
        einfo "GPU line: ${gpu_line}"

        # PCI slot is the first field (e.g. "00:02.0" or "01:00.0")
        local pci_slot
        pci_slot=$(echo "${gpu_line}" | awk '{print $1}') || true

        # Extract vendor:device from [xxxx:yyyy]
        local pci_ids
        pci_ids=$(echo "${gpu_line}" | grep -o '\[[0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\]' | tail -1) || true
        local vid did
        vid=$(echo "${pci_ids}" | tr -d '[]' | cut -d: -f1)
        did=$(echo "${pci_ids}" | tr -d '[]' | cut -d: -f2)

        local vname
        vname=$(_classify_gpu_vendor "${vid}")

        local dname
        dname=$(echo "${gpu_line}" | sed 's/.*: //')

        gpu_slots+=("${pci_slot}")
        gpu_vendor_ids+=("${vid}")
        gpu_device_ids+=("${did}")
        gpu_names+=("${dname}")
        gpu_vendors+=("${vname}")
    done

    if [[ ${#gpu_lines[@]} -ge 2 ]]; then
        # Multiple GPUs — classify iGPU vs dGPU
        # Heuristic: PCI slot 00:xx.x = on-die (iGPU), 01:+ = PCIe (dGPU)
        # Also: NVIDIA is always dGPU, Intel is always iGPU
        local igpu_idx=-1 dgpu_idx=-1
        local i
        for (( i=0; i<${#gpu_lines[@]}; i++ )); do
            local slot="${gpu_slots[$i]}"
            local vendor="${gpu_vendors[$i]}"
            local slot_bus="${slot%%:*}"

            # NVIDIA is always discrete
            if [[ "${vendor}" == "nvidia" ]]; then
                dgpu_idx=${i}
                continue
            fi

            # Intel is always integrated
            if [[ "${vendor}" == "intel" ]]; then
                igpu_idx=${i}
                continue
            fi

            # AMD: use PCI slot heuristic — bus 00 = iGPU, otherwise dGPU
            if [[ "${slot_bus}" == "00" ]]; then
                igpu_idx=${i}
            else
                dgpu_idx=${i}
            fi
        done

        # If we found both iGPU and dGPU — hybrid setup
        if [[ ${igpu_idx} -ge 0 && ${dgpu_idx} -ge 0 ]]; then
            HYBRID_GPU="yes"
            IGPU_VENDOR="${gpu_vendors[$igpu_idx]}"
            IGPU_DEVICE_NAME="${gpu_names[$igpu_idx]}"
            DGPU_VENDOR="${gpu_vendors[$dgpu_idx]}"
            DGPU_DEVICE_NAME="${gpu_names[$dgpu_idx]}"

            # Primary GPU_VENDOR = dGPU vendor (controls driver install)
            GPU_VENDOR="${DGPU_VENDOR}"
            GPU_DEVICE_ID="${gpu_device_ids[$dgpu_idx]}"
            GPU_DEVICE_NAME="${DGPU_DEVICE_NAME}"

            # Get driver recommendation from dGPU
            local recommendation
            recommendation=$(get_gpu_recommendation "${gpu_vendor_ids[$dgpu_idx]}" "${gpu_device_ids[$dgpu_idx]}")
            GPU_DRIVER=$(echo "${recommendation}" | cut -d'|' -f1)
            GPU_USE_NVIDIA_OPEN=$(echo "${recommendation}" | cut -d'|' -f2)

            einfo "Hybrid GPU detected: iGPU=${IGPU_DEVICE_NAME} + dGPU=${DGPU_DEVICE_NAME}"
        else
            # Multiple GPUs but can't classify — use first one
            HYBRID_GPU="no"
            GPU_VENDOR="${gpu_vendors[0]}"
            GPU_DEVICE_ID="${gpu_device_ids[0]}"
            GPU_DEVICE_NAME="${gpu_names[0]}"

            local recommendation
            recommendation=$(get_gpu_recommendation "${gpu_vendor_ids[0]}" "${gpu_device_ids[0]}")
            GPU_DRIVER=$(echo "${recommendation}" | cut -d'|' -f1)
            GPU_USE_NVIDIA_OPEN=$(echo "${recommendation}" | cut -d'|' -f2)
        fi
    else
        # Single GPU
        HYBRID_GPU="no"
        GPU_VENDOR="${gpu_vendors[0]}"
        GPU_DEVICE_ID="${gpu_device_ids[0]}"
        GPU_DEVICE_NAME="${gpu_names[0]}"

        local recommendation
        recommendation=$(get_gpu_recommendation "${gpu_vendor_ids[0]}" "${gpu_device_ids[0]}")
        GPU_DRIVER=$(echo "${recommendation}" | cut -d'|' -f1)
        GPU_USE_NVIDIA_OPEN=$(echo "${recommendation}" | cut -d'|' -f2)
    fi

    export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER GPU_USE_NVIDIA_OPEN
    export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME

    einfo "GPU: ${GPU_DEVICE_NAME} (${GPU_VENDOR})"
    einfo "Driver: ${GPU_DRIVER}"
    [[ "${HYBRID_GPU}" == "yes" ]] && einfo "Hybrid: ${IGPU_VENDOR} iGPU + ${DGPU_VENDOR} dGPU"
    [[ "${GPU_VENDOR}" == "nvidia" ]] && einfo "NVIDIA open kernel: ${GPU_USE_NVIDIA_OPEN}"
}

# --- ASUS ROG Detection ---

# detect_asus_rog — Detect ASUS ROG/TUF hardware via DMI
detect_asus_rog() {
    ASUS_ROG_DETECTED=0

    local board_vendor="" product_name=""
    if [[ -f /sys/class/dmi/id/board_vendor ]]; then
        board_vendor=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null) || true
    fi
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || true
    fi

    if [[ "${board_vendor}" == *"ASUSTeK"* ]] && [[ "${product_name}" =~ (ROG|TUF) ]]; then
        ASUS_ROG_DETECTED=1
        einfo "ASUS ROG/TUF hardware detected: ${product_name}"
    fi

    export ASUS_ROG_DETECTED
}

# --- Microsoft Surface Detection ---

# detect_surface — Detect Microsoft Surface hardware via DMI
detect_surface() {
    SURFACE_DETECTED=0
    SURFACE_MODEL=""

    local sys_vendor="" product_name=""
    if [[ -f /sys/class/dmi/id/sys_vendor ]]; then
        sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) || true
    fi
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || true
    fi

    if [[ "${sys_vendor}" == "Microsoft Corporation" ]] && [[ "${product_name}" == Surface* ]]; then
        SURFACE_DETECTED=1
        SURFACE_MODEL="${product_name}"
        einfo "Microsoft Surface detected: ${product_name}"
    fi

    export SURFACE_DETECTED SURFACE_MODEL
}

# --- Peripheral Detection ---

# detect_bluetooth — Detect Bluetooth hardware via /sys/class/bluetooth
detect_bluetooth() {
    BLUETOOTH_DETECTED=0
    if [[ -d /sys/class/bluetooth ]] && ls /sys/class/bluetooth/hci* &>/dev/null 2>&1; then
        BLUETOOTH_DETECTED=1
        einfo "Bluetooth hardware detected"
    fi
    export BLUETOOTH_DETECTED
}

# detect_fingerprint — Detect fingerprint readers via USB vendor IDs
detect_fingerprint() {
    FINGERPRINT_DETECTED=0
    if ! command -v lsusb &>/dev/null; then
        export FINGERPRINT_DETECTED; return 0
    fi
    local lsusb_out
    lsusb_out=$(lsusb 2>/dev/null) || true
    # 06cb=Synaptics, 27c6=Goodix, 147e=AuthenTec, 138a=Validity
    if echo "${lsusb_out}" | grep -qiE '06cb:|27c6:|147e:|138a:'; then
        FINGERPRINT_DETECTED=1
        einfo "Fingerprint reader detected"
    # 04f3=Elan (ambivalent — touchpads and fingerprint — look for "fingerprint" in description)
    elif echo "${lsusb_out}" | grep -qi '04f3:' && echo "${lsusb_out}" | grep -qi 'fingerprint\|fprint'; then
        FINGERPRINT_DETECTED=1
        einfo "Fingerprint reader detected (Elan)"
    fi
    export FINGERPRINT_DETECTED
}

# detect_thunderbolt — Detect Thunderbolt controllers via sysfs or lspci
detect_thunderbolt() {
    THUNDERBOLT_DETECTED=0
    if [[ -d /sys/bus/thunderbolt/devices ]] && ls /sys/bus/thunderbolt/devices/[0-9]* &>/dev/null 2>&1; then
        THUNDERBOLT_DETECTED=1
        einfo "Thunderbolt controller detected"
    elif lspci -nn 2>/dev/null | grep -qi 'thunderbolt\|USB4'; then
        THUNDERBOLT_DETECTED=1
        einfo "Thunderbolt controller detected (lspci)"
    fi
    export THUNDERBOLT_DETECTED
}

# detect_sensors — Detect IIO sensors (accelerometer, gyroscope, ALS)
detect_sensors() {
    SENSORS_DETECTED=0
    if [[ -d /sys/bus/iio/devices ]]; then
        local dev
        for dev in /sys/bus/iio/devices/iio:device*; do
            [[ -d "${dev}" ]] || continue
            local dev_name
            dev_name=$(cat "${dev}/name" 2>/dev/null) || continue
            case "${dev_name}" in
                *accel*|*gyro*|*als*|*light*|*incli*)
                    SENSORS_DETECTED=1; einfo "IIO sensor detected: ${dev_name}"; break ;;
            esac
        done
    fi
    export SENSORS_DETECTED
}

# detect_webcam — Detect webcam via /sys/class/video4linux
detect_webcam() {
    WEBCAM_DETECTED=0
    if [[ -d /sys/class/video4linux ]]; then
        local dev
        for dev in /sys/class/video4linux/video*; do
            [[ -d "${dev}" ]] || continue
            local dev_name
            dev_name=$(cat "${dev}/name" 2>/dev/null) || true
            if [[ -n "${dev_name}" ]]; then
                WEBCAM_DETECTED=1; einfo "Webcam detected: ${dev_name}"; break
            fi
        done
    fi
    export WEBCAM_DETECTED
}

# detect_wwan — Detect WWAN LTE modem via PCI (Intel XMM7360)
detect_wwan() {
    WWAN_DETECTED=0
    if lspci -nnd 8086:7360 2>/dev/null | grep -q .; then
        WWAN_DETECTED=1
        einfo "WWAN modem detected: Intel XMM7360 LTE Advanced"
    fi
    export WWAN_DETECTED
}

# --- Disk Detection ---

# detect_disks — List available block devices
# Populates AVAILABLE_DISKS array: "device|size|model|transport"
detect_disks() {
    declare -ga AVAILABLE_DISKS=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local name size model tran
        read -r name size model tran <<< "${line}"
        AVAILABLE_DISKS+=("${name}|${size}|${model:-unknown}|${tran:-unknown}")
        einfo "Disk: /dev/${name} -- ${size} -- ${model:-unknown} (${tran:-unknown})"
    done < <(lsblk -dno NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v '^loop\|^sr\|^rom\|^ram\|^zram')

    export AVAILABLE_DISKS

    if [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]]; then
        ewarn "No suitable disks detected"
    fi
}

# get_disk_list_for_dialog — Format disks for dialog menu
get_disk_list_for_dialog() {
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        echo "/dev/${name}"
        echo "${size} ${model} (${tran})"
    done
}

# --- ESP / Windows Detection ---

# detect_esp — Find existing EFI System Partitions
# Populates ESP_PARTITIONS array and checks for Windows
detect_esp() {
    declare -ga ESP_PARTITIONS=()
    WINDOWS_DETECTED=0
    WINDOWS_ESP=""

    # Use lsblk to find EFI System Partitions by GPT type GUID
    local part parttype
    while IFS=' ' read -r part parttype; do
        [[ -z "${part}" || -z "${parttype}" ]] && continue
        if [[ "${parttype,,}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
            ESP_PARTITIONS+=("${part}")
            einfo "Found ESP: ${part}"

            # Check for Windows Boot Manager
            local tmp_mount
            tmp_mount=$(mktemp -d /tmp/esp-check-XXXXXX)
            if mount -o ro "${part}" "${tmp_mount}" 2>/dev/null; then
                if [[ -d "${tmp_mount}/EFI/Microsoft/Boot" ]]; then
                    WINDOWS_DETECTED=1
                    WINDOWS_ESP="${part}"
                    einfo "Windows Boot Manager found on ${part}"
                fi
                umount "${tmp_mount}" 2>/dev/null
            fi
            rmdir "${tmp_mount}" 2>/dev/null || true
        fi
    done < <(lsblk -lno PATH,PARTTYPE 2>/dev/null)

    export ESP_PARTITIONS WINDOWS_DETECTED WINDOWS_ESP
}

# --- Installed OS Detection ---

# detect_installed_oses — Scan partitions for installed operating systems
# Populates DETECTED_OSES associative array: partition -> OS name
detect_installed_oses() {
    declare -gA DETECTED_OSES=()
    LINUX_DETECTED=0

    einfo "Scanning for installed operating systems..."

    local part fstype
    while IFS=' ' read -r part fstype; do
        [[ -z "${part}" || -z "${fstype}" ]] && continue

        # Skip ESP partitions
        local esp
        for esp in "${ESP_PARTITIONS[@]}"; do
            [[ "${part}" == "${esp}" ]] && continue 2
        done

        case "${fstype}" in
            ext4|xfs)
                _detect_linux_on_partition "${part}" "${fstype}" ""
                ;;
            btrfs)
                _detect_linux_on_partition "${part}" "${fstype}" ""
                if [[ -z "${DETECTED_OSES[${part}]:-}" ]]; then
                    # btrfs fallback: try subvol=@  (openSUSE, Ubuntu)
                    _detect_linux_on_partition "${part}" "${fstype}" "@"
                fi
                ;;
            ntfs)
                _detect_ntfs_on_partition "${part}"
                ;;
        esac
    done < <(lsblk -lno PATH,FSTYPE 2>/dev/null | awk '$2 != "" {print}')

    export LINUX_DETECTED DETECTED_OSES

    # Log results
    if [[ ${#DETECTED_OSES[@]} -gt 0 ]]; then
        local p
        for p in "${!DETECTED_OSES[@]}"; do
            einfo "Detected OS: ${p} -> ${DETECTED_OSES[${p}]}"
        done
    else
        einfo "No other operating systems detected"
    fi

    serialize_detected_oses
}

# _detect_linux_on_partition — Try to find /etc/os-release on a Linux partition
# Args: partition fstype [subvol]
_detect_linux_on_partition() {
    local part="$1" fstype="$2" subvol="${3:-}"

    # Check if already mounted
    local existing_mount
    existing_mount=$(findmnt -n -o TARGET "${part}" 2>/dev/null | head -1) || true

    local tmp_mount="" needs_umount=0
    if [[ -n "${existing_mount}" ]]; then
        tmp_mount="${existing_mount}"
    else
        tmp_mount="/tmp/os-detect-$$"
        mkdir -p "${tmp_mount}"

        local mount_opts="-o ro"
        [[ -n "${subvol}" ]] && mount_opts="-o ro,subvol=${subvol}"

        if ! mount ${mount_opts} "${part}" "${tmp_mount}" 2>/dev/null; then
            rmdir "${tmp_mount}" 2>/dev/null || true
            return
        fi
        needs_umount=1
    fi

    if [[ -f "${tmp_mount}/etc/os-release" ]]; then
        local pretty_name
        pretty_name=$(sed -n 's/^PRETTY_NAME="\?\([^"]*\)"\?$/\1/p' "${tmp_mount}/etc/os-release" | head -1) || true
        if [[ -n "${pretty_name}" ]]; then
            DETECTED_OSES["${part}"]="${pretty_name}"
            LINUX_DETECTED=1
        fi
    fi

    if [[ "${needs_umount}" -eq 1 ]]; then
        umount "${tmp_mount}" 2>/dev/null || true
        rmdir "${tmp_mount}" 2>/dev/null || true
    fi
}

# _detect_ntfs_on_partition — Check if NTFS partition is a Windows system drive
_detect_ntfs_on_partition() {
    local part="$1"

    local existing_mount
    existing_mount=$(findmnt -n -o TARGET "${part}" 2>/dev/null | head -1) || true

    local tmp_mount="" needs_umount=0
    if [[ -n "${existing_mount}" ]]; then
        tmp_mount="${existing_mount}"
    else
        tmp_mount="/tmp/os-detect-$$"
        mkdir -p "${tmp_mount}"

        if ! mount -o ro "${part}" "${tmp_mount}" 2>/dev/null; then
            rmdir "${tmp_mount}" 2>/dev/null || true
            return
        fi
        needs_umount=1
    fi

    if [[ -d "${tmp_mount}/Windows/System32" ]]; then
        DETECTED_OSES["${part}"]="Windows (system)"
        WINDOWS_DETECTED=1
        export WINDOWS_DETECTED
    fi

    if [[ "${needs_umount}" -eq 1 ]]; then
        umount "${tmp_mount}" 2>/dev/null || true
        rmdir "${tmp_mount}" 2>/dev/null || true
    fi
}

# serialize_detected_oses — DETECTED_OSES assoc array -> serialized string
# Format: "/dev/sda1=Windows|/dev/sda3=openSUSE Tumbleweed"
serialize_detected_oses() {
    local result="" part
    for part in "${!DETECTED_OSES[@]}"; do
        local name="${DETECTED_OSES[${part}]}"
        # Sanitize: replace | and = in OS names with -
        name="${name//|/-}"
        name="${name//=/-}"
        [[ -n "${result}" ]] && result+="|"
        result+="${part}=${name}"
    done
    DETECTED_OSES_SERIALIZED="${result}"
    export DETECTED_OSES_SERIALIZED
}

# deserialize_detected_oses — Serialized string -> DETECTED_OSES assoc array
# Restores WINDOWS_DETECTED and LINUX_DETECTED flags
deserialize_detected_oses() {
    declare -gA DETECTED_OSES=()
    WINDOWS_DETECTED="${WINDOWS_DETECTED:-0}"
    LINUX_DETECTED="${LINUX_DETECTED:-0}"

    local serialized="${DETECTED_OSES_SERIALIZED:-}"
    [[ -z "${serialized}" ]] && return 0

    local IFS='|'
    local entry
    for entry in ${serialized}; do
        local part="${entry%%=*}"
        local name="${entry#*=}"
        [[ -z "${part}" || -z "${name}" ]] && continue
        DETECTED_OSES["${part}"]="${name}"

        # Restore flags
        if [[ "${name}" == *"Windows"* ]]; then
            WINDOWS_DETECTED=1
        else
            LINUX_DETECTED=1
        fi
    done

    export DETECTED_OSES WINDOWS_DETECTED LINUX_DETECTED
}

# --- Full Detection ---

# detect_all_hardware — Run all hardware detection
detect_all_hardware() {
    einfo "=== Hardware Detection ==="
    detect_cpu
    detect_gpu
    detect_asus_rog
    detect_surface
    detect_bluetooth
    detect_fingerprint
    detect_thunderbolt
    detect_sensors
    detect_webcam
    detect_wwan
    detect_disks
    detect_esp
    detect_installed_oses
    einfo "=== Hardware Detection Complete ==="
}

# get_hardware_summary — Format hardware info for display
get_hardware_summary() {
    local summary=""
    summary+="CPU: ${CPU_MODEL:-unknown}\n"
    summary+="  Cores: ${CPU_CORES:-?}\n"
    summary+="\n"
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        summary+="GPU: Hybrid (iGPU + dGPU)\n"
        summary+="  iGPU: ${IGPU_DEVICE_NAME:-unknown} (${IGPU_VENDOR:-unknown})\n"
        summary+="  dGPU: ${DGPU_DEVICE_NAME:-unknown} (${DGPU_VENDOR:-unknown})\n"
        summary+="  PRIME render offload: available\n"
    else
        summary+="GPU: ${GPU_DEVICE_NAME:-unknown}\n"
        summary+="  Vendor: ${GPU_VENDOR:-unknown}\n"
    fi
    summary+="  Driver: ${GPU_DRIVER:-none}\n"
    [[ "${GPU_VENDOR:-}" == "nvidia" ]] && summary+="  Open kernel: ${GPU_USE_NVIDIA_OPEN:-no}\n"
    [[ "${ASUS_ROG_DETECTED:-0}" == "1" ]] && summary+="  ASUS ROG/TUF: detected\n"
    [[ "${SURFACE_DETECTED:-0}" == "1" ]] && summary+="  Microsoft Surface: ${SURFACE_MODEL:-detected}\n"
    [[ "${BLUETOOTH_DETECTED:-0}" == "1" ]] && summary+="  Bluetooth: detected\n"
    [[ "${FINGERPRINT_DETECTED:-0}" == "1" ]] && summary+="  Fingerprint reader: detected\n"
    [[ "${THUNDERBOLT_DETECTED:-0}" == "1" ]] && summary+="  Thunderbolt: detected\n"
    [[ "${SENSORS_DETECTED:-0}" == "1" ]] && summary+="  IIO sensors: detected (2-in-1)\n"
    [[ "${WEBCAM_DETECTED:-0}" == "1" ]] && summary+="  Webcam: detected\n"
    [[ "${WWAN_DETECTED:-0}" == "1" ]] && summary+="  WWAN LTE: Intel XMM7360 detected\n"
    summary+="\n"
    summary+="Disks:\n"
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        summary+="  /dev/${name}: ${size} ${model} (${tran})\n"
    done
    summary+="\n"
    if [[ ${#ESP_PARTITIONS[@]} -gt 0 ]]; then
        summary+="ESP partitions: ${ESP_PARTITIONS[*]}\n"
    fi
    summary+="\n"
    if [[ ${#DETECTED_OSES[@]} -gt 0 ]]; then
        summary+="Detected operating systems:\n"
        local p
        for p in "${!DETECTED_OSES[@]}"; do
            summary+="  ${p}: ${DETECTED_OSES[${p}]}\n"
        done
    else
        summary+="Detected operating systems: none\n"
    fi
    echo -e "${summary}"
}
