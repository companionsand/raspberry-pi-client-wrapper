# Automatic WiFi AP Conflict Resolution

## Overview

The WiFi access point dnsmasq conflicts are now **automatically resolved** by `launch.sh` on every boot and restart. No manual intervention needed!

## What Was Added

### 1. Pre-Flight Checks in launch.sh (Step 8)

Before starting the client, `launch.sh` automatically:

**If WiFi setup is enabled (`SKIP_WIFI_SETUP != true`):**

1. **Detects system dnsmasq** - Checks if a system-wide dnsmasq service is running
2. **Configures system dnsmasq** - Creates `/etc/dnsmasq.d/99-no-wlan0.conf` to exclude wlan0
   - This tells system dnsmasq to not bind to wlan0
   - Lets NetworkManager use wlan0 for the hotspot
   - Only creates config if it doesn't already exist
3. **Restarts system dnsmasq** - Applies the configuration
4. **Cleans NetworkManager dnsmasq** - Kills any lingering dnsmasq processes from NetworkManager
5. **Removes old hotspot** - Deletes any previous Kin_Hotspot connection
6. **Flushes wlan0 IP** - Clears any old IP addresses from the interface

**If WiFi setup is disabled:**

- Skips all checks (no overhead)

### 2. Restart Cleanup (in main loop)

Before each restart of main.py, `launch.sh` also:

1. **Cleans NetworkManager dnsmasq** - Kills lingering processes
2. **Removes hotspot connection** - Deletes Kin_Hotspot
3. **Flushes wlan0** - Clears IP addresses

This ensures a clean state for every restart.

### 3. Enhanced Cleanup in access_point.py

The Python code also does cleanup:

- Waits 2 seconds after disconnecting (gives NetworkManager time to stop dnsmasq)
- Kills lingering dnsmasq processes with `pkill -f 'dnsmasq.*wlan0'`
- Flushes IP addresses from wlan0
- Resets interface state (down/up)

## How It Works

### On First Boot

```
1. launch.sh starts
2. Step 8: Detect system dnsmasq (PID 888)
3. Create /etc/dnsmasq.d/99-no-wlan0.conf
4. Restart system dnsmasq with new config
5. Clean up NetworkManager dnsmasq processes
6. Clean up old hotspot connections
7. Flush wlan0 IP addresses
8. Start main.py
9. main.py creates WiFi AP successfully ✓
```

### On Subsequent Restarts

```
1. main.py exits (crash, idle timeout, etc.)
2. launch.sh: Clean up WiFi AP resources
3. Kill NetworkManager dnsmasq
4. Delete Kin_Hotspot connection
5. Flush wlan0
6. Check for updates
7. Restart main.py
8. main.py creates WiFi AP successfully ✓
```

## What You'll See in Logs

### Initial Boot

```
[agent-launcher] [INFO] Checking for WiFi access point conflicts...
[agent-launcher] [INFO] WiFi setup enabled - checking for dnsmasq conflicts...
[agent-launcher] [INFO] System dnsmasq detected - configuring to avoid conflicts...
[agent-launcher] [INFO] Creating dnsmasq config to exclude wlan0...
[agent-launcher] [SUCCESS] System dnsmasq configured to exclude wlan0
[agent-launcher] [SUCCESS] WiFi AP pre-flight checks complete
[agent-launcher] [INFO] Starting Kin AI client with idle-time monitoring...
```

### On Restart

```
[agent-launcher] [INFO] main.py stopped, restarting...
[agent-launcher] [INFO] Cleaning up WiFi AP resources before restart...
[agent-launcher] [INFO] Checking for updates before restart...
[agent-launcher] [INFO] Already up to date
[agent-launcher] [INFO] Starting main.py...
```

## Benefits

✅ **Zero manual intervention** - Works automatically on every boot
✅ **Idempotent** - Safe to run multiple times
✅ **Smart detection** - Only runs if WiFi setup is enabled
✅ **Clean restarts** - Resources cleaned up before each restart
✅ **Persistent config** - dnsmasq config survives reboots
✅ **No service disruption** - System dnsmasq keeps running (just excludes wlan0)

## Files Modified

1. **`launch.sh`**

   - Added Step 8: WiFi AP conflict resolution
   - Added cleanup before restarts in main loop

2. **`access_point.py`** (already done)
   - Enhanced `_cleanup_existing()` method
   - Added interface reset logic
   - Added dnsmasq process killing

## Testing

The fix has been tested to handle:

- ✅ System dnsmasq running (most common case)
- ✅ No system dnsmasq
- ✅ Multiple rapid restarts
- ✅ WiFi setup enabled/disabled
- ✅ First boot vs subsequent boots
- ✅ Crashes and clean exits

## Configuration File

The dnsmasq exclusion config is stored at:

```
/etc/dnsmasq.d/99-no-wlan0.conf
```

Content:

```
# Don't bind to wlan0 - let NetworkManager handle it
except-interface=wlan0
```

This file:

- Persists across reboots
- Only created once (idempotent)
- Can be manually deleted if needed
- Won't affect system dnsmasq's other functions

## Rollback

If you need to undo the changes:

```bash
# Remove the config file
sudo rm /etc/dnsmasq.d/99-no-wlan0.conf

# Restart dnsmasq
sudo systemctl restart dnsmasq
```

## No More Manual Fixes!

You no longer need to:

- ❌ Run `fix_dnsmasq_conflict.sh`
- ❌ Manually stop/disable dnsmasq
- ❌ Clean up resources before starting
- ❌ Worry about port conflicts

Everything is handled automatically! 🎉

## Edge Cases

### If System dnsmasq Gets Disabled Later

The script detects whether dnsmasq is running. If it's not running, it skips the configuration step. If you disable system dnsmasq later, the config file remains but has no effect (harmless).

### If WiFi Setup Is Disabled

The entire Step 8 is skipped (checks `SKIP_WIFI_SETUP` in .env). No overhead for systems that don't need WiFi setup.

### If Running Without sudo

The script uses `sudo` for operations that need it. If sudo requires a password, systemd service will need to be configured with appropriate permissions (but typically systemd services run as root or with sudo NOPASSWD).

## Future Improvements (Optional)

Potential enhancements for the future:

1. Add retry logic if NetworkManager isn't ready
2. Verify the fix actually worked before starting main.py
3. Add telemetry to track how often conflicts are detected
4. Automatically adjust dnsmasq config if settings change

But for now, the current implementation should handle all common cases automatically!
