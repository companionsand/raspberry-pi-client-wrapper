#!/bin/bash
# WiFi Setup Script for Raspberry Pi
# Handles WiFi AP creation, HTTP server, and WiFi configuration

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WRAPPER_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
AP_SSID="Kin_Setup"
AP_INTERFACE="wlan0"
HTTP_PORT=80
SETUP_DIR="$WRAPPER_DIR/wifi-setup"
PAIRING_CODE_FILE="/tmp/kin_pairing_code"
WIFI_CONFIG_FILE="/etc/wpa_supplicant/wpa_supplicant.conf"
MAX_RETRIES=5

# Logging
LOG_PREFIX="[wifi-setup]"
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

# Function to check internet connectivity
check_internet() {
    ping -c 1 -W 2 8.8.8.8 &> /dev/null
}

# Function to create WiFi AP
create_ap() {
    log_info "Creating WiFi access point: $AP_SSID"
    
    # Stop existing network services
    systemctl stop wpa_supplicant 2>/dev/null || true
    systemctl stop dhcpcd 2>/dev/null || true
    
    # Configure hostapd
    cat > /etc/hostapd/hostapd.conf <<EOF
interface=$AP_INTERFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
EOF
    
    # Configure dnsmasq for DHCP
    cat > /etc/dnsmasq.conf <<EOF
interface=$AP_INTERFACE
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
EOF
    
    # Configure static IP for AP
    cat > /etc/dhcpcd.conf.ap <<EOF
interface $AP_INTERFACE
static ip_address=192.168.4.1/24
nohook wpa_supplicant
EOF
    
    # Backup original dhcpcd.conf
    if [ ! -f /etc/dhcpcd.conf.backup ]; then
        cp /etc/dhcpcd.conf /etc/dhcpcd.conf.backup
    fi
    
    # Use AP config
    cp /etc/dhcpcd.conf.ap /etc/dhcpcd.conf
    
    # Start services
    systemctl start hostapd
    systemctl start dnsmasq
    systemctl start dhcpcd
    
    log_success "WiFi access point created"
}

# Function to stop WiFi AP
stop_ap() {
    log_info "Stopping WiFi access point..."
    
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    
    # Restore original dhcpcd.conf
    if [ -f /etc/dhcpcd.conf.backup ]; then
        cp /etc/dhcpcd.conf.backup /etc/dhcpcd.conf
    fi
    
    systemctl restart dhcpcd 2>/dev/null || true
    
    log_success "WiFi access point stopped"
}

# Function to scan for WiFi networks
scan_wifi() {
    log_info "Scanning for WiFi networks..."
    
    # Try iwlist first, fallback to nmcli
    if command -v iwlist &> /dev/null; then
        iwlist "$AP_INTERFACE" scan 2>/dev/null | grep -E "ESSID:|Encryption" | paste - - | sed 's/.*ESSID:"\(.*\)".*Encryption:\(.*\)/\1|\2/' | sort -u
    elif command -v nmcli &> /dev/null; then
        nmcli -t -f SSID,SECURITY device wifi list 2>/dev/null | sort -u
    else
        log_error "No WiFi scanning tool available (iwlist or nmcli)"
        return 1
    fi
}

# Function to configure WiFi
configure_wifi() {
    local ssid="$1"
    local password="$2"
    
    log_info "Configuring WiFi: $ssid"
    
    # Use nmcli to configure WiFi
    if command -v nmcli &> /dev/null; then
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
    else
        log_error "nmcli not available for WiFi configuration"
        return 1
    fi
}

# Function to start HTTP server
start_http_server() {
    log_info "Starting HTTP server on port $HTTP_PORT..."
    
    # Create setup page HTML
    cat > "$SETUP_DIR/setup.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kin Device Setup</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
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
        h1 {
            color: #333;
            margin-bottom: 10px;
            font-size: 28px;
        }
        .subtitle {
            color: #666;
            margin-bottom: 30px;
            font-size: 14px;
        }
        .form-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 8px;
            color: #333;
            font-weight: 500;
            font-size: 14px;
        }
        select, input {
            width: 100%;
            padding: 12px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.3s;
        }
        select:focus, input:focus {
            outline: none;
            border-color: #667eea;
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
            transition: transform 0.2s, box-shadow 0.2s;
        }
        button:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
        }
        button:active {
            transform: translateY(0);
        }
        button:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
        .message {
            padding: 12px;
            border-radius: 8px;
            margin-bottom: 20px;
            font-size: 14px;
        }
        .success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        .error {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        .loading {
            text-align: center;
            color: #666;
        }
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
                    <option value="">Scanning for networks...</option>
                </select>
            </div>
            
            <div class="form-group">
                <label for="password">WiFi Password (leave blank if open)</label>
                <input type="password" id="password" name="password" placeholder="Enter WiFi password">
            </div>
            
            <div class="form-group">
                <label for="pairingCode">Pairing Code</label>
                <input type="text" id="pairingCode" name="pairingCode" pattern="[0-9]{4}" maxlength="4" placeholder="1234" required>
            </div>
            
            <button type="submit" id="submitBtn">Connect</button>
        </form>
    </div>
    
    <script>
        const ssidSelect = document.getElementById('ssid');
        const form = document.getElementById('setupForm');
        const messageDiv = document.getElementById('message');
        const submitBtn = document.getElementById('submitBtn');
        
        function showMessage(text, type) {
            messageDiv.innerHTML = '<div class="message ' + type + '">' + text + '</div>';
        }
        
        // Load WiFi networks
        fetch('/networks')
            .then(response => response.json())
            .then(data => {
                ssidSelect.innerHTML = '<option value="">Select a network...</option>';
                data.networks.forEach(network => {
                    const option = document.createElement('option');
                    option.value = network.ssid;
                    option.textContent = network.ssid + (network.encrypted ? ' (secured)' : ' (open)');
                    ssidSelect.appendChild(option);
                });
            })
            .catch(error => {
                showMessage('Failed to load WiFi networks. Please refresh the page.', 'error');
            });
        
        // Handle form submission
        form.addEventListener('submit', async (e) => {
            e.preventDefault();
            submitBtn.disabled = true;
            submitBtn.textContent = 'Connecting...';
            
            const formData = new FormData(form);
            const data = {
                ssid: formData.get('ssid'),
                password: formData.get('password') || '',
                pairing_code: formData.get('pairingCode')
            };
            
            try {
                const response = await fetch('/configure', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(data)
                });
                
                const result = await response.json();
                
                if (result.success) {
                    showMessage('WiFi configured successfully! Device will restart and connect...', 'success');
                    // Wait a bit then redirect or show success
                    setTimeout(() => {
                        showMessage('Setup complete! You can close this page.', 'success');
                    }, 2000);
                } else {
                    showMessage('Error: ' + (result.error || 'Failed to configure WiFi'), 'error');
                    submitBtn.disabled = false;
                    submitBtn.textContent = 'Connect';
                }
            } catch (error) {
                showMessage('Error: ' + error.message, 'error');
                submitBtn.disabled = false;
                submitBtn.textContent = 'Connect';
            }
        });
    </script>
