#!/bin/bash
# Kin AI Raspberry Pi Client Wrapper - Installation Script
# This script sets up all dependencies and services for the Kin AI client

set -e

# Configuration
WRAPPER_DIR="$HOME/raspberry-pi-client-wrapper"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
VENV_DIR="$CLIENT_DIR/venv"
GIT_REPO_URL="https://github.com/companionsand/raspberry-pi-client"
GIT_BRANCH="main"

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

sudo apt install -y \
    python3-pip \
    python3-venv \
    portaudio19-dev \
    python3-pyaudio \
    alsa-utils \
    pipewire \
    wireplumber \
    libspa-0.2-modules \
    git \
    curl \
    wget

log_success "System dependencies installed"

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

# Step 3: Create Python virtual environment
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

# Step 4: Install Python requirements
log_info "Installing Python requirements..."

if [ -f "$CLIENT_DIR/requirements.txt" ]; then
    pip install -r "$CLIENT_DIR/requirements.txt" -q
    log_success "Python requirements installed"
else
    log_warning "requirements.txt not found, skipping..."
fi

# Step 5: Prompt for configuration
echo ""
echo "========================================="
echo "  Configuration Setup"
echo "========================================="
echo ""

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

# Step 6: Create .env template
log_info "Creating .env template..."

if [ ! -f "$CLIENT_DIR/.env" ]; then
    cat > "$CLIENT_DIR/.env" <<EOF
# Device credentials
DEVICE_ID=$DEVICE_ID_INPUT

# Supabase authentication
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-supabase-anon-key-here
EMAIL=your-email@example.com
PASSWORD=your-password-here

# Backend
CONVERSATION_ORCHESTRATOR_URL=ws://your-backend-url:8001/ws

# ElevenLabs API
ELEVENLABS_API_KEY=your-elevenlabs-api-key-here

# Wake word detection
PICOVOICE_ACCESS_KEY=your-picovoice-access-key-here
WAKE_WORD=porcupine

# Audio devices
MIC_DEVICE=echo_cancel.mic
SPEAKER_DEVICE=echo_cancel.speaker

# OpenTelemetry
OTEL_ENABLED=true
OTEL_EXPORTER_ENDPOINT=http://localhost:4318
ENV=$ENV_INPUT
EOF
    log_success ".env template created at $CLIENT_DIR/.env with Device ID: $DEVICE_ID_INPUT"
    log_warning "IMPORTANT: Edit $CLIENT_DIR/.env with your actual API keys and credentials!"
else
    log_info ".env file already exists, skipping..."
fi

# Step 7: Setup OpenTelemetry Collector
log_info "Setting up OpenTelemetry Collector..."

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -f "$SCRIPT_DIR/otel/install-collector.sh" ]; then
    cd "$SCRIPT_DIR/otel"
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
else
    log_error "OpenTelemetry installer not found at $SCRIPT_DIR/otel/install-collector.sh"
    exit 1
fi

# Step 8: Setup PipeWire Echo Cancellation
log_info "Setting up PipeWire Echo Cancellation..."

if [ -f "$SCRIPT_DIR/pipewire/setup-aec.sh" ]; then
    cd "$SCRIPT_DIR/pipewire"
    chmod +x setup-aec.sh
    ./setup-aec.sh
    log_success "PipeWire Echo Cancellation configured"
else
    log_error "PipeWire setup script not found at $SCRIPT_DIR/pipewire/setup-aec.sh"
    exit 1
fi

# Step 9: Setup agent-launcher systemd service
log_info "Setting up agent-launcher systemd service..."

if [ -f "$SCRIPT_DIR/services/agent-launcher.service" ]; then
    # Update service file with correct paths
    sed "s|/home/pi/raspberry-pi-client-wrapper|$WRAPPER_DIR|g" \
        "$SCRIPT_DIR/services/agent-launcher.service" | \
        sudo tee /etc/systemd/system/agent-launcher.service > /dev/null
    
    # Update User= field if not running as pi
    if [ "$USER" != "pi" ]; then
        sudo sed -i "s/User=pi/User=$USER/g" /etc/systemd/system/agent-launcher.service
    fi
    
    sudo systemctl daemon-reload
    sudo systemctl enable agent-launcher.service
    log_success "Agent launcher service installed and enabled"
else
    log_error "Agent launcher service file not found at $SCRIPT_DIR/services/agent-launcher.service"
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

if systemctl --user is-enabled --quiet pipewire-aec 2>/dev/null; then
    log_success "✓ PipeWire AEC service enabled"
else
    log_warning "✗ PipeWire AEC service not enabled"
fi

if systemctl is-enabled --quiet agent-launcher; then
    log_success "✓ Agent launcher service enabled"
else
    log_warning "✗ Agent launcher service not enabled"
fi

# Installation complete
echo ""
echo "========================================="
log_success "Installation Complete!"
echo "========================================="
echo ""
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
echo "2. Restart services to apply configuration:"
echo "   sudo systemctl restart otelcol"
echo "   sudo systemctl restart agent-launcher"
echo ""
echo "3. Check service status:"
echo "   sudo systemctl status agent-launcher"
echo "   sudo systemctl status otelcol"
echo "   systemctl --user status pipewire-aec"
echo ""
echo "4. View logs:"
echo "   sudo journalctl -u agent-launcher -f"
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
log_warning "Don't forget to configure API keys in $CLIENT_DIR/.env!"
echo ""

