#!/bin/bash
# Fix Audio - Restore PipeWire after failed echo cancellation setup
# Run this script to restore audio functionality

set -e

echo "========================================="
echo "  Fixing PipeWire Audio"
echo "========================================="
echo ""

# Step 1: Stop and disable the problematic service
echo "🛑 Stopping problematic pipewire-aec service..."
if systemctl --user is-active --quiet pipewire-aec 2>/dev/null; then
    systemctl --user stop pipewire-aec
    echo "✓ Stopped pipewire-aec.service"
fi

if systemctl --user is-enabled --quiet pipewire-aec 2>/dev/null; then
    systemctl --user disable pipewire-aec
    echo "✓ Disabled pipewire-aec.service"
fi

if [ -f "$HOME/.config/systemd/user/pipewire-aec.service" ]; then
    rm "$HOME/.config/systemd/user/pipewire-aec.service"
    echo "✓ Removed service file"
fi

# Step 2: Reset failed services
echo ""
echo "🔄 Resetting failed services..."
systemctl --user reset-failed 2>/dev/null || true
echo "✓ Reset failed service states"

# Step 3: Restart PipeWire services
echo ""
echo "🔄 Restarting PipeWire services..."
systemctl --user restart wireplumber
systemctl --user restart pipewire pipewire-pulse
echo "✓ PipeWire services restarted"

# Step 4: Wait for services to initialize
echo ""
echo "⏳ Waiting for services to initialize..."
sleep 3

# Step 5: Check status
echo ""
echo "📊 Checking service status..."
if systemctl --user is-active --quiet pipewire; then
    echo "✓ PipeWire is running"
else
    echo "✗ PipeWire is not running"
fi

if systemctl --user is-active --quiet pipewire-pulse; then
    echo "✓ PipeWire PulseAudio is running"
else
    echo "✗ PipeWire PulseAudio is not running"
fi

if systemctl --user is-active --quiet wireplumber; then
    echo "✓ WirePlumber is running"
else
    echo "✗ WirePlumber is not running"
fi

# Step 6: List audio devices
echo ""
echo "🔊 Available audio devices:"
echo ""
echo "Sources (microphones):"
pactl list short sources || echo "Could not list sources"
echo ""
echo "Sinks (speakers):"
pactl list short sinks || echo "Could not list sinks"

echo ""
echo "========================================="
echo "✅ Audio Fix Complete!"
echo "========================================="
echo ""
echo "Your audio devices should now be working."
echo "Test by running:"
echo "  speaker-test -c2 -t wav"
echo ""

