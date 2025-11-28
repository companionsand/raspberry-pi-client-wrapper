#!/bin/bash
# =============================================================================
# ALSA Loopback Uninstall
# =============================================================================
# Removes the ALSA loopback configuration for speaker monitoring.
#
# Usage:
#   sudo ./uninstall-loopback.sh
# =============================================================================

set -e

echo "=========================================="
echo "🗑️  ALSA Loopback Uninstall"
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (sudo ./uninstall-loopback.sh)"
    exit 1
fi

echo ""
echo "1️⃣  Removing ALSA configuration..."

if [ -f /etc/asound.conf ]; then
    # Check if it's our config
    if grep -q "Speaker Monitoring" /etc/asound.conf 2>/dev/null; then
        rm /etc/asound.conf
        echo "   ✓ Removed /etc/asound.conf"
    else
        echo "   ⚠️  /etc/asound.conf exists but wasn't created by us - leaving it"
    fi
else
    echo "   ✓ /etc/asound.conf not present"
fi

echo ""
echo "2️⃣  Removing snd-aloop from auto-load..."

if [ -f /etc/modules-load.d/snd-aloop.conf ]; then
    rm /etc/modules-load.d/snd-aloop.conf
    echo "   ✓ Removed /etc/modules-load.d/snd-aloop.conf"
else
    echo "   ✓ snd-aloop.conf not present"
fi

echo ""
echo "3️⃣  Unloading snd-aloop module..."

if lsmod | grep -q snd_aloop; then
    rmmod snd-aloop 2>/dev/null || echo "   ⚠️  Could not unload snd-aloop (may be in use)"
    echo "   ✓ snd-aloop module unloaded"
else
    echo "   ✓ snd-aloop module not loaded"
fi

echo ""
echo "=========================================="
echo "✅ ALSA Loopback Uninstall Complete!"
echo "=========================================="
echo ""
echo "Speaker monitoring has been disabled."
echo "A reboot may be required for all changes to take effect."
echo ""

