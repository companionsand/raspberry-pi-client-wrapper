#!/bin/bash
# Kin AI Raspberry Pi Client Wrapper - Installation Script
# This script sets up all dependencies and services for the Kin AI client

set -e

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
WRAPPER_DIR="$SCRIPT_DIR"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
VENV_DIR="$CLIENT_DIR/venv"
GIT_REPO_URL="https://github.com/companionsand/raspberry-pi-client.git"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${NC}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# Load .env file if it exists
ENV_FILE="$WRAPPER_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    log_info "Loading configuration from .env file..."
    set -a  # Export all variables
    source "$ENV_FILE"
    set +a
    USE_ENV_FILE=true
    log_success "Configuration loaded from .env"
else
    USE_ENV_FILE=false
    log_info "No .env file found - will prompt for configuration"
fi

# Set defaults for optional configuration
GIT_BRANCH=${GIT_BRANCH:-"main"}  # Default to main branch
SKIP_ECHO_CANCEL_SETUP=${SKIP_ECHO_CANCEL_SETUP:-"true"}  # Default to true (skip for ReSpeaker hardware AEC)

# Print header
echo "========================================="
echo "  Kin AI Raspberry Pi Client Installer  "
echo "========================================="
echo ""

# Check if running on Raspberry Pi
log_info "Checking system compatibility..."
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null && ! grep -q "BCM" /proc/cpuinfo 2>/dev/null; then
    log_warning "This doesn't appear to be a Raspberry Pi"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
fi

log_success "System check passed"

# Check internet connectivity
log_info "Checking internet connection..."
if ! ping -c 1 -W 5 8.8.8.8 &> /dev/null; then
    log_error "No internet connection. Please connect to the internet and try again."
    exit 1
fi
log_success "Internet connection verified"

# Update system
log_info "Updating system packages..."
sudo apt update
log_success "Package list updated"

# Step 1: Install system dependencies
log_info "Installing system dependencies..."
log_info "This may take several minutes..."

# Use SKIP_ECHO_CANCEL_SETUP for echo cancellation setup (already has default)
SKIP_ECHO_CANCEL="$SKIP_ECHO_CANCEL_SETUP"

if [ "$SKIP_ECHO_CANCEL" = "true" ]; then
    log_info "SKIP_ECHO_CANCEL_SETUP=true - Installing ALSA-only dependencies (ReSpeaker hardware AEC)..."
    sudo apt install -y \
        python3-pip \
        python3-venv \
        portaudio19-dev \
        python3-pyaudio \
        alsa-utils \
        hostapd \
        dnsmasq \
        git \
        curl \
        wget
    log_success "ALSA-only dependencies installed (PipeWire skipped)"
else
    log_info "Installing dependencies including PipeWire for echo cancellation..."
    sudo apt install -y \
        python3-pip \
        python3-venv \
        portaudio19-dev \
        python3-pyaudio \
        alsa-utils \
        hostapd \
        dnsmasq \
        pipewire \
        wireplumber \
        libspa-0.2-modules \
        git \
        curl \
        wget
    log_success "System dependencies installed (including PipeWire)"
fi

# Step 2: Clone repository
log_info "Setting up repository..."

if [ ! -d "$CLIENT_DIR" ]; then
    log_info "Cloning repository from $GIT_REPO_URL..."
    mkdir -p "$WRAPPER_DIR"
    cd "$WRAPPER_DIR"
    git clone -b "$GIT_BRANCH" "$GIT_REPO_URL" "$CLIENT_DIR"
    log_success "Repository cloned"
else
    log_info "Repository already exists at $CLIENT_DIR"
    cd "$CLIENT_DIR"
    git fetch origin "$GIT_BRANCH"
    git reset --hard "origin/$GIT_BRANCH"
    log_success "Repository updated"
fi

# Ensure WiFi setup script is executable
if [ -f "$WRAPPER_DIR/wifi-setup/setup-wifi.sh" ]; then
    chmod +x "$WRAPPER_DIR/wifi-setup/setup-wifi.sh"
    log_success "WiFi setup script is executable"
fi

