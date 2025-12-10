#!/bin/bash
# ReSpeaker Initialization Script
# Automatically configures ReSpeaker tuning parameters for optimal AEC performance
# This script runs on every boot before the client starts

set -e

LOG_PREFIX="[respeaker-init]"
log_info() {
    echo "$LOG_PREFIX [INFO] $1"
}

log_error() {
    echo "$LOG_PREFIX [ERROR] $1" >&2
}

log_success() {
    echo "$LOG_PREFIX [SUCCESS] $1"
}

log_info "Initializing ReSpeaker tuning parameters..."

# Find usb_4_mic_array directory (should be in home directory)
USB_MIC_ARRAY_DIR="$HOME/usb_4_mic_array"

# Auto-clone repository if not present
if [ ! -d "$USB_MIC_ARRAY_DIR" ]; then
    log_info "usb_4_mic_array not found, cloning repository..."
    if git clone https://github.com/respeaker/usb_4_mic_array.git "$USB_MIC_ARRAY_DIR" 2>/dev/null; then
        log_success "Repository cloned to $USB_MIC_ARRAY_DIR"
    else
        log_error "Failed to clone usb_4_mic_array repository"
        log_error "Please clone manually: cd ~ && git clone https://github.com/respeaker/usb_4_mic_array.git"
        exit 1
    fi
fi

# Check if tuning.py exists
if [ ! -f "$USB_MIC_ARRAY_DIR/tuning.py" ]; then
    log_error "tuning.py not found in $USB_MIC_ARRAY_DIR"
    exit 1
fi

# Ensure pyusb is installed (required for tuning.py)
if ! python -c "import usb.core" 2>/dev/null; then
    log_info "Installing pyusb dependency..."
    pip install pyusb -q 2>/dev/null || log_info "Could not install pyusb (may already be installed or need sudo)"
fi

cd "$USB_MIC_ARRAY_DIR"

# Configuration parameters - load from file if available, otherwise use environment variables
CONFIG_FILE="$HOME/.respeaker_config.json"

if [ -f "$CONFIG_FILE" ]; then
    log_info "Loading ReSpeaker config from $CONFIG_FILE (fetched from backend)"
    
    # Parse JSON using python3 (available in system python, not venv)
    AGCGAIN_VALUE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('agc_gain', 3.0))" 2>/dev/null || echo "3.0")
    AGCONOFF_VALUE=$(python3 -c "import json; print(int(json.load(open('$CONFIG_FILE')).get('agc_on_off', 0)))" 2>/dev/null || echo "0")
    AECFREEZEONOFF_VALUE=$(python3 -c "import json; print(int(json.load(open('$CONFIG_FILE')).get('aec_freeze_on_off', 0)))" 2>/dev/null || echo "0")
    ECHOONOFF_VALUE=$(python3 -c "import json; print(int(json.load(open('$CONFIG_FILE')).get('echo_on_off', 1)))" 2>/dev/null || echo "1")
    HPFONOFF_VALUE=$(python3 -c "import json; print(int(json.load(open('$CONFIG_FILE')).get('hpf_on_off', 1)))" 2>/dev/null || echo "1")
    STATNOISEONOFF_VALUE=$(python3 -c "import json; print(int(json.load(open('$CONFIG_FILE')).get('stat_noise_on_off', 1)))" 2>/dev/null || echo "1")
    
    log_success "Using backend-provided ReSpeaker configuration"
else
    log_info "No config file found at $CONFIG_FILE"
    log_info "Using environment variables or defaults"
    
    # Fallback to environment variables (for manual override or backward compatibility)
    AGCGAIN_VALUE=${RESPEAKER_AGCGAIN:-3.0}
    AGCONOFF_VALUE=${RESPEAKER_AGCONOFF:-0}
    AECFREEZEONOFF_VALUE=${RESPEAKER_AECFREEZEONOFF:-0}
    ECHOONOFF_VALUE=${RESPEAKER_ECHOONOFF:-1}
    HPFONOFF_VALUE=${RESPEAKER_HPFONOFF:-1}
    STATNOISEONOFF_VALUE=${RESPEAKER_STATNOISEONOFF:-1}
fi

log_info "Applying ReSpeaker configuration:"
log_info "  AGCGAIN: $AGCGAIN_VALUE (microphone gain)"
log_info "  AGCONOFF: $AGCONOFF_VALUE (0=freeze, 1=auto-adjust)"
log_info "  AECFREEZEONOFF: $AECFREEZEONOFF_VALUE (0=AEC adaptation enabled)"
log_info "  ECHOONOFF: $ECHOONOFF_VALUE (1=echo suppression ON)"
log_info "  HPFONOFF: $HPFONOFF_VALUE (1=high-pass filter ON)"
log_info "  STATNOISEONOFF: $STATNOISEONOFF_VALUE (1=stationary noise suppression ON)"

# Apply settings with error handling
apply_setting() {
    local param_name=$1
    local param_value=$2
    
    if sudo python tuning.py "$param_name" "$param_value" &>/dev/null; then
        # Verify it stuck
        local current_value=$(sudo python tuning.py "$param_name" 2>/dev/null | tail -1 | tr -d '\r\n' || echo "ERROR")
        
        # For numeric values, compare with tolerance
        if [[ "$current_value" =~ ^[0-9.]+$ ]] && [[ "$param_value" =~ ^[0-9.]+$ ]]; then
            # Use bc for floating point comparison if available
            if command -v bc &>/dev/null; then
                local diff=$(echo "$current_value - $param_value" | bc | tr -d '-')
                local tolerance=$(echo "scale=2; $param_value * 0.1" | bc)
                if (( $(echo "$diff <= $tolerance" | bc -l) )); then
                    log_success "  $param_name set to $param_value (verified: $current_value)"
                    return 0
                fi
            else
                # Without bc, just do string comparison
                if [ "${current_value%.*}" = "${param_value%.*}" ]; then
                    log_success "  $param_name set to $param_value (verified: $current_value)"
                    return 0
                fi
            fi
        elif [ "$current_value" = "$param_value" ]; then
            log_success "  $param_name set to $param_value (verified)"
            return 0
        fi
        
        log_error "  $param_name verification failed (expected: $param_value, got: $current_value)"
        return 1
    else
        log_error "  Failed to set $param_name"
        return 1
    fi
}

# Apply all settings
SUCCESS=true

# 1. Freeze AGC first (prevent auto-adjustment)
apply_setting "AGCONOFF" "$AGCONOFF_VALUE" || SUCCESS=false

# 2. Set AGC gain to safe level
apply_setting "AGCGAIN" "$AGCGAIN_VALUE" || SUCCESS=false

# 3. Enable AEC adaptation
apply_setting "AECFREEZEONOFF" "$AECFREEZEONOFF_VALUE" || SUCCESS=false

# 4. Enable echo suppression
apply_setting "ECHOONOFF" "$ECHOONOFF_VALUE" || SUCCESS=false

# 5. Enable high-pass filter
apply_setting "HPFONOFF" "$HPFONOFF_VALUE" || SUCCESS=false

# 6. Enable stationary noise suppression
apply_setting "STATNOISEONOFF" "$STATNOISEONOFF_VALUE" || SUCCESS=false

if [ "$SUCCESS" = true ]; then
    log_success "ReSpeaker initialization complete!"
    exit 0
else
    log_error "Some settings failed to apply - check errors above"
    exit 1
fi

