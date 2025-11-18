# Raspberry Pi Client Wrapper

A comprehensive wrapper for deploying and managing the Kin AI Raspberry Pi client. This wrapper handles all dependencies, services, and automatic updates.

## Overview

This wrapper automates the setup and management of the Kin AI voice assistant client on Raspberry Pi. It handles:

- 🔧 System dependency installation
- 📡 OpenTelemetry collector setup with persistent logging
- 🎤 PipeWire echo cancellation configuration
- 🔄 Automatic code updates from git
- 🚀 Systemd service management for auto-start on boot
- 📦 Python virtual environment and dependency management

## Architecture

```
raspberry-pi-client-wrapper/
├── install.sh                 # One-time installation script
├── launch.sh                  # Runtime launcher (run by systemd)
├── otel/
│   ├── install-collector.sh  # OpenTelemetry collector installer
│   └── otel-collector-config.yaml
├── pipewire/
│   └── setup-aec.sh          # Echo cancellation setup
├── services/
│   └── agent-launcher.service # Systemd service template
├── raspberry-pi-client/      # Git cloned here (gitignored)
└── README.md                 # This file
```

## Prerequisites

### Hardware
- Raspberry Pi 5 (recommended) or Pi 4
- USB microphone
- USB speaker or 3.5mm audio output
- MicroSD card (32GB+ recommended)
- Stable internet connection

### Software
- Raspberry Pi OS Lite (64-bit) or Desktop
- Fresh system or clean install recommended

## Quick Start

### 1. Setup GitHub SSH Access (Required)

Since the `raspberry-pi-client` repository is private, you need to set up SSH keys on your Raspberry Pi first:

```bash
# SSH into your Pi
ssh pi@raspberrypi.local

# Generate SSH key
ssh-keygen -t ed25519 -C "your_email@example.com"
# Press Enter to accept defaults

# Display your public key
cat ~/.ssh/id_ed25519.pub

# Copy the output and add it to GitHub:
# https://github.com/settings/ssh/new

# Test the connection
ssh -T git@github.com
# You should see: "Hi <username>! You've successfully authenticated..."
```

### 2. Copy Wrapper to Pi

Copy this entire `raspberry-pi-client-wrapper` directory to your Raspberry Pi:

```bash
# On your development machine:
scp -r raspberry-pi-client-wrapper pi@raspberrypi.local:~/

# Or use rsync:
rsync -av raspberry-pi-client-wrapper pi@raspberrypi.local:~/
```

### 3. Run Installation Script

SSH into your Raspberry Pi and run the installer:

```bash
ssh pi@raspberrypi.local
cd ~/raspberry-pi-client-wrapper
chmod +x install.sh
./install.sh
```

The installer will:
1. ✓ Check system compatibility
2. ✓ **Verify GitHub SSH access** (exits with instructions if not configured)
3. ✓ Install system dependencies (Python, PipeWire, audio libraries)
4. ✓ Clone the raspberry-pi-client repository
5. ✓ Create Python virtual environment
6. ✓ Install Python requirements
7. ✓ **Prompt for configuration** (Device ID, OTEL endpoint, Environment)
8. ✓ Setup OpenTelemetry Collector with systemd service
9. ✓ Verify PipeWire is running (for audio)
10. ✓ Setup agent-launcher systemd service (with auto-restart)
11. ✓ Create .env template files

**Installation takes 5-10 minutes** depending on your Pi model and internet speed.

#### Installation Prompts

During installation, you'll be asked to provide:
- **Device ID**: Your unique device identifier
- **OTEL Central Collector Endpoint**: Your central telemetry collector URL (e.g., `https://your-collector.onrender.com:4318`)
- **Environment**: Deployment environment (production/staging/development)

These values will be automatically configured in the system.

### 4. Configure API Keys and Credentials

After installation, configure the client with your API keys:

```bash
nano ~/raspberry-pi-client-wrapper/raspberry-pi-client/.env
```