# Step 4: Create Python virtual environment
log_info "Creating Python virtual environment..."

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    log_success "Virtual environment created at $VENV_DIR"
else
    log_info "Virtual environment already exists"
fi

# Activate and upgrade pip
source "$VENV_DIR/bin/activate"
pip install --upgrade pip -q
log_success "Python environment ready"

# Step 5: Install Python requirements
log_info "Installing Python requirements..."

if [ -f "$CLIENT_DIR/requirements.txt" ]; then
    pip install -r "$CLIENT_DIR/requirements.txt" -q
    log_success "Python requirements installed"
else
    log_warning "requirements.txt not found, skipping..."
fi

# Step 6: Get configuration (from .env or prompts)
echo ""
echo "========================================="
echo "  Configuration Setup"
echo "========================================="
echo ""

# Check if this is a new device auth setup or legacy
USE_DEVICE_AUTH=false
if [ "$USE_ENV_FILE" = true ] && [ -n "$DEVICE_PRIVATE_KEY" ]; then
    USE_DEVICE_AUTH=true
    log_success "✨ New device authentication detected!"
    log_info "This device uses the simplified authentication system"
fi

if [ "$USE_ENV_FILE" = true ] && [ -n "$DEVICE_ID" ] && [ -n "$OTEL_CENTRAL_COLLECTOR_ENDPOINT" ] && [ -n "$ENV" ]; then
    log_success "Using configuration from .env file"
    DEVICE_ID_INPUT="$DEVICE_ID"
    DEVICE_PRIVATE_KEY_INPUT="$DEVICE_PRIVATE_KEY"
    OTEL_ENDPOINT_INPUT="$OTEL_CENTRAL_COLLECTOR_ENDPOINT"
    ENV_INPUT="$ENV"
    
    if [ "$USE_DEVICE_AUTH" = true ]; then
        echo "  Device ID: $DEVICE_ID_INPUT"
        echo "  Device Private Key: [CONFIGURED]"
        echo "  OTEL Endpoint: $OTEL_ENDPOINT_INPUT"
        echo "  Environment: $ENV_INPUT"
        echo ""
        log_info "✅ All runtime configuration will be fetched from the backend"
    else
        echo "  Device ID: $DEVICE_ID_INPUT"
        echo "  OTEL Endpoint: $OTEL_ENDPOINT_INPUT"
        echo "  Environment: $ENV_INPUT"
    fi
else
    log_info "Please provide the following configuration details:"
    echo ""

    # Prompt for Device ID
    read -p "Enter Device ID: " DEVICE_ID_INPUT
    while [ -z "$DEVICE_ID_INPUT" ]; do
        log_error "Device ID cannot be empty"
        read -p "Enter Device ID: " DEVICE_ID_INPUT
    done

    # Prompt for OTEL Central Collector Endpoint
    read -p "Enter OTEL Central Collector Endpoint (e.g., https://your-collector.onrender.com:4318): " OTEL_ENDPOINT_INPUT
    while [ -z "$OTEL_ENDPOINT_INPUT" ]; do
        log_error "OTEL endpoint cannot be empty"
        read -p "Enter OTEL Central Collector Endpoint: " OTEL_ENDPOINT_INPUT
    done

    # Prompt for Environment
    read -p "Enter Environment (production/staging/development) [production]: " ENV_INPUT
    ENV_INPUT=${ENV_INPUT:-production}

    log_success "Configuration details captured"
fi

# Step 7: Create client .env file
log_info "Creating client .env file..."

if [ ! -f "$CLIENT_DIR/.env" ]; then
    if [ "$USE_DEVICE_AUTH" = true ]; then
        # New device authentication - minimal .env file
        log_info "Creating minimal .env file (new authentication system)..."
        cat > "$CLIENT_DIR/.env" <<EOF
# ============================================================================
# Kin AI Raspberry Pi Client - Device Authentication
# ============================================================================
# This device uses the new authentication system.
# All runtime configuration (API keys, wake word, etc.) is fetched from the
# backend after authentication.

# Device Credentials (REQUIRED)
DEVICE_ID=$DEVICE_ID_INPUT
DEVICE_PRIVATE_KEY=$DEVICE_PRIVATE_KEY_INPUT

