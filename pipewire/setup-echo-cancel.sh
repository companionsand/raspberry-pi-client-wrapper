#!/bin/bash
# Setup Echo Cancellation for PipeWire
# This script creates the proper PipeWire configuration for echo cancellation
# Supports auto-detection of default devices

set -e

# Logging functions
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

# Parse command line arguments
AUTO_MODE=false
SOURCE_ID=""
SINK_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --source-id)
            SOURCE_ID="$2"
            shift 2
            ;;
        --sink-id)
            SINK_ID="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--auto] [--source-id ID] [--sink-id ID]"
            exit 1
            ;;
    esac
done

echo "========================================="
echo "  PipeWire Echo Cancellation Setup"
echo "========================================="
echo ""

# Function to get default source
get_default_source() {
    pactl info 2>/dev/null | grep 'Default Source:' | cut -d: -f2 | xargs
}

# Function to get default sink
get_default_sink() {
    pactl info 2>/dev/null | grep 'Default Sink:' | cut -d: -f2 | xargs
}

# Function to verify device exists
verify_device() {
    local device="$1"
    local type="$2"
    
    if [ "$type" = "source" ]; then
        pactl list short sources 2>/dev/null | grep -q "^[0-9]*[[:space:]]$device"
    else
        pactl list short sinks 2>/dev/null | grep -q "^[0-9]*[[:space:]]$device"
    fi
}

# Auto-detect or prompt for devices
if [ -n "$SOURCE_ID" ] && [ -n "$SINK_ID" ]; then
    # IDs provided via command line
    log_info "Using provided device IDs..."
    MIC_DEVICE="$SOURCE_ID"
    SPEAKER_DEVICE="$SINK_ID"
    
elif [ "$AUTO_MODE" = true ]; then
    # Auto-detect defaults
    log_info "Auto-detecting default audio devices..."
    
    DEFAULT_SOURCE=$(get_default_source)
    DEFAULT_SINK=$(get_default_sink)
    
    if [ -z "$DEFAULT_SOURCE" ] || [ -z "$DEFAULT_SINK" ]; then
        log_error "Could not auto-detect default devices"
        log_error "Please run without --auto flag for manual selection"
        exit 1
    fi
    
    # Verify devices exist
    if ! verify_device "$DEFAULT_SOURCE" "source"; then
        log_error "Default source '$DEFAULT_SOURCE' not found"
        exit 1
    fi
    
    if ! verify_device "$DEFAULT_SINK" "sink"; then
        log_error "Default sink '$DEFAULT_SINK' not found"
        exit 1
    fi
    
    MIC_DEVICE="$DEFAULT_SOURCE"
    SPEAKER_DEVICE="$DEFAULT_SINK"
    
    log_success "Auto-detected devices:"
    echo "  Microphone: $MIC_DEVICE"
    echo "  Speaker:    $SPEAKER_DEVICE"
    
