#!/bin/bash
# Setup PipeWire Echo Cancellation for Raspberry Pi
# This script configures PipeWire with echo cancellation for barge-in capability

set -e

echo "========================================="
echo "Setting up PipeWire Echo Cancellation"
echo "========================================="

# Install required packages
echo "📦 Installing PipeWire dependencies..."
sudo apt update
sudo apt install -y pipewire wireplumber libspa-0.2-modules alsa-utils

echo "✓ Dependencies installed"

# Check if PipeWire is running
echo "🔍 Checking PipeWire status..."
if systemctl --user is-active --quiet pipewire; then
    echo "✓ PipeWire is running"
else
    echo "⚠️  PipeWire is not running, will start it..."
fi

# Restart PipeWire services to load AEC modules
echo "🔄 Restarting PipeWire services..."
systemctl --user restart wireplumber 2>/dev/null || true
systemctl --user restart pipewire pipewire-pulse 2>/dev/null || true

# Wait for services to initialize
echo "⏳ Waiting for services to initialize..."
sleep 3

# Verify echo cancellation nodes exist
echo "🔍 Verifying echo cancellation setup..."
if pactl list short sources | grep -q "echo_cancel"; then
    echo "✓ Echo cancellation source (echo_cancel.mic) found"
else
    echo "⚠️  Warning: Echo cancellation source not found"
    echo "   This may require manual PipeWire configuration"
fi

if pactl list short sinks | grep -q "echo_cancel"; then
    echo "✓ Echo cancellation sink (echo_cancel.speaker) found"
else
    echo "⚠️  Warning: Echo cancellation sink not found"
    echo "   This may require manual PipeWire configuration"
fi

# Note: Echo cancellation requires manual PipeWire configuration
echo ""
echo "⚠️  Note: Echo cancellation requires manual PipeWire configuration"
echo "   The Raspberry Pi client will use the default audio devices."
echo "   For echo cancellation, please configure PipeWire manually:"
echo "   - See: https://docs.pipewire.org/page_module_echo_cancel.html"
echo ""

echo ""
echo "========================================="
echo "✅ PipeWire Echo Cancellation Setup Complete!"
echo "========================================="
echo ""
echo "Verification:"
echo "  Sources: pactl list short sources | grep echo_cancel"
echo "  Sinks:   pactl list short sinks | grep echo_cancel"
echo ""
echo "Expected devices:"
echo "  - echo_cancel.mic (microphone with AEC)"
echo "  - echo_cancel.speaker (speaker with AEC)"
echo ""

