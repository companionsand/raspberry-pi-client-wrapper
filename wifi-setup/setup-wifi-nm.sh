#!/bin/bash
# WiFi Setup Script using NetworkManager (simpler, more compatible)

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WRAPPER_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
AP_SSID="Kin_Setup"
AP_INTERFACE="wlan0"
HTTP_PORT=80
SETUP_DIR="$WRAPPER_DIR/wifi-setup"
PAIRING_CODE_FILE="/tmp/kin_pairing_code"

# Logging
LOG_PREFIX="[wifi-setup-nm]"
log_info() {
    echo "$LOG_PREFIX [INFO] $1"
}

log_error() {
    echo "$LOG_PREFIX [ERROR] $1" >&2
}

log_success() {
    echo "$LOG_PREFIX [SUCCESS] $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if NetworkManager is available
if ! command -v nmcli &> /dev/null; then
    log_error "NetworkManager (nmcli) is not installed"
    log_info "Install it with: sudo apt-get install network-manager"
    exit 1
fi

# Function to create WiFi AP using NetworkManager
create_ap_nm() {
    log_info "Creating WiFi access point using NetworkManager: $AP_SSID"
    
    # Check if WiFi interface exists
    if ! ip link show "$AP_INTERFACE" &> /dev/null; then
        log_error "WiFi interface $AP_INTERFACE not found"
        ip link show
        return 1
    fi
    
    # Delete existing hotspot connection if it exists
    nmcli connection delete "Kin_Hotspot" 2>/dev/null || true
    
    # Create a new hotspot connection
    log_info "Creating hotspot connection..."
    nmcli connection add type wifi ifname "$AP_INTERFACE" \
        con-name "Kin_Hotspot" \
        autoconnect no \
        ssid "$AP_SSID"
    
    # Configure the hotspot
    nmcli connection modify "Kin_Hotspot" \
        802-11-wireless.mode ap \
        802-11-wireless.band bg \
        ipv4.method shared \
        ipv4.address 192.168.4.1/24
    
    # Start the hotspot
    log_info "Starting hotspot..."
    nmcli connection up "Kin_Hotspot"
    
    if [ $? -eq 0 ]; then
        log_success "WiFi access point created"
        
        # Wait a moment for the interface to be ready
        sleep 3
        
        # Verify it's working
        if nmcli connection show --active | grep -q "Kin_Hotspot"; then
            log_success "Hotspot is active and running"
            return 0
        else
            log_error "Hotspot created but not active"
            return 1
        fi
    else
        log_error "Failed to start hotspot"
        return 1
    fi
}

# Function to stop WiFi AP
stop_ap_nm() {
    log_info "Stopping WiFi access point..."
    
    # Bring down the hotspot
    nmcli connection down "Kin_Hotspot" 2>/dev/null || true
    
    # Delete the hotspot connection
    nmcli connection delete "Kin_Hotspot" 2>/dev/null || true
    
    log_success "WiFi access point stopped"
}

# Function to check internet connectivity
check_internet() {
    ping -c 1 -W 2 8.8.8.8 &> /dev/null
}

# Function to configure WiFi
configure_wifi_nm() {
    local ssid="$1"
    local password="$2"
    
    log_info "Configuring WiFi: $ssid"
    
    # Stop the hotspot first
    stop_ap_nm
    
    # Connect to the network
    if [ -z "$password" ]; then
        nmcli device wifi connect "$ssid" ifname "$AP_INTERFACE"
    else
        nmcli device wifi connect "$ssid" password "$password" ifname "$AP_INTERFACE"
    fi
    
    if [ $? -eq 0 ]; then
        log_success "WiFi configured successfully"
        return 0
    else
        log_error "Failed to configure WiFi"
        return 1
    fi
}

# Source the HTTP server functions from the original script
# (reusing the same HTTP server and API code)
source "$SCRIPT_DIR/setup-wifi.sh" 2>/dev/null || {
    # If we can't source it, define the HTTP server function here
    start_http_server_with_api() {
        log_info "Starting HTTP server with API on port $HTTP_PORT..."
        
        # Create Python HTTP server with API endpoints
        cat > "$SETUP_DIR/http_server.py" <<'PYTHON_EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import os

PAIRING_CODE_FILE = "/tmp/kin_pairing_code"
SETUP_DIR = os.path.dirname(os.path.abspath(__file__))

class SetupHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.path = '/setup.html'
        elif self.path == '/networks':
            self.send_networks()
            return
        return super().do_GET()
    
    def do_POST(self):
        if self.path == '/configure':
            self.handle_configure()
        else:
            self.send_error(404)
    
    def send_networks(self):
        try:
            networks = []
            result = subprocess.run(['nmcli', '-t', '-f', 'SSID,SECURITY', 'device', 'wifi', 'list'],
                                  capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                seen = set()
                for line in result.stdout.strip().split('\n'):
                    if ':' in line:
                        parts = line.split(':')
                        if len(parts) >= 2:
                            ssid = parts[0].strip()
                            if ssid and ssid not in seen:
                                seen.add(ssid)
                                networks.append({
                                    'ssid': ssid,
                                    'encrypted': bool(parts[1].strip())
                                })
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({'networks': networks}).encode())
        except Exception as e:
            self.send_error(500, str(e))
    
    def handle_configure(self):
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            ssid = data.get('ssid', '').strip()
            password = data.get('password', '').strip()
            pairing_code = data.get('pairing_code', '').strip()
            
            if not ssid:
                self.send_error(400, 'SSID is required')
                return
            
            if not pairing_code or len(pairing_code) != 4 or not pairing_code.isdigit():
                self.send_error(400, 'Valid 4-digit pairing code is required')
                return
            
            # Save pairing code
            with open(PAIRING_CODE_FILE, 'w') as f:
                f.write(pairing_code)
            
            # Configure WiFi using the shell script
            if password:
                result = subprocess.run(['nmcli', 'device', 'wifi', 'connect', ssid, 'password', password],
                                      capture_output=True, text=True, timeout=30)
            else:
                result = subprocess.run(['nmcli', 'device', 'wifi', 'connect', ssid],
                                      capture_output=True, text=True, timeout=30)
            
            if result.returncode == 0:
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({'success': True}).encode())
            else:
                self.send_error(500, f'WiFi configuration failed: {result.stderr}')
        except Exception as e:
            self.send_error(500, str(e))

if __name__ == '__main__':
    os.chdir(SETUP_DIR)
    PORT = 80
    with socketserver.TCPServer(("", PORT), SetupHandler) as httpd:
        print(f"Server running on port {PORT}")
        httpd.serve_forever()
PYTHON_EOF
        
        chmod +x "$SETUP_DIR/http_server.py"
        
        # Also create the HTML file
        cat > "$SETUP_DIR/setup.html" <<'HTML_EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kin Device Setup</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        .container {
            background: white;
            border-radius: 20px;
            padding: 40px;
            max-width: 500px;
            width: 100%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        }
        h1 { color: #333; margin-bottom: 10px; font-size: 28px; }
        .subtitle { color: #666; margin-bottom: 30px; font-size: 14px; }
        .form-group { margin-bottom: 20px; }
        label { display: block; margin-bottom: 8px; color: #333; font-weight: 500; }
        select, input {
            width: 100%;
            padding: 12px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
        }
        button {
            width: 100%;
            padding: 14px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
        }
        .message { padding: 12px; border-radius: 8px; margin-bottom: 20px; }
        .success { background: #d4edda; color: #155724; }
        .error { background: #f8d7da; color: #721c24; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Kin Device Setup</h1>
        <p class="subtitle">Configure your WiFi network to get started</p>
        <div id="message"></div>
        <form id="setupForm">
            <div class="form-group">
                <label for="ssid">WiFi Network</label>
                <select id="ssid" name="ssid" required>
                    <option value="">Scanning...</option>
                </select>
            </div>
            <div class="form-group">
                <label for="password">WiFi Password</label>
                <input type="password" id="password" name="password" placeholder="Leave blank if open">
            </div>
            <div class="form-group">
                <label for="pairingCode">Pairing Code</label>
                <input type="text" id="pairingCode" name="pairingCode" pattern="[0-9]{4}" maxlength="4" placeholder="1234" required>
            </div>
            <button type="submit" id="submitBtn">Connect</button>
        </form>
    </div>
    <script>
        const form = document.getElementById('setupForm');
        const ssidSelect = document.getElementById('ssid');
        const messageDiv = document.getElementById('message');
        
        fetch('/networks')
            .then(r => r.json())
            .then(data => {
                ssidSelect.innerHTML = '<option value="">Select network...</option>';
                data.networks.forEach(n => {
                    const opt = document.createElement('option');
                    opt.value = n.ssid;
                    opt.textContent = n.ssid + (n.encrypted ? ' 🔒' : '');
                    ssidSelect.appendChild(opt);
                });
            });
        
        form.onsubmit = async (e) => {
            e.preventDefault();
            const data = {
                ssid: form.ssid.value,
                password: form.password.value,
                pairing_code: form.pairingCode.value
            };
            try {
                const r = await fetch('/configure', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(data)
                });
                const result = await r.json();
                messageDiv.innerHTML = result.success ? 
                    '<div class="message success">Connected! Device will restart...</div>' :
                    '<div class="message error">Error: ' + (result.error || 'Failed') + '</div>';
            } catch(e) {
                messageDiv.innerHTML = '<div class="message error">Error: ' + e.message + '</div>';
            }
        };
    </script>
</body>
</html>
HTML_EOF
        
        # Start server in background
        python3 "$SETUP_DIR/http_server.py" > /dev/null 2>&1 &
        HTTP_SERVER_PID=$!
        echo $HTTP_SERVER_PID > "$SETUP_DIR/http_server.pid"
        
        log_success "HTTP server started (PID: $HTTP_SERVER_PID)"
    }
    
    stop_http_server() {
        if [ -f "$SETUP_DIR/http_server.pid" ]; then
            kill $(cat "$SETUP_DIR/http_server.pid") 2>/dev/null || true
            rm "$SETUP_DIR/http_server.pid"
        fi
    }
}

# Main setup flow
main() {
    log_info "Starting WiFi setup mode (NetworkManager version)..."
    
    # Create setup directory
    mkdir -p "$SETUP_DIR"
    
    # Create WiFi AP
    if ! create_ap_nm; then
        log_error "Failed to create access point"
        exit 1
    fi
    
    # Start HTTP server
    start_http_server_with_api
    
    log_info "====================================="
    log_success "WiFi setup mode active!"
    log_info "Connect to '$AP_SSID' network"
    log_info "Open browser to: http://192.168.4.1"
    log_info "====================================="
    
    # Wait for configuration
    while true; do
        sleep 5
        
        if [ -f "$PAIRING_CODE_FILE" ]; then
            log_info "Configuration received, checking connection..."
            sleep 10
            
            if check_internet; then
                log_success "WiFi configured and connected!"
                stop_http_server
                exit 0
            fi
        fi
    done
}

# Run main
main "$@"