# OpenTelemetry (configured via wrapper)
OTEL_ENABLED=true
OTEL_EXPORTER_ENDPOINT=http://localhost:4318
ENV=$ENV_INPUT

# Optional: Override orchestrator URL for testing
# CONVERSATION_ORCHESTRATOR_URL=ws://localhost:8001/ws
EOF
        log_success "✨ Client .env created with device authentication"
        log_info "All API keys and settings will be fetched from the backend"
        
    else
        # Legacy authentication - full .env file
        log_info "Creating .env file (legacy authentication system)..."
        
        # Use values from wrapper .env if available, otherwise use placeholders
        CLIENT_SUPABASE_URL=${SUPABASE_URL:-"https://your-project.supabase.co"}
        CLIENT_SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY:-"your-supabase-anon-key-here"}
        CLIENT_EMAIL=${EMAIL:-"your-email@example.com"}
        CLIENT_PASSWORD=${PASSWORD:-"your-password-here"}
        CLIENT_ORCHESTRATOR_URL=${CONVERSATION_ORCHESTRATOR_URL:-"wss://your-backend.onrender.com/ws"}
        CLIENT_ELEVENLABS_KEY=${ELEVENLABS_API_KEY:-"your-elevenlabs-api-key-here"}
        CLIENT_PICOVOICE_KEY=${PICOVOICE_ACCESS_KEY:-"your-picovoice-access-key-here"}
        CLIENT_WAKE_WORD=${WAKE_WORD:-"porcupine"}
        CLIENT_LED_ENABLED=${LED_ENABLED:-"true"}
        CLIENT_LED_BRIGHTNESS=${LED_BRIGHTNESS:-"60"}
        
        if [ "$SKIP_ECHO_CANCEL" = "true" ]; then
            # ALSA-only mode: No MIC_DEVICE/SPEAKER_DEVICE (auto-detect)
            cat > "$CLIENT_DIR/.env" <<EOF
# Device credentials
DEVICE_ID=$DEVICE_ID_INPUT

# Supabase authentication
SUPABASE_URL=$CLIENT_SUPABASE_URL
SUPABASE_ANON_KEY=$CLIENT_SUPABASE_ANON_KEY
EMAIL=$CLIENT_EMAIL
PASSWORD=$CLIENT_PASSWORD

# Backend
CONVERSATION_ORCHESTRATOR_URL=$CLIENT_ORCHESTRATOR_URL

# ElevenLabs API
ELEVENLABS_API_KEY=$CLIENT_ELEVENLABS_KEY

# Wake word detection
PICOVOICE_ACCESS_KEY=$CLIENT_PICOVOICE_KEY
WAKE_WORD=$CLIENT_WAKE_WORD

# LED Visual Feedback
LED_ENABLED=$CLIENT_LED_ENABLED
LED_BRIGHTNESS=$CLIENT_LED_BRIGHTNESS

# OpenTelemetry
OTEL_ENABLED=true
OTEL_EXPORTER_ENDPOINT=http://localhost:4318
ENV=$ENV_INPUT
EOF
        else
            # PipeWire mode: Include MIC_DEVICE/SPEAKER_DEVICE for echo cancellation
            cat > "$CLIENT_DIR/.env" <<EOF
# Device credentials
DEVICE_ID=$DEVICE_ID_INPUT

# Supabase authentication
SUPABASE_URL=$CLIENT_SUPABASE_URL
SUPABASE_ANON_KEY=$CLIENT_SUPABASE_ANON_KEY
EMAIL=$CLIENT_EMAIL
PASSWORD=$CLIENT_PASSWORD

# Backend
CONVERSATION_ORCHESTRATOR_URL=$CLIENT_ORCHESTRATOR_URL

# ElevenLabs API
ELEVENLABS_API_KEY=$CLIENT_ELEVENLABS_KEY

# Wake word detection
PICOVOICE_ACCESS_KEY=$CLIENT_PICOVOICE_KEY
WAKE_WORD=$CLIENT_WAKE_WORD

