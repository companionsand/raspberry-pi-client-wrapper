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

# Step 1: Check internet connection
log_info "Checking internet connection..."
max_retries=30
retry_count=0

while ! ping -c 1 -W 2 8.8.8.8 &> /dev/null; do
    retry_count=$((retry_count + 1))
    if [ $retry_count -ge $max_retries ]; then
        log_error "No internet connection after $max_retries attempts. Exiting."
        exit 1
    fi
    log_info "Waiting for internet connection... (attempt $retry_count/$max_retries)"
    sleep 2
done

log_success "Internet connection established"

# Step 2: Check if git repo exists
if [ ! -d "$CLIENT_DIR" ]; then
    log_info "Repository not found. Cloning from $GIT_REPO_URL..."
    git clone -b "$GIT_BRANCH" "$GIT_REPO_URL" "$CLIENT_DIR"
    log_success "Repository cloned successfully"
else
    log_info "Repository found. Pulling latest changes..."
    cd "$CLIENT_DIR"
    
    # Stash any local changes (shouldn't be any, but just in case)
    git stash --include-untracked 2>/dev/null || true
    
    # Fetch and pull latest changes
    git fetch origin "$GIT_BRANCH"
    git reset --hard "origin/$GIT_BRANCH"
    
    cd "$WRAPPER_DIR"
    log_success "Repository updated to latest commit"
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
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
    log_success "Requirements installed"
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

# Step 6: Run the client with idle-time monitoring
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
    
    # Before restarting, pull latest changes from git
    log_info "Checking for updates before restart..."
    cd "$CLIENT_DIR"
    git fetch origin "$GIT_BRANCH" 2>/dev/null || true
    
    # Check if there are updates
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/$GIT_BRANCH")
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        log_info "Updates found, pulling latest changes..."
        git reset --hard "origin/$GIT_BRANCH"
        
        # Reinstall requirements in case they changed
        pip install -r requirements.txt -q
        log_success "Updates applied"
    else
        log_info "Already up to date"
    fi
    
    cd "$CLIENT_DIR"
done
