#!/bin/bash
# Kin AI Agent Launcher
# This script runs on boot to start the Raspberry Pi client

set -e

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
WRAPPER_DIR="$SCRIPT_DIR"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
VENV_DIR="$CLIENT_DIR/venv"
GIT_REPO_URL="https://github.com/companionsand/raspberry-pi-client.git"

# Logging
LOG_PREFIX="[agent-launcher]"
log_info() {
    echo "$LOG_PREFIX [INFO] $1"
}

log_error() {
    echo "$LOG_PREFIX [ERROR] $1" >&2
}

log_success() {
    echo "$LOG_PREFIX [SUCCESS] $1"
}

# Load wrapper .env file if it exists (for GIT_BRANCH configuration)
if [ -f "$WRAPPER_DIR/.env" ]; then
    set -a  # Export all variables
    source "$WRAPPER_DIR/.env"
    set +a
fi

# Set Git branch (from .env or default to main)
GIT_BRANCH=${GIT_BRANCH:-"main"}

# Change to wrapper directory
cd "$WRAPPER_DIR"

log_info "Starting Kin AI Agent Launcher..."

# Step 1: Check internet connection (brief check only)
# WiFi setup is now handled in the Python client (main.py)
log_info "Checking internet connection..."
if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
    log_success "Internet connection established"
else
    log_info "No internet connection - main.py will handle WiFi setup if enabled"
fi

# Step 2: Check if git repo exists
if [ ! -d "$CLIENT_DIR" ]; then
    log_error "Repository not found at $CLIENT_DIR"
    log_error "This should not happen - install.sh should have cloned it"
    log_error "Please run install.sh first or check your installation"
    exit 1
else
    log_info "Repository found. Checking for updates..."
    cd "$CLIENT_DIR"
    
    # Try to pull latest changes (gracefully handle failure if no internet)
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        # Stash any local changes (shouldn't be any, but just in case)
        git stash --include-untracked 2>/dev/null || true
        
        # Fetch and pull latest changes
        if git fetch origin "$GIT_BRANCH" 2>/dev/null && git reset --hard "origin/$GIT_BRANCH" 2>/dev/null; then
            log_success "Repository updated to latest commit"
        else
            log_info "Could not update repository (using local version)"
        fi
    else
        log_info "Skipping git pull (no internet - will use local version)"
    fi
    
    cd "$WRAPPER_DIR"
fi

# Step 3: Setup virtual environment
log_info "Setting up Python virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    log_info "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    log_success "Virtual environment created"
else
    log_info "Virtual environment already exists"
fi

# Activate virtual environment
source "$VENV_DIR/bin/activate"
log_success "Virtual environment activated"

# Ensure Python logs are flushed immediately so journald sees them
export PYTHONUNBUFFERED=1

# Step 4: Install/update requirements
log_info "Installing Python requirements..."
cd "$CLIENT_DIR"

if [ -f "requirements.txt" ]; then
    # Try to install requirements (gracefully handle failure if no internet)
    if pip install --upgrade pip -q 2>/dev/null && pip install -r requirements.txt -q 2>/dev/null; then
        log_success "Requirements installed"
    else
        log_info "Could not install/update requirements (using cached versions)"
        log_info "If this is first boot without internet, some packages may be missing"
    fi
else
    log_error "requirements.txt not found in $CLIENT_DIR"
    exit 1
fi

# Step 5: Check if .env file exists
if [ ! -f ".env" ]; then
    log_error ".env file not found in $CLIENT_DIR"
    log_error "Please create a .env file with required configuration"
    log_error "See ../.env.example or README.md for details"
    exit 1
fi

log_success "Configuration file found"

# Step 6: Start device monitor in background (for remote interventions)
log_info "Starting device monitor in background..."
if [ -f "$WRAPPER_DIR/monitor/device_monitor.sh" ]; then
    chmod +x "$WRAPPER_DIR/monitor/device_monitor.sh"
    # Start monitor in background, redirect output to journal via logger
    "$WRAPPER_DIR/monitor/device_monitor.sh" 2>&1 | logger -t device-monitor &
    MONITOR_PID=$!
    log_success "Device monitor started (PID: $MONITOR_PID)"
else
    log_info "Device monitor script not found, skipping..."
fi

# Step 7: Initialize ReSpeaker (if present)
log_info "Initializing ReSpeaker tuning parameters..."
if [ -f "$WRAPPER_DIR/respeaker/respeaker-init.sh" ]; then
    chmod +x "$WRAPPER_DIR/respeaker/respeaker-init.sh"
    if "$WRAPPER_DIR/respeaker/respeaker-init.sh" 2>&1; then
        log_success "ReSpeaker initialized successfully"
    else
        log_info "ReSpeaker initialization failed or not present - continuing anyway"
    fi
else
    log_info "respeaker/respeaker-init.sh not found, skipping ReSpeaker initialization"
fi

# Step 8: Fix WiFi AP conflicts (dnsmasq)
log_info "Checking for WiFi access point conflicts..."