else
    # Interactive mode - try auto-detect first
    log_info "Detecting default audio devices..."
    
    DEFAULT_SOURCE=$(get_default_source)
    DEFAULT_SINK=$(get_default_sink)
    
    # Show all available devices
    echo ""
    echo "📋 Available Audio Devices:"
    echo ""
    echo "Sources (Microphones):"
    pactl list short sources | nl -w2 -s'. '
    echo ""
    echo "Sinks (Speakers):"
    pactl list short sinks | nl -w2 -s'. '
    echo ""
    
    if [ -n "$DEFAULT_SOURCE" ] && [ -n "$DEFAULT_SINK" ]; then
        # Defaults detected
        log_info "System defaults detected:"
        echo "  Default Microphone: $DEFAULT_SOURCE"
        echo "  Default Speaker:    $DEFAULT_SINK"
        echo ""
        read -p "Use these defaults? (yes/no) [yes]: " USE_DEFAULTS
        USE_DEFAULTS=${USE_DEFAULTS:-yes}
        
        if [ "$USE_DEFAULTS" = "yes" ]; then
            MIC_DEVICE="$DEFAULT_SOURCE"
            SPEAKER_DEVICE="$DEFAULT_SINK"
        fi
    fi
    
    # If defaults not used or not available, prompt for selection
    if [ -z "$MIC_DEVICE" ]; then
        echo "========================================="
        echo "  Device Selection"
        echo "========================================="
        echo ""
        
        # Get microphone
        while true; do
            read -p "Enter MICROPHONE number or full device name: " MIC_INPUT
            
            # Check if input is a number (selection from list)
            if [[ "$MIC_INPUT" =~ ^[0-9]+$ ]]; then
                MIC_DEVICE=$(pactl list short sources | sed -n "${MIC_INPUT}p" | awk '{print $2}')
                if [ -z "$MIC_DEVICE" ]; then
                    log_error "Invalid selection number"
                    continue
                fi
            else
                MIC_DEVICE="$MIC_INPUT"
            fi
            
            # Verify device exists
            if verify_device "$MIC_DEVICE" "source"; then
                log_success "Microphone: $MIC_DEVICE"
                break
            else
                log_error "Device not found: $MIC_DEVICE"
            fi
        done
        
        # Get speaker
        while true; do
            read -p "Enter SPEAKER number or full device name: " SPEAKER_INPUT
            
            # Check if input is a number
            if [[ "$SPEAKER_INPUT" =~ ^[0-9]+$ ]]; then
                SPEAKER_DEVICE=$(pactl list short sinks | sed -n "${SPEAKER_INPUT}p" | awk '{print $2}')
                if [ -z "$SPEAKER_DEVICE" ]; then
                    log_error "Invalid selection number"
                    continue
                fi
            else
                SPEAKER_DEVICE="$SPEAKER_INPUT"
            fi
            
            # Verify device exists
            if verify_device "$SPEAKER_DEVICE" "sink"; then
                log_success "Speaker: $SPEAKER_DEVICE"
                break
            else
                log_error "Device not found: $SPEAKER_DEVICE"
            fi
        done
        
        # Confirm selection
        echo ""
        log_info "Selected devices:"
        echo "  Microphone: $MIC_DEVICE"
        echo "  Speaker:    $SPEAKER_DEVICE"
        echo ""
        read -p "Is this correct? (yes/no): " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            log_info "Setup cancelled"
            exit 0
        fi
    fi
fi

# Create config directory
log_info "Creating PipeWire configuration directory..."
mkdir -p ~/.config/pipewire/pipewire-pulse.conf.d

# Create echo cancellation config
CONFIG_FILE="$HOME/.config/pipewire/pipewire-pulse.conf.d/20-echo-cancel.conf"

log_info "Creating echo cancellation configuration..."
cat > "$CONFIG_FILE" <<EOF
# PipeWire Echo Cancellation Configuration
# Generated by setup-echo-cancel.sh

pulse.cmd = [
    { cmd = "load-module" args = "module-echo-cancel source_master=$MIC_DEVICE sink_master=$SPEAKER_DEVICE source_name=echo_cancel.mic sink_name=echo_cancel.speaker use_master_format=1 aec_method=webrtc aec_args=\\"analog_gain_control=0\\"" }
]
EOF

log_success "Configuration created at: $CONFIG_FILE"

# Restart PipeWire services
log_info "Restarting PipeWire services to apply configuration..."
systemctl --user restart wireplumber
systemctl --user restart pipewire pipewire-pulse

# Wait for services to initialize
log_info "Waiting for services to initialize..."
sleep 3

# Verify echo cancellation devices
echo ""
log_info "Verifying echo cancellation setup..."

if pactl list short sources | grep -q "echo_cancel.mic"; then
    log_success "✓ Echo cancellation microphone (echo_cancel.mic) created"
else
    log_error "✗ Echo cancellation microphone not found"
    echo "Check logs: journalctl --user -u pipewire-pulse -n 50"
    exit 1
fi

if pactl list short sinks | grep -q "echo_cancel.speaker"; then
    log_success "✓ Echo cancellation speaker (echo_cancel.speaker) created"
else
    log_error "✗ Echo cancellation speaker not found"
    echo "Check logs: journalctl --user -u pipewire-pulse -n 50"
    exit 1
fi

echo ""
echo "========================================="
log_success "Echo Cancellation Setup Complete!"
echo "========================================="
echo ""
echo "Virtual devices created:"
echo "  - echo_cancel.mic (microphone with AEC)"
echo "  - echo_cancel.speaker (speaker with AEC)"
echo ""
echo "These devices are now configured in your client .env file."
echo ""