# Audio devices (PipeWire echo cancellation)
MIC_DEVICE=echo_cancel.mic
SPEAKER_DEVICE=echo_cancel.speaker

# LED Visual Feedback
LED_ENABLED=$CLIENT_LED_ENABLED
LED_BRIGHTNESS=$CLIENT_LED_BRIGHTNESS

# OpenTelemetry
OTEL_ENABLED=true
OTEL_EXPORTER_ENDPOINT=http://localhost:4318
ENV=$ENV_INPUT
EOF
        fi
        
        if [ "$USE_ENV_FILE" = true ] && [ -n "$SUPABASE_URL" ]; then
            log_success "Client .env created with values from wrapper .env"
        else
            log_success ".env template created at $CLIENT_DIR/.env"
            log_warning "IMPORTANT: Edit $CLIENT_DIR/.env with your actual API keys and credentials!"
        fi
    fi
else
    log_info ".env file already exists, skipping..."
fi

# Step 8: Setup OpenTelemetry Collector
log_info "Setting up OpenTelemetry Collector..."

if [ -f "$WRAPPER_DIR/otel/install-collector.sh" ]; then
    cd "$WRAPPER_DIR/otel"
    chmod +x install-collector.sh
    ./install-collector.sh
    log_success "OpenTelemetry Collector installed"
    
    # Update OTEL configuration with prompted values
    log_info "Configuring OpenTelemetry Collector with provided endpoint..."
    sudo tee /etc/otelcol/otelcol.env > /dev/null <<EOF
# Central collector endpoint
OTEL_CENTRAL_COLLECTOR_ENDPOINT=$OTEL_ENDPOINT_INPUT

# Environment
ENV=$ENV_INPUT

# Device ID
DEVICE_ID=$DEVICE_ID_INPUT
EOF
    log_success "OpenTelemetry Collector configured with endpoint: $OTEL_ENDPOINT_INPUT"

    # Restart collector so the new environment file is loaded immediately
    log_info "Restarting OpenTelemetry Collector to apply configuration..."
    sudo systemctl daemon-reload
    sudo systemctl restart otelcol
    log_success "OpenTelemetry Collector restarted with new configuration"
else
    log_error "OpenTelemetry installer not found at $WRAPPER_DIR/otel/install-collector.sh"
    exit 1
fi

# Step 9: Setup PipeWire and Echo Cancellation
if [ "$SKIP_ECHO_CANCEL" = "true" ]; then
    log_info "Skipping PipeWire and echo cancellation setup (SKIP_ECHO_CANCEL_SETUP=true)"
    log_info "Using ALSA-only mode - devices will be auto-detected by client"
    log_success "Audio setup complete (ALSA direct access)"