# Check if WiFi setup is enabled
SKIP_WIFI_SETUP=$(grep -E "^SKIP_WIFI_SETUP=" "$CLIENT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' "'"'" || echo "false")
if [ "$SKIP_WIFI_SETUP" != "true" ]; then
    log_info "WiFi setup enabled - checking for dnsmasq conflicts..."
    
    # Check if system dnsmasq is running
    if pgrep -f "^/usr/sbin/dnsmasq" > /dev/null 2>&1; then
        log_info "System dnsmasq detected - configuring to avoid conflicts..."
        
        # Create config to exclude wlan0 if it doesn't exist
        if [ ! -f "/etc/dnsmasq.d/99-no-wlan0.conf" ]; then
            log_info "Creating dnsmasq config to exclude wlan0..."
            echo "# Don't bind to wlan0 - let NetworkManager handle it" | sudo tee /etc/dnsmasq.d/99-no-wlan0.conf > /dev/null
            echo "except-interface=wlan0" | sudo tee -a /etc/dnsmasq.d/99-no-wlan0.conf > /dev/null
            
            # Restart system dnsmasq to apply changes
            sudo systemctl restart dnsmasq 2>/dev/null || true
            log_success "System dnsmasq configured to exclude wlan0"
        else
            log_info "dnsmasq config already exists"
        fi
    fi
    
    # Clean up any lingering NetworkManager dnsmasq processes
    sudo pkill -9 -f "dnsmasq.*NetworkManager" 2>/dev/null || true
    
    # Clean up any existing Kin hotspot connection
    sudo nmcli connection down Kin_Hotspot 2>/dev/null || true
    sudo nmcli connection delete Kin_Hotspot 2>/dev/null || true
    
    # Flush wlan0 IP addresses
    sudo ip addr flush dev wlan0 2>/dev/null || true
    
    # Give NetworkManager a moment to settle
    sleep 2
    
    log_success "WiFi AP pre-flight checks complete"
else
    log_info "WiFi setup disabled - skipping AP conflict checks"
fi

# Step 9: Run the client with idle-time monitoring
log_info "Starting Kin AI client with idle-time monitoring..."
log_info "Will restart after 3 hours of inactivity for updates"
log_info "========================================="

# Activity tracking file
ACTIVITY_FILE="$WRAPPER_DIR/.last_activity"
IDLE_TIMEOUT=10800  # 3 hours in seconds

# Function to check idle time
check_idle_time() {
    if [ ! -f "$ACTIVITY_FILE" ]; then
        return 1  # File doesn't exist, not idle
    fi
    
    local current_time=$(date +%s)
    # Try Linux stat first (more common for Raspberry Pi), then macOS stat
    local file_mtime=$(stat -c %Y "$ACTIVITY_FILE" 2>/dev/null || stat -f %m "$ACTIVITY_FILE" 2>/dev/null)
    
    # Verify we got a valid number
    if ! [[ "$file_mtime" =~ ^[0-9]+$ ]]; then
        return 1  # Invalid mtime, treat as not idle
    fi
    
    local idle_time=$((current_time - file_mtime))
    
    if [ $idle_time -ge $IDLE_TIMEOUT ]; then
        return 0  # Idle timeout reached
    else
        return 1  # Still active
    fi
}

# Run main.py in a loop with idle-time monitoring
while true; do
    log_info "Starting main.py..."
    
    # Initialize activity file
    touch "$ACTIVITY_FILE"
    
    # Start main.py in background so we can monitor it
    python main.py &
    MAIN_PID=$!
    
    log_info "main.py started (PID: $MAIN_PID)"
    
    # Monitor process and idle time
    while kill -0 $MAIN_PID 2>/dev/null; do
        # Check if idle timeout reached
        if check_idle_time; then
            log_info "3 hours of idle time detected, restarting for updates..."
            kill -TERM $MAIN_PID 2>/dev/null || true
            sleep 5
            kill -KILL $MAIN_PID 2>/dev/null || true
            break
        fi
        
        # Check every 60 seconds
        sleep 60
    done
    
    # Wait for process to fully exit
    wait $MAIN_PID 2>/dev/null || true
    exit_code=$?
    
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 143 ] && [ $exit_code -ne 137 ]; then
        # Non-zero exit that's not SIGTERM (143) or SIGKILL (137)
        log_error "main.py exited with code $exit_code, restarting in 5 seconds..."
        sleep 5
    else
        log_info "main.py stopped, restarting..."
        sleep 2
    fi
    
    # Before restarting, clean up WiFi AP resources if needed
    SKIP_WIFI_SETUP=$(grep -E "^SKIP_WIFI_SETUP=" "$CLIENT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d ' "'"'" || echo "false")
    if [ "$SKIP_WIFI_SETUP" != "true" ]; then
        log_info "Cleaning up WiFi AP resources before restart..."
        
        # Clean up any lingering NetworkManager dnsmasq processes
        sudo pkill -9 -f "dnsmasq.*NetworkManager" 2>/dev/null || true
        
        # Clean up any existing Kin hotspot connection
        sudo nmcli connection down Kin_Hotspot 2>/dev/null || true
        sudo nmcli connection delete Kin_Hotspot 2>/dev/null || true
        
        # Flush wlan0 IP addresses
        sudo ip addr flush dev wlan0 2>/dev/null || true
        
        sleep 1
    fi
    
    # Before restarting, pull latest changes from git (if internet available)
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        log_info "Checking for updates before restart..."
        cd "$CLIENT_DIR"
        
        if git fetch origin "$GIT_BRANCH" 2>/dev/null; then
            # Check if there are updates
            LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
            REMOTE=$(git rev-parse "origin/$GIT_BRANCH" 2>/dev/null || echo "")
            
            if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
                log_info "Updates found, pulling latest changes..."
                git reset --hard "origin/$GIT_BRANCH" 2>/dev/null || log_info "Could not apply updates"
                
                # Reinstall requirements in case they changed
                pip install -r requirements.txt -q 2>/dev/null || log_info "Could not update requirements"
                log_success "Updates applied"
            else
                log_info "Already up to date"
            fi
        else
            log_info "Could not check for updates (no internet)"
        fi
    else
        log_info "Skipping update check (no internet)"
    fi
    
    cd "$CLIENT_DIR"
done
