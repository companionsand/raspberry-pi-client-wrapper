#!/bin/bash
# Kin AI Agent Launcher
# This script runs on boot to start the Raspberry Pi client

set -e

# Configuration
WRAPPER_DIR="$HOME/raspberry-pi-client-wrapper"
CLIENT_DIR="$WRAPPER_DIR/raspberry-pi-client"
VENV_DIR="$CLIENT_DIR/venv"
GIT_REPO_URL="git@github.com:companionsand/raspberry-pi-client.git"
GIT_BRANCH="main"

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
    log_error "See .env.example or README.md for details"
    exit 1
fi

log_success "Configuration file found"

# Step 6: Run the client
log_info "Starting Kin AI client..."
log_info "========================================="

# Run main.py (this will block until the process exits)
exec python main.py