else
    log_info "Setting up PipeWire and Echo Cancellation..."

    if systemctl --user is-active --quiet pipewire 2>/dev/null; then
        log_success "PipeWire is running"
    else
        log_warning "PipeWire is not running (audio may not work)"
        log_info "Starting PipeWire services..."
        systemctl --user start pipewire pipewire-pulse wireplumber
        sleep 2
    fi

    log_info "Ensuring PipeWire services are enabled for this user..."
    if systemctl --user is-enabled --quiet pipewire 2>/dev/null && \
       systemctl --user is-enabled --quiet pipewire-pulse 2>/dev/null && \
       systemctl --user is-enabled --quiet wireplumber 2>/dev/null; then
        log_success "PipeWire user services already enabled"
    else
        systemctl --user enable pipewire pipewire-pulse wireplumber >/dev/null
        log_success "PipeWire user services enabled"
    fi

    # Run echo cancellation setup
    echo ""
    # Check if echo cancellation is already configured
    # Verify both the config file exists AND the devices are actually working
    NEED_RECONFIG=false
    if [ -f "$HOME/.config/pipewire/pipewire-pulse.conf.d/20-echo-cancel.conf" ] && \
       pactl list short sources 2>/dev/null | grep -q "echo_cancel.mic" && \
       pactl list short sinks 2>/dev/null | grep -q "echo_cancel.speaker"; then
        log_info "Echo cancellation already configured"
        
        # Test if devices are actually usable
        if pactl get-source-volume echo_cancel.mic &>/dev/null && \
           pactl get-sink-volume echo_cancel.speaker &>/dev/null; then
            log_success "Echo cancellation devices verified and working"
            
            # Ensure .env has the echo cancel devices
            if [ -f "$CLIENT_DIR/.env" ]; then
                if ! grep -q "^MIC_DEVICE=echo_cancel.mic" "$CLIENT_DIR/.env"; then
                    log_info "Updating .env with echo cancellation devices..."
                    if grep -q "^MIC_DEVICE=" "$CLIENT_DIR/.env"; then
                        sed -i 's/^MIC_DEVICE=.*/MIC_DEVICE=echo_cancel.mic/' "$CLIENT_DIR/.env"
                    else
                        echo "MIC_DEVICE=echo_cancel.mic" >> "$CLIENT_DIR/.env"
                    fi
                    if grep -q "^SPEAKER_DEVICE=" "$CLIENT_DIR/.env"; then
                        sed -i 's/^SPEAKER_DEVICE=.*/SPEAKER_DEVICE=echo_cancel.speaker/' "$CLIENT_DIR/.env"
                    else
                        echo "SPEAKER_DEVICE=echo_cancel.speaker" >> "$CLIENT_DIR/.env"
                    fi
                    log_success ".env updated with echo cancellation devices"
                fi
            fi
        else
            log_warning "Echo cancellation devices exist but are not functional"
            log_info "Will reconfigure echo cancellation..."
            
            # Remove existing config to trigger reconfiguration
            rm -f "$HOME/.config/pipewire/pipewire-pulse.conf.d/20-echo-cancel.conf"
            systemctl --user restart pipewire pipewire-pulse wireplumber
            sleep 3
            
            NEED_RECONFIG=true
        fi
    else
        log_info "Echo cancellation not configured or incomplete"
        NEED_RECONFIG=true
    fi

    # Configure echo cancellation if needed
    if [ "$NEED_RECONFIG" = true ]; then
        if [ -f "$WRAPPER_DIR/pipewire/setup-echo-cancel.sh" ]; then
            log_info "Configuring echo cancellation for barge-in capability..."
            cd "$WRAPPER_DIR/pipewire"
            chmod +x setup-echo-cancel.sh
            
            # Try auto-detection first, fall back to interactive if it fails
            if [ "$USE_ENV_FILE" = true ]; then
                # Fully automated mode - try auto-detect
                log_info "Attempting auto-detection of default audio devices..."
                if ./setup-echo-cancel.sh --auto 2>/dev/null; then
                    log_success "Auto-detected and configured echo cancellation"
                else
                    log_warning "Auto-detection failed, falling back to interactive mode"
                    ./setup-echo-cancel.sh
                fi
            else
                # Interactive mode - auto-detect with user confirmation
                ./setup-echo-cancel.sh
            fi
            
            # Check if echo cancellation was set up successfully
            if pactl list short sources | grep -q "echo_cancel.mic" && \
               pactl list short sinks | grep -q "echo_cancel.speaker"; then
                
                # Test if devices are actually usable
                if pactl get-source-volume echo_cancel.mic &>/dev/null && \
                   pactl get-sink-volume echo_cancel.speaker &>/dev/null; then
                    log_success "Echo cancellation configured and verified"
                    
                    # Automatically update .env with echo cancel devices
                    if [ -f "$CLIENT_DIR/.env" ]; then
                        log_info "Updating .env with echo cancellation devices..."
                        # Update MIC_DEVICE if it exists
                        if grep -q "^MIC_DEVICE=" "$CLIENT_DIR/.env"; then
                            sed -i 's/^MIC_DEVICE=.*/MIC_DEVICE=echo_cancel.mic/' "$CLIENT_DIR/.env"
                        else
                            echo "MIC_DEVICE=echo_cancel.mic" >> "$CLIENT_DIR/.env"
                        fi
                        # Update SPEAKER_DEVICE if it exists
                        if grep -q "^SPEAKER_DEVICE=" "$CLIENT_DIR/.env"; then
                            sed -i 's/^SPEAKER_DEVICE=.*/SPEAKER_DEVICE=echo_cancel.speaker/' "$CLIENT_DIR/.env"
                        else
                            echo "SPEAKER_DEVICE=echo_cancel.speaker" >> "$CLIENT_DIR/.env"
                        fi
                        log_success ".env updated with echo cancellation devices"
                    fi
                else
                    log_warning "Echo cancellation devices exist but are not functional"
                    log_info "You may need to configure it manually later"
                fi
            else
                log_warning "Echo cancellation setup incomplete"
                log_info "You may need to configure it manually later"
            fi
        else
            log_error "Echo cancellation setup script not found at $WRAPPER_DIR/pipewire/setup-echo-cancel.sh"
            exit 1
        fi
    fi
