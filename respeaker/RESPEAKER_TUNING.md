# ReSpeaker Automatic Tuning Configuration

## Overview

This wrapper automatically configures ReSpeaker tuning parameters on every boot to prevent echo/AEC issues that cause false barge-in triggers.

## The Problem

**Symptom**: Agent speech gets interrupted constantly (false barge-ins)

**Root Cause**: ReSpeaker's Auto Gain Control (AGC) amplifies the microphone signal, including echo from the speaker. Even with hardware AEC enabled, if the AGC gain is too high (20+), the echo gets amplified faster than AEC can cancel it, causing the VAD to think the agent's voice is user speech.

**Solution**: Freeze the AGC and set it to a safe gain level (5.0) on every boot.

## How It Works

The `respeaker-init.sh` script runs automatically before the client starts (via `launch.sh`) and configures these parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AGCONOFF` | `0` | Freeze AGC (prevent auto-adjustment) |
| `AGCGAIN` | `5.0` | Set microphone gain to safe level (~14dB) |
| `AECFREEZEONOFF` | `0` | Enable AEC adaptation |
| `ECHOONOFF` | `1` | Enable echo suppression |

## Setup (One-Time)

### 1. Install ReSpeaker Tuning Tools

```bash
# On your Raspberry Pi, clone the ReSpeaker tuning repository
cd ~
git clone https://github.com/respeaker/usb_4_mic_array.git
cd usb_4_mic_array
pip install pyusb
```

### 2. Verify Script Exists

The wrapper should already have `respeaker/respeaker-init.sh` if you've pulled the latest changes. Verify:

```bash
cd ~/raspberry-pi-client-wrapper
ls -l respeaker/respeaker-init.sh
# Should show: -rwxr-xr-x ... respeaker-init.sh
```

If missing, pull the latest wrapper code:

```bash
cd ~/raspberry-pi-client-wrapper
git pull origin main
chmod +x respeaker/respeaker-init.sh
```

### 3. Test Manually (Before Rebooting)

Test the script to make sure it works:

```bash
cd ~/raspberry-pi-client-wrapper
./respeaker/respeaker-init.sh
```

**Expected output:**

```
[respeaker-init] [INFO] Initializing ReSpeaker tuning parameters...
[respeaker-init] [INFO] Applying ReSpeaker configuration:
[respeaker-init] [INFO]   AGCGAIN: 5.0 (microphone gain)
[respeaker-init] [INFO]   AGCONOFF: 0 (0=freeze, 1=auto-adjust)
[respeaker-init] [INFO]   AECFREEZEONOFF: 0 (0=AEC adaptation enabled)
[respeaker-init] [INFO]   ECHOONOFF: 1 (1=echo suppression ON)
[respeaker-init] [SUCCESS]   AGCONOFF set to 0 (verified)
[respeaker-init] [SUCCESS]   AGCGAIN set to 5.0 (verified: 5.0)
[respeaker-init] [SUCCESS]   AECFREEZEONOFF set to 0 (verified)
[respeaker-init] [SUCCESS]   ECHOONOFF set to 1 (verified)
[respeaker-init] [SUCCESS] ReSpeaker initialization complete!
```

### 4. Restart the Client

If the test succeeds, restart the client service to apply the new launch script:

```bash
sudo systemctl restart agent-launcher
```

The script will now run automatically on every boot!

## Customizing Settings

You can override the default values via environment variables in the wrapper `.env` file:

```bash
# Edit wrapper .env (not the client .env!)
cd ~/raspberry-pi-client-wrapper
nano .env
```

Add these lines to customize:

```bash
# ReSpeaker Tuning (optional overrides)
RESPEAKER_AGCGAIN=5.0      # Lower for quieter environments (try 3.0)
RESPEAKER_AGCONOFF=0       # Keep at 0 to freeze AGC
RESPEAKER_AECFREEZEONOFF=0 # Keep at 0 for AEC adaptation
RESPEAKER_ECHOONOFF=1      # Keep at 1 for echo suppression
```

Then restart:

```bash
sudo systemctl restart agent-launcher
```

## Verifying It's Working

### Check Current Settings

```bash
cd ~/usb_4_mic_array
python tuning.py AGCGAIN
python tuning.py AGCONOFF
```

**Expected:**
- `AGCGAIN`: Should be ~5.0 (not 20+)
- `AGCONOFF`: Should be 0

### Test AEC Performance

Run the channel analysis test from the AEC guide:

```bash
cd ~/usb_4_mic_array

# Create test tone
sox -n -r 16000 -c 1 /tmp/test_tone.wav synth 3 sine 440 vol 0.8

# Record during playback
(sleep 2 && aplay -D plughw:3,0 /tmp/test_tone.wav > /dev/null 2>&1) &
arecord -D hw:3,0 -c 6 -f S16_LE -r 16000 -d 6 test_channels.wav
wait

# Check RMS levels
echo "Ch0 (AEC):" && sox test_channels.wav -n remix 1 stat 2>&1 | grep "RMS amplitude"
echo "Ch1 (Raw):" && sox test_channels.wav -n remix 2 stat 2>&1 | grep "RMS amplitude"
```

**Success criteria:**
- Ch0 RMS should be **< 0.20** (good AEC)
- Ch0 should be **lower than Ch1** (AEC is working)

## Troubleshooting

### Script Fails: "usb_4_mic_array directory not found"

Install the tuning tools (see Setup Step 1 above).

### Settings Don't Persist After Reboot

Make sure the `launch.sh` script has been updated. Check for Step 7:

```bash
grep -A 5 "Initialize ReSpeaker" ~/raspberry-pi-client-wrapper/launch.sh
```

If not found, pull the latest wrapper code.

### AGC Gain Still Climbing to 20+

1. Verify `AGCONOFF` is set to 0 (freeze AGC)
2. Check if the script is actually running on boot:

```bash
sudo journalctl -u agent-launcher -n 100 | grep respeaker
```

You should see the initialization messages.

### Still Getting False Barge-Ins

If AGC is frozen at 5.0 but you still have issues:

1. **Lower the gain further**: Try `RESPEAKER_AGCGAIN=3.0` or even `2.0`
2. **Check mechanical isolation**: See AEC_TESTING_GUIDE.md for the "spaghetti test"
3. **Increase barge-in threshold**: See the main response for code changes

## Technical Details

### Why Does AGC Keep Climbing?

When `AGCONOFF` is not set to 0, the AGC actively monitors the microphone input and automatically adjusts `AGCGAIN` to maintain a target level. In quiet environments or when the user is far from the mic, AGC will boost the gain to 20+ to capture speech. This also amplifies echo, defeating the AEC.

By setting `AGCONOFF=0`, we **freeze** the AGC at whatever value we set for `AGCGAIN`, preventing this auto-adjustment.

### Why Run on Every Boot?

The ReSpeaker's tuning parameters are stored in volatile memory (RAM) on the device, not in flash/EEPROM. They reset to defaults on power cycle. That's why we need to reconfigure them on every boot.

### Why Not Use ReSpeaker's EEPROM?

Some ReSpeaker models support saving to EEPROM, but:
1. Not all firmware versions support it
2. It's risky (can brick the device if corrupted)
3. Boot-time configuration is more flexible and debuggable

---

**Created**: December 2025  
**Status**: Active  
**Applies to**: ReSpeaker 4-Mic Array (UAC1.0) with raspberry-pi-client-wrapper