Fill in the required API keys and credentials:
```bash
# Already configured by installer:
DEVICE_ID=your-device-id        # ✓ Already set
ENV=production                  # ✓ Already set

# You need to fill in:
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-supabase-anon-key-here
EMAIL=your-email@example.com
PASSWORD=your-password-here
CONVERSATION_ORCHESTRATOR_URL=ws://your-backend:8001/ws
ELEVENLABS_API_KEY=your-elevenlabs-api-key-here
PICOVOICE_ACCESS_KEY=your-picovoice-access-key-here
```

**Note:** Device ID, OTEL endpoint, and environment are already configured from the installation prompts. You only need to add your API keys and credentials.

### 5. Start Services

```bash
# Start OpenTelemetry Collector
sudo systemctl restart otelcol

# Start the agent launcher
sudo systemctl restart agent-launcher

# Check status
sudo systemctl status otelcol
sudo systemctl status agent-launcher
```

### 6. View Logs

```bash
# Agent launcher logs (main application)
sudo journalctl -u agent-launcher -f

# OpenTelemetry Collector logs
sudo journalctl -u otelcol -f

# Combined view
sudo journalctl -u agent-launcher -u otelcol -f
```

## How It Works

### Auto-Restart on Crash

🔄 **The system is configured for maximum reliability:**

- If `main.py` crashes or errors out, systemd automatically restarts it
- No limit on restart attempts - it will keep trying indefinitely
- 10-second delay between restart attempts
- Restarts are logged in systemd journal

This ensures your device stays online even after:
- Python exceptions
- Network failures
- Temporary service disruptions
- System resource issues

### Boot Sequence

When the Raspberry Pi boots:

1. **Network Wait**: `agent-launcher.service` waits for network-online.target
2. **OTEL Start**: OpenTelemetry Collector starts (dependency)
3. **Launch Script**: `launch.sh` is executed by systemd

### Launch Script Flow

The `launch.sh` script runs on every boot:

```
1. Check Internet Connection
   ├─ Ping 8.8.8.8 with retries
   └─ Exit if no connection after 30 attempts

2. Update Code
   ├─ Clone repo if not exists
   └─ Git pull latest changes if exists

3. Setup Python Environment
   ├─ Create venv if not exists
   └─ Activate venv

4. Install Dependencies
   └─ pip install -r requirements.txt

5. Verify Configuration
   └─ Check .env file exists

6. Run Client
   └─ exec python main.py
```

### Services Overview

| Service | Type | Purpose | Auto-Start | Auto-Restart |
|---------|------|---------|------------|--------------|
| `otelcol.service` | System | OpenTelemetry Collector | ✓ Yes | ✓ Yes |
| `agent-launcher.service` | System | Client Launcher & Updater | ✓ Yes | ✓ Yes (unlimited) |

## Manual Operations

### Manually Update Code

```bash
cd ~/raspberry-pi-client-wrapper/raspberry-pi-client
git pull origin main
sudo systemctl restart agent-launcher
```

### Reinstall Dependencies

```bash
cd ~/raspberry-pi-client-wrapper/raspberry-pi-client
source venv/bin/activate
pip install -r requirements.txt --force-reinstall
```

### Reset to Fresh State

```bash
# Stop services
sudo systemctl stop agent-launcher
sudo systemctl stop otelcol

# Remove cloned repository
rm -rf ~/raspberry-pi-client-wrapper/raspberry-pi-client

# Restart (will re-clone)
sudo systemctl start agent-launcher
```

## Troubleshooting

### GitHub SSH Authentication Fails

**Problem**: Installation fails with "GitHub SSH authentication failed!"