fi

# Step 10: Setup agent-launcher systemd service
log_info "Setting up agent-launcher systemd service..."

if [ "$SKIP_ECHO_CANCEL" != "true" ]; then
    # Ensure linger is enabled so the user's PipeWire session stays alive at boot
    log_info "Ensuring systemd linger is enabled for user $USER (required for PipeWire)..."
    if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q "yes"; then
        log_success "Systemd linger already enabled for $USER"
    else
        sudo loginctl enable-linger "$USER"
        log_success "Enabled systemd linger for $USER"
    fi
fi

# Generate environment file used by the systemd service
AGENT_ENV_FILE="/etc/default/agent-launcher"
AGENT_UID="$(id -u "$USER")"
log_info "Writing agent-launcher environment to $AGENT_ENV_FILE..."

if [ "$SKIP_ECHO_CANCEL" = "true" ]; then
    # ALSA-only mode - minimal environment
    sudo tee "$AGENT_ENV_FILE" > /dev/null <<EOF
# Automatically generated by raspberry-pi-client-wrapper/install.sh
# ALSA-only mode (SKIP_ECHO_CANCEL_SETUP=true)
AGENT_USER=$USER
AGENT_UID=$AGENT_UID
EOF
    log_success "Environment file written (ALSA-only mode)"
else
    # PipeWire mode - include PulseAudio environment
    sudo tee "$AGENT_ENV_FILE" > /dev/null <<EOF
# Automatically generated by raspberry-pi-client-wrapper/install.sh
# PipeWire mode (SKIP_ECHO_CANCEL_SETUP=false)
AGENT_USER=$USER
AGENT_UID=$AGENT_UID
XDG_RUNTIME_DIR=/run/user/$AGENT_UID
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$AGENT_UID/bus
PULSE_SERVER=unix:/run/user/$AGENT_UID/pulse/native
PULSE_SOCKET_PATH=/run/user/$AGENT_UID/pulse/native
EOF
    log_success "Environment file written (PipeWire mode)"
fi

if [ -f "$WRAPPER_DIR/services/agent-launcher.service" ]; then
    # Update service file with correct paths and conditionally include ExecStartPre
    if [ "$SKIP_ECHO_CANCEL" = "true" ]; then
        # ALSA-only mode: Remove ExecStartPre (PulseAudio socket check)
        log_info "Generating service file (ALSA-only, no PulseAudio check)..."
        sed "s|/home/pi/raspberry-pi-client-wrapper|$WRAPPER_DIR|g" \
            "$WRAPPER_DIR/services/agent-launcher.service" | \
            sed '/^ExecStartPre=/d' | \
            sudo tee /etc/systemd/system/agent-launcher.service > /dev/null
    else
        # PipeWire mode: Keep ExecStartPre (PulseAudio socket check)
        log_info "Generating service file (PipeWire mode, with PulseAudio check)..."
        sed "s|/home/pi/raspberry-pi-client-wrapper|$WRAPPER_DIR|g" \
            "$WRAPPER_DIR/services/agent-launcher.service" | \
            sudo tee /etc/systemd/system/agent-launcher.service > /dev/null
    fi
    
    # Update User= field if not running as pi
    if [ "$USER" != "pi" ]; then
        sudo sed -i "s/User=pi/User=$USER/g" /etc/systemd/system/agent-launcher.service
    fi
    
    sudo systemctl daemon-reload
    sudo systemctl enable agent-launcher.service
    log_success "Agent launcher service installed and enabled"
