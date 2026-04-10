#!/usr/bin/env bash
# gpu_config.sh — GPU driver configuration
source "${LIB_DIR}/protection.sh"

screen_gpu_config() {
    local detected_vendor="${GPU_VENDOR:-unknown}"
    local detected_name="${GPU_DEVICE_NAME:-Unknown GPU}"

    # If no GPU detected or auto is fine, quick path
    if [[ "${detected_vendor}" == "none" || "${detected_vendor}" == "unknown" ]]; then
        local msg="No dedicated GPU detected or GPU not recognized.\n\n"
        msg+="PorteuX includes open-source mesa drivers by default.\n"
        msg+="No additional GPU configuration needed."
        dialog_msgbox "GPU Configuration" "${msg}"
        export NVIDIA_MODULE="no"
        return ${TUI_NEXT}
    fi

    local msg="Detected GPU: ${detected_name}\n"
    msg+="Vendor: ${detected_vendor}\n"

    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        msg+="\nHybrid GPU detected:\n"
        msg+="  iGPU: ${IGPU_DEVICE_NAME:-?} (${IGPU_VENDOR:-?})\n"
        msg+="  dGPU: ${DGPU_DEVICE_NAME:-?} (${DGPU_VENDOR:-?})\n"
    fi

    case "${detected_vendor}" in
        nvidia)
            msg+="\nNVIDIA GPU detected. PorteuX provides a separate\n"
            msg+="nvidia-driver.xzm module for proprietary drivers.\n"
            msg+="\nWithout it, the open-source 'nvk' driver will be used."

            dialog_msgbox "GPU Configuration" "${msg}"

            if dialog_yesno "NVIDIA Module" \
                "Download NVIDIA proprietary driver module?\n\n(nvidia-driver.xzm — recommended for best performance)"; then
                export NVIDIA_MODULE="yes"
                einfo "NVIDIA driver module will be downloaded"
            else
                export NVIDIA_MODULE="no"
                einfo "Using open-source nvk driver"
            fi
            ;;
        amd)
            msg+="\nAMD GPU detected. PorteuX includes mesa/radv drivers\n"
            msg+="by default. No additional module needed."
            dialog_msgbox "GPU Configuration" "${msg}"
            export NVIDIA_MODULE="no"
            ;;
        intel)
            msg+="\nIntel GPU detected. PorteuX includes mesa/anv drivers\n"
            msg+="by default. No additional module needed."
            dialog_msgbox "GPU Configuration" "${msg}"
            export NVIDIA_MODULE="no"
            ;;
        *)
            dialog_msgbox "GPU Configuration" "${msg}\n\nUsing default mesa drivers."
            export NVIDIA_MODULE="no"
            ;;
    esac

    einfo "GPU config: vendor=${detected_vendor}, nvidia_module=${NVIDIA_MODULE:-no}"
    return ${TUI_NEXT}
}