**Solution:**
```bash
# 1. Generate SSH key if you haven't already
ssh-keygen -t ed25519 -C "your_email@example.com"

# 2. Display your public key
cat ~/.ssh/id_ed25519.pub

# 3. Copy the entire output and add it to GitHub:
# Go to: https://github.com/settings/ssh/new
# Paste the key and save

# 4. Test the connection
ssh -T git@github.com
# Expected output: "Hi <username>! You've successfully authenticated..."

# 5. Re-run the installer
cd ~/raspberry-pi-client-wrapper
./install.sh
```

**Common SSH issues:**
- Permission denied: SSH key not added to GitHub
- Host key verification failed: Run `ssh -T git@github.com` and accept the host key
- No route to host: Check internet connection

### Agent Won't Start

**Check logs:**
```bash
sudo journalctl -u agent-launcher -n 50
```

**View restart history:**
```bash
# See how many times the service has restarted
sudo systemctl status agent-launcher

# Watch for restart events in real-time
sudo journalctl -u agent-launcher -f
```

**Common issues:**
- `.env` file not configured
- No internet connection
- Python dependencies failed to install
- Invalid credentials
- Repeated crashes (check Python error messages in logs)

**If the service is crash-looping:**
The service will keep restarting automatically. Check logs to identify the root cause:
```bash
# Get last 100 lines to see error pattern
sudo journalctl -u agent-launcher -n 100

# Filter for Python errors
sudo journalctl -u agent-launcher | grep -i error
```

### Audio Issues (No Microphone/Speaker Detected)

**Problem**: Audio devices not detected after installation

**Quick Fix**: Run the audio fix script:
```bash
cd ~/raspberry-pi-client-wrapper
./fix-audio.sh
```

This script will:
- Remove problematic service configurations
- Reset failed PipeWire services
- Restart audio services properly
- List available audio devices

**Manual fix:**
```bash
# Reset failed services
systemctl --user reset-failed

# Restart PipeWire services
systemctl --user restart wireplumber
systemctl --user restart pipewire pipewire-pulse

# Check audio devices
pactl list short sources  # microphones
pactl list short sinks    # speakers
```

**Test audio:**
```bash
# Test speaker
speaker-test -c2 -t wav

# Test microphone
arecord -d 5 test.wav && aplay test.wav
```

### OpenTelemetry Collector Issues

**Check status:**
```bash
sudo systemctl status otelcol
sudo journalctl -u otelcol -n 50
```

**Validate config:**
```bash
sudo /usr/local/bin/otelcol --config=/etc/otelcol/config.yaml validate
```

**Check connectivity:**
```bash
curl -X POST https://your-collector.onrender.com:4318/v1/traces
```

### Code Not Updating

**Force update:**
```bash
cd ~/raspberry-pi-client-wrapper/raspberry-pi-client
git fetch origin main
git reset --hard origin/main
sudo systemctl restart agent-launcher
```

### Service Won't Start on Boot

**Check service status:**
```bash
sudo systemctl is-enabled agent-launcher
sudo systemctl is-enabled otelcol
```

**Re-enable:**
```bash
sudo systemctl enable agent-launcher
sudo systemctl enable otelcol
sudo systemctl daemon-reload
```

## Development Mode

To run the client manually (not as a service):

```bash
# Stop the service
sudo systemctl stop agent-launcher

# Activate venv and run
cd ~/raspberry-pi-client-wrapper/raspberry-pi-client
source venv/bin/activate
python main.py

# When done, restart service
sudo systemctl start agent-launcher
```

## Uninstallation

### Quick Uninstall

To completely remove the wrapper and all services, simply run the uninstall script:

```bash
cd ~/raspberry-pi-client-wrapper
./uninstall.sh
```

The uninstall script will:
1. Stop all services (agent-launcher, otelcol, pipewire-aec)
2. Disable all services
3. Remove service files from systemd
4. Remove OpenTelemetry Collector (binary, configs, data)
5. Remove cloned repository and virtual environment
6. **Prompt** to remove wrapper directory (optional)
7. **Prompt** to remove system packages (optional)
8. Clean up all traces