else
    log_error "Agent launcher service file not found at $WRAPPER_DIR/services/agent-launcher.service"
    exit 1
fi

# Final checks
log_info "Running final checks..."

# Check if all services are enabled
if systemctl is-enabled --quiet otelcol; then
    log_success "✓ OpenTelemetry Collector service enabled"
else
    log_warning "✗ OpenTelemetry Collector service not enabled"
fi

if systemctl is-enabled --quiet agent-launcher; then
    log_success "✓ Agent launcher service enabled"
else
    log_warning "✗ Agent launcher service not enabled"
fi

# Step 11: Start services and verify installation
echo ""
log_info "Starting services and verifying installation..."

# Start OTEL collector
sudo systemctl start otelcol
sleep 2

# Start agent launcher
sudo systemctl start agent-launcher

# Give services adequate time to initialize and potentially fail
log_info "Waiting 30 seconds for services to stabilize..."
sleep 30

# Verification function
verify_installation() {
    local failed=false
    local error_messages=()
    
    log_info "Verifying installation..."
    
    # Check OTEL collector
    if ! systemctl is-active --quiet otelcol; then
        error_messages+=("OpenTelemetry Collector failed to start")
        failed=true
    else
        log_success "✓ OpenTelemetry Collector running"
    fi
    
    # Check agent-launcher - more thorough check
    LAUNCHER_STATE=$(systemctl is-active agent-launcher 2>/dev/null || echo "inactive")
    LAUNCHER_FAILED=$(systemctl is-failed agent-launcher 2>/dev/null && echo "yes" || echo "no")
    
    if [ "$LAUNCHER_STATE" != "active" ] || [ "$LAUNCHER_FAILED" = "yes" ]; then
        error_messages+=("Agent launcher failed to start or exited with error")
        failed=true
    else
        # Double-check it's actually running and not about to fail
        sleep 5
        LAUNCHER_STATE_RECHECK=$(systemctl is-active agent-launcher 2>/dev/null || echo "inactive")
        if [ "$LAUNCHER_STATE_RECHECK" != "active" ]; then
            error_messages+=("Agent launcher was active but then failed")
            failed=true
        else
            log_success "✓ Agent launcher running"
        fi
    fi
    
    # Check for errors in agent-launcher logs
    if sudo journalctl -u agent-launcher --since "30 seconds ago" -n 50 2>/dev/null | grep -iE "error|traceback|failed" | grep -v "paInvalidSampleRate" &>/dev/null; then
        error_messages+=("Agent launcher has errors in logs")
        failed=true
    else
        log_success "✓ Agent launcher logs clean"
    fi
    
    # Check echo cancellation devices (only if not skipped)
    if [ "$SKIP_ECHO_CANCEL" != "true" ]; then
        if ! pactl list short sources 2>/dev/null | grep -q "echo_cancel.mic"; then
            error_messages+=("Echo cancellation microphone device not found")
            failed=true
        else
            log_success "✓ Echo cancellation microphone available"
        fi
        
        if ! pactl list short sinks 2>/dev/null | grep -q "echo_cancel.speaker"; then
            error_messages+=("Echo cancellation speaker device not found")
            failed=true
        else
            log_success "✓ Echo cancellation speaker available"
        fi
    else
        log_success "✓ ALSA-only mode - skipping echo cancellation device check"
    fi
    
    if [ "$failed" = true ]; then
        echo ""
        log_error "Installation verification failed!"
        echo ""
        echo "Errors detected:"
        for msg in "${error_messages[@]}"; do
            echo "  ✗ $msg"
        done
        echo ""
        
        log_info "Showing recent agent-launcher logs:"
        echo "========================================="
        sudo journalctl -u agent-launcher --since "1 minute ago" -n 100 --no-pager
        echo "========================================="
        echo ""
        
        # Stop the agent-launcher service since it failed
        log_info "Stopping agent-launcher service..."
        sudo systemctl stop agent-launcher 2>/dev/null || true
        log_success "Agent launcher stopped"
        echo ""
        
        log_error "Installation failed. Please review the errors above."
        log_info "You can try running ./install.sh again after fixing the issues."
        log_info "Or run ./uninstall.sh to clean up and start fresh."
        echo ""
        
        return 1
    fi
    
    log_success "Installation verified successfully!"
    return 0
}