</body>
</html>
EOF
    
    # Start Python HTTP server in background
    cd "$SETUP_DIR"
    python3 -m http.server "$HTTP_PORT" > /dev/null 2>&1 &
    HTTP_SERVER_PID=$!
    echo $HTTP_SERVER_PID > "$SETUP_DIR/http_server.pid"
    
    log_success "HTTP server started (PID: $HTTP_SERVER_PID)"
}

# Function to stop HTTP server
stop_http_server() {
    if [ -f "$SETUP_DIR/http_server.pid" ]; then
        local pid=$(cat "$SETUP_DIR/http_server.pid")
        kill "$pid" 2>/dev/null || true
        rm "$SETUP_DIR/http_server.pid"
        log_info "HTTP server stopped"
    fi
}

# Function to handle HTTP requests (simple Python server with API endpoints)
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
import sys

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
            # Scan for WiFi networks
            networks = []
            try:
                result = subprocess.run(['iwlist', 'wlan0', 'scan'], 
                                      capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    current_ssid = None
                    for line in result.stdout.split('\n'):
                        if 'ESSID:' in line:
                            ssid = line.split('ESSID:')[1].strip().strip('"')
                            if ssid:
                                current_ssid = ssid
                        elif 'Encryption key:' in line and current_ssid:
                            encrypted = 'on' in line.lower()
                            networks.append({
                                'ssid': current_ssid,
                                'encrypted': encrypted
                            })
                            current_ssid = None
            except:
                # Fallback to nmcli
                try:
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
                except:
                    pass
            
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
            
            # Configure WiFi using nmcli
            try:
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
                self.send_error(500, f'WiFi configuration error: {str(e)}')
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
    
    # Start server in background
    python3 "$SETUP_DIR/http_server.py" > /dev/null 2>&1 &
    HTTP_SERVER_PID=$!
    echo $HTTP_SERVER_PID > "$SETUP_DIR/http_server.pid"
    
    log_success "HTTP server with API started (PID: $HTTP_SERVER_PID)"
}

# Main setup flow
main() {
    log_info "Starting WiFi setup mode..."
    
    # Create setup directory
    mkdir -p "$SETUP_DIR"
    
    # Create WiFi AP
    create_ap
    
    # Start HTTP server with API
    start_http_server_with_api
    
    log_info "WiFi setup mode active. Connect to '$AP_SSID' network and go to http://192.168.4.1"
    log_info "Waiting for WiFi configuration..."
    
    # Wait for WiFi configuration (check if pairing code file exists and WiFi is configured)
    retry_count=0
    while [ $retry_count -lt $MAX_RETRIES ]; do
        sleep 5
        
        # Check if pairing code file exists (indicates user submitted form)
        if [ -f "$PAIRING_CODE_FILE" ]; then
            log_info "Pairing code received, checking WiFi connection..."
            
            # Stop AP
            stop_ap
            stop_http_server
            
            # Wait a bit for WiFi to connect
            sleep 10
            
            # Check internet connectivity
            if check_internet; then
                log_success "WiFi configured and internet connection established!"
                return 0
            else
                log_error "WiFi configured but no internet connection. Retrying... ($retry_count/$MAX_RETRIES)"
                retry_count=$((retry_count + 1))
                
                # Restart AP for retry
                create_ap
                start_http_server_with_api
            fi
        fi
    done
    
    log_error "Failed to configure WiFi after $MAX_RETRIES attempts. Restarting setup mode..."
    stop_ap
    stop_http_server
    return 1
}

# Run main function
main "$@"

