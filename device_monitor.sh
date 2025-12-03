#!/bin/bash
# Kin AI Device Monitor
# Background process that sends heartbeats and handles remote interventions
#
# This script:
# - Polls the conversation orchestrator every 10 seconds for interventions
# - Sends logs every 60 seconds
# - Executes interventions (restart, reinstall) when requested

set -e

# Get the actual directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CLIENT_DIR="$SCRIPT_DIR/raspberry-pi-client"

# Logging
LOG_PREFIX="[device-monitor]"
log_info() {
    echo "$LOG_PREFIX [INFO] $1"
}

log_error() {
    echo "$LOG_PREFIX [ERROR] $1" >&2
}

log_success() {
    echo "$LOG_PREFIX [SUCCESS] $1"
}

# Load .env file from wrapper directory
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Load .env file from client directory for additional config
if [ -f "$CLIENT_DIR/.env" ]; then
    set -a
    source "$CLIENT_DIR/.env"
    set +a
fi

# Configuration
DEVICE_ID="${DEVICE_ID:-}"
DEVICE_PRIVATE_KEY="${DEVICE_PRIVATE_KEY:-}"
ORCHESTRATOR_URL="${CONVERSATION_ORCHESTRATOR_URL:-wss://conversation-orchestrator.onrender.com/ws}"

# Convert WebSocket URL to HTTP URL
ORCHESTRATOR_HTTP_URL=$(echo "$ORCHESTRATOR_URL" | sed 's|wss://|https://|' | sed 's|ws://|http://|' | sed 's|/ws$||')

# Timing configuration
POLL_INTERVAL=10       # Poll for interventions every 10 seconds
LOG_INTERVAL=60        # Send logs every 60 seconds
LOG_LINES=100          # Number of log lines to send

# State
JWT_TOKEN=""
JWT_EXPIRES_AT=0
LAST_LOG_SEND=0

# Check required configuration
if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_PRIVATE_KEY" ]; then
    log_error "DEVICE_ID and DEVICE_PRIVATE_KEY must be set in .env"
    exit 1
fi

log_info "Device Monitor starting..."
log_info "Device ID: $DEVICE_ID"
log_info "Orchestrator URL: $ORCHESTRATOR_HTTP_URL"