# Run verification
if ! verify_installation; then
    exit 1
fi

# Installation complete
echo ""
echo "========================================="
log_success "Installation Complete!"
echo "========================================="
echo ""

if [ "$USE_DEVICE_AUTH" = true ]; then
    # New device authentication system
    echo "✨ Device Authentication System Active"
    echo ""
    echo "✅ Services are now running:"
    echo "   • OpenTelemetry Collector: Active"
    echo "   • Agent Launcher: Active"
    echo ""
    echo "🔐 Authentication:"
    echo "   • Device ID: $DEVICE_ID_INPUT"
    echo "   • Private Key: [CONFIGURED]"
    echo "   • All API keys fetched from backend automatically"
    echo ""
    echo "📝 Next Steps:"
    echo "   1. View logs to monitor the client:"
    echo "      sudo journalctl -u agent-launcher -f"
    echo ""
    echo "   2. Check service status:"
    echo "      sudo systemctl status agent-launcher"
    echo ""
    echo "   3. If device is not paired with a user yet:"
    echo "      Go to admin portal → Device Management"
    echo "      Find your device and pair it with a user"
    echo ""
    echo "💡 Tips:"
    echo "   • API keys are managed centrally in the admin portal"
    echo "   • No need to update .env files on the device"
    echo "   • Device will authenticate automatically on startup"
    
elif [ "$USE_ENV_FILE" = true ]; then
    # Legacy authentication with .env
    echo "✅ Services are now running:"
    echo "   • OpenTelemetry Collector: Active"
    echo "   • Agent Launcher: Active"
    echo ""
    echo "⚠️  Legacy Authentication Mode"
    echo "   Consider reprovisioning this device via the admin portal"
    echo "   for the new simplified authentication system"
    echo ""
    echo "📝 Next Steps:"
    echo "   1. View logs to monitor the client:"
    echo "      sudo journalctl -u agent-launcher -f"
    echo ""
    echo "   2. Check service status:"
    echo "      sudo systemctl status agent-launcher"
    echo ""
    echo "   3. Reconfigure if needed:"
    echo "      Edit $WRAPPER_DIR/.env and run ./install.sh again"
else
    # No .env file - manual configuration needed
    echo "⚠️  IMPORTANT NEXT STEPS:"
    echo ""
    echo "1. Configure the client with API keys and credentials:"
    echo "   nano $CLIENT_DIR/.env"
    echo "   Fill in:"
    echo "     - SUPABASE_URL, SUPABASE_ANON_KEY, EMAIL, PASSWORD"
    echo "     - CONVERSATION_ORCHESTRATOR_URL"
    echo "     - ELEVENLABS_API_KEY"
    echo "     - PICOVOICE_ACCESS_KEY"
    echo ""
    echo "2. Services are already running but need configuration:"
    echo "   After editing .env, restart services:"
    echo "   sudo systemctl restart agent-launcher"
    echo ""
    echo "3. Check service status:"
    echo "   sudo systemctl status agent-launcher"
    echo "   sudo systemctl status otelcol"
    echo ""
    echo "4. View logs:"
    echo "   sudo journalctl -u agent-launcher -f"
fi
echo ""
echo "✅ Configuration Applied:"
echo "   Device ID: $DEVICE_ID_INPUT"
echo "   OTEL Endpoint: $OTEL_ENDPOINT_INPUT"
echo "   Environment: $ENV_INPUT"
echo ""
echo "🔄 Auto-Restart Enabled:"
echo "   If the client crashes or errors, it will automatically restart."
echo "   The system will keep trying to run the client indefinitely."
echo ""
echo "🚀 Boot Behavior:"
echo "   On every boot, the agent launcher will:"
echo "     - Wait for internet connection"
echo "     - Update code from git"
echo "     - Install dependencies"
echo "     - Launch the client"
echo ""
