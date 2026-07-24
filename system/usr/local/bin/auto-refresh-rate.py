#!/usr/bin/env python3
# Automatic display refresh rate switching for the 3.2K OLED panel:
# 120 Hz on AC (smoothness), 60 Hz on battery (roughly halves scan-out power).
# Talks to Mutter's DisplayConfig on the session D-Bus bus, so it must run as
# a systemd --user service inside the GNOME session (see auto-refresh-rate.service).
import glob
import sys
import time

import dbus

def get_ac_status():
    for path in glob.glob("/sys/class/power_supply/AC*/online") + glob.glob(
        "/sys/class/power_supply/ADP*/online"
    ):
        try:
            with open(path) as f:
                return f.read().strip() == "1"
        except OSError:
            continue
    return False

def set_refresh_rate(rate_hz):
    mode_id = f"3200x2000@{rate_hz}.000"
    try:
        bus = dbus.SessionBus()
        obj = bus.get_object("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig")
        iface = dbus.Interface(obj, "org.gnome.Mutter.DisplayConfig")
        serial, physical_monitors, logical_monitors, properties = iface.GetCurrentState()

        new_logical_monitors = []
        # Index explicitly: the logical monitor struct has a 7th field
        # (properties) that ApplyMonitorsConfig must NOT receive back.
        for lm in logical_monitors:
            x, y, scale, rotation, primary, monitors = lm[0], lm[1], lm[2], lm[3], lm[4], lm[5]
            new_monitors = [(m[0], mode_id, {}) for m in monitors]
            new_logical_monitors.append((x, y, scale, rotation, primary, new_monitors))

        # Method 1 (persistent) instead of 2 (temporary) avoids GNOME's
        # "keep these settings?" confirmation pop-up on every switch.
        iface.ApplyMonitorsConfig(serial, 1, new_logical_monitors, {})
        print(f"[auto-refresh-rate] Applied mode {mode_id}")
        return True
    except Exception as e:
        print(f"[auto-refresh-rate] Failed to apply mode {mode_id}: {e}", file=sys.stderr)
        return False

def main():
    print("[auto-refresh-rate] Starting 60 Hz (battery) / 120 Hz (AC) auto-switching...")
    current_ac = None
    while True:
        ac_online = get_ac_status()
        if ac_online != current_ac:
            target_rate = 120 if ac_online else 60
            print(f"[auto-refresh-rate] Power source: {'AC (120 Hz)' if ac_online else 'battery (60 Hz)'}")
            if set_refresh_rate(target_rate):
                current_ac = ac_online
        time.sleep(2)

if __name__ == "__main__":
    main()