**Interactive Prompts:**
- Remove wrapper directory? (keeps scripts if you say no)
- Remove system packages? (Python, PipeWire, etc. - may be used by other apps)
- Reboot now? (recommended to complete cleanup)

### What Gets Removed

**Always removed:**
- ✓ All systemd services
- ✓ OpenTelemetry Collector
- ✓ Cloned raspberry-pi-client repository
- ✓ Python virtual environment

**Optional (prompted):**
- Wrapper directory with scripts
- System packages (pip, pipewire, etc.)

**Preserved:**
- System journal logs (can be manually cleared)
- PipeWire user configurations (may be used by other apps)

### Manual Uninstallation

If you prefer to uninstall manually:

```bash
# Stop and disable services
sudo systemctl stop agent-launcher
sudo systemctl disable agent-launcher
sudo systemctl stop otelcol
sudo systemctl disable otelcol
systemctl --user stop pipewire-aec
systemctl --user disable pipewire-aec

# Remove service files
sudo rm /etc/systemd/system/agent-launcher.service
sudo rm /etc/systemd/system/otelcol.service
rm ~/.config/systemd/user/pipewire-aec.service

# Remove OpenTelemetry Collector
sudo rm /usr/local/bin/otelcol
sudo rm -rf /etc/otelcol
sudo rm -rf /var/lib/otelcol
sudo rm -rf /var/log/otelcol

# Remove wrapper
rm -rf ~/raspberry-pi-client-wrapper

# Reload systemd
sudo systemctl daemon-reload
systemctl --user daemon-reload

# Reboot
sudo reboot
```

## Configuration Reference

### Git Repository
- **URL**: `git@github.com:companionsand/raspberry-pi-client.git` (SSH)
- **Branch**: `main`
- **Clone Location**: `~/raspberry-pi-client-wrapper/raspberry-pi-client/`
- **Authentication**: Requires SSH key added to GitHub account

### Paths
- **Wrapper**: `~/raspberry-pi-client-wrapper/`
- **Client**: `~/raspberry-pi-client-wrapper/raspberry-pi-client/`
- **Venv**: `~/raspberry-pi-client-wrapper/raspberry-pi-client/venv/`
- **Client .env**: `~/raspberry-pi-client-wrapper/raspberry-pi-client/.env`
- **Cache**: `~/raspberry-pi-client-wrapper/otel/.cache/` (OpenTelemetry tarball)
- **OTEL Config**: `/etc/otelcol/config.yaml`
- **OTEL Env**: `/etc/otelcol/otelcol.env`

### Service Files
- **Agent Launcher**: `/etc/systemd/system/agent-launcher.service`
- **OTEL Collector**: `/etc/systemd/system/otelcol.service`

## Performance Optimizations

### Cached Downloads

The installer caches downloaded files to speed up reinstallations:

**Location**: `~/raspberry-pi-client-wrapper/otel/.cache/`

**What's cached:**
- OpenTelemetry Collector tarball (~40MB)

**Benefits:**
- ✅ First installation: Downloads from internet
- ✅ Subsequent installations: Uses cached file (10x faster)
- ✅ Works offline after first download
- ✅ Preserves bandwidth

**Cache management:**
```bash
# Check cache size
du -sh ~/raspberry-pi-client-wrapper/otel/.cache

# Clear cache manually
rm -rf ~/raspberry-pi-client-wrapper/otel/.cache

# Uninstaller asks if you want to remove cache
# (Keeping it speeds up future reinstalls)
```

## Additional Documentation

- **OpenTelemetry Setup**: See `OTEL_SETUP.md` for detailed OTEL information
- **Client README**: See `raspberry-pi-client/README.md` after installation

## Support

If you encounter issues:
1. Check service logs with `journalctl`
2. Verify configuration files are correct
3. Ensure internet connectivity
4. Check system resources (disk space, memory)

## License

Copyright © 2025 Kin Voice AI. All rights reserved.