# Function to authenticate and get JWT token
authenticate() {
    log_info "Authenticating device..."
    
    # Step 1: Request challenge
    CHALLENGE_RESPONSE=$(curl -s -X POST "$ORCHESTRATOR_HTTP_URL/auth/device/challenge" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\": \"$DEVICE_ID\"}" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$CHALLENGE_RESPONSE" ]; then
        log_error "Failed to get challenge"
        return 1
    fi
    
    CHALLENGE=$(echo "$CHALLENGE_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('challenge', ''))" 2>/dev/null)
    TIMESTAMP=$(echo "$CHALLENGE_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('timestamp', ''))" 2>/dev/null)
    
    if [ -z "$CHALLENGE" ] || [ -z "$TIMESTAMP" ]; then
        log_error "Invalid challenge response"
        return 1
    fi
    
    # Step 2: Sign challenge with private key
    MESSAGE="${CHALLENGE}:${TIMESTAMP}"
    
    # Use Python to sign the challenge with Ed25519
    SIGNATURE=$(python3 << EOF
import base64
from cryptography.hazmat.primitives.asymmetric import ed25519

private_key_bytes = base64.b64decode("$DEVICE_PRIVATE_KEY")
private_key = ed25519.Ed25519PrivateKey.from_private_bytes(private_key_bytes)

message = "$MESSAGE".encode()
signature = private_key.sign(message)
print(base64.b64encode(signature).decode())
EOF
    )
    
    if [ -z "$SIGNATURE" ]; then
        log_error "Failed to sign challenge"
        return 1
    fi
    
    # Step 3: Verify and get JWT
    VERIFY_RESPONSE=$(curl -s -X POST "$ORCHESTRATOR_HTTP_URL/auth/device/verify" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\": \"$DEVICE_ID\", \"challenge\": \"$CHALLENGE\", \"signature\": \"$SIGNATURE\"}" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$VERIFY_RESPONSE" ]; then
        log_error "Failed to verify challenge"
        return 1
    fi
    
    JWT_TOKEN=$(echo "$VERIFY_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('jwt_token', ''))" 2>/dev/null)
    EXPIRES_IN=$(echo "$VERIFY_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('expires_in', 3600))" 2>/dev/null)
    
    if [ -z "$JWT_TOKEN" ]; then
        log_error "No JWT token in response"
        return 1
    fi
    
    # Set expiration (subtract 5 minutes buffer)
    JWT_EXPIRES_AT=$(($(date +%s) + EXPIRES_IN - 300))
    
    log_success "Authentication successful"
    return 0
}

# Function to ensure we have a valid token
ensure_token() {
    local now=$(date +%s)
    
    if [ -z "$JWT_TOKEN" ] || [ $now -ge $JWT_EXPIRES_AT ]; then
        authenticate || return 1
    fi
    
    return 0
}

# Function to get last N lines of agent-launcher logs
get_logs() {
    journalctl -u agent-launcher --no-pager -n $LOG_LINES 2>/dev/null || echo "Unable to retrieve logs"
}

# Function to send heartbeat
send_heartbeat() {
    local include_logs=$1
    local logs=""
    
    if [ "$include_logs" = "true" ]; then
        logs=$(get_logs | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
        # Remove surrounding quotes from json.dumps
        logs=${logs:1:-1}
    fi
    
    local body
    if [ -n "$logs" ]; then
        body="{\"logs\": \"$logs\"}"
    else
        body="{}"
    fi
    
    local response=$(curl -s -X POST "$ORCHESTRATOR_HTTP_URL/device/heartbeat" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -d "$body" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_error "Heartbeat request failed"
        return 1
    fi
    
    echo "$response"
}

# Function to update intervention status
update_intervention_status() {
    local intervention_id=$1
    local status=$2
    local error_message=$3
    
    local body="{\"status\": \"$status\""
    if [ -n "$error_message" ]; then
        body="$body, \"error_message\": \"$error_message\""
    fi
    body="$body}"
    
    curl -s -X POST "$ORCHESTRATOR_HTTP_URL/device/intervention/$intervention_id/status" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -d "$body" 2>/dev/null
}

# Function to execute intervention
execute_intervention() {
    local intervention_id=$1
    local intervention_type=$2
    
    log_info "Executing intervention: $intervention_type (ID: $intervention_id)"
    
    # Mark as in progress
    update_intervention_status "$intervention_id" "in_progress"
    
    local error_message=""
    local success=true
    
    case "$intervention_type" in
        "restart")
            log_info "Restarting agent-launcher service..."
            if sudo systemctl restart agent-launcher 2>&1; then
                log_success "Service restarted successfully"
            else
                error_message="Failed to restart service: $?"
                success=false
            fi
            ;;
        "reinstall")
            log_info "Running reinstall..."
            if [ -f "$SCRIPT_DIR/reinstall.sh" ]; then
                chmod +x "$SCRIPT_DIR/reinstall.sh"
                if "$SCRIPT_DIR/reinstall.sh" 2>&1; then
                    log_success "Reinstall completed successfully"
                else
                    error_message="Reinstall script failed with exit code: $?"
                    success=false
                fi
            else
                error_message="reinstall.sh not found"
                success=false
            fi
            ;;
        *)
            error_message="Unknown intervention type: $intervention_type"
            success=false
            ;;
    esac
    
    # Update final status
    if [ "$success" = true ]; then
        update_intervention_status "$intervention_id" "completed"
        log_success "Intervention $intervention_type completed"
    else
        update_intervention_status "$intervention_id" "failed" "$error_message"
        log_error "Intervention $intervention_type failed: $error_message"
    fi
}

# Main loop
log_info "Starting monitor loop..."

while true; do
    # Ensure we have a valid token
    if ! ensure_token; then
        log_error "Authentication failed, retrying in $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
        continue
    fi
    
    # Determine if we should send logs
    now=$(date +%s)
    include_logs="false"
    
    if [ $((now - LAST_LOG_SEND)) -ge $LOG_INTERVAL ]; then
        include_logs="true"
        LAST_LOG_SEND=$now
    fi
    
    # Send heartbeat
    response=$(send_heartbeat "$include_logs")
    
    if [ -z "$response" ]; then
        log_error "Empty heartbeat response"
        sleep $POLL_INTERVAL
        continue
    fi
    
    # Check for pending interventions
    interventions=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for i in data.get('interventions', []):
        print(f\"{i['id']}|{i['type']}\")
except:
    pass
" 2>/dev/null)
    
    # Execute any pending interventions
    if [ -n "$interventions" ]; then
        echo "$interventions" | while IFS='|' read -r id type; do
            if [ -n "$id" ] && [ -n "$type" ]; then
                execute_intervention "$id" "$type"
            fi
        done
    fi
    
    # Wait before next poll
    sleep $POLL_INTERVAL
done

