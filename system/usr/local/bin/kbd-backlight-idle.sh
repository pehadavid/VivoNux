#!/usr/bin/env bash
# VivoNux — turns the keyboard backlight off after one minute of inactivity,
# battery only. Restores the previous brightness as soon as keyboard/trackpad
# activity resumes, or as soon as AC power is plugged back in.
#
# Uses Mutter's IdleMonitor (works under Wayland, unlike xprintidle) and
# UPower's KbdBacklight interface (accessible without sudo, and independent
# of the exact sysfs LED name).

IDLE_THRESHOLD_MS="${VIVONUX_KBD_IDLE_MS:-60000}"
POLL_INTERVAL="${VIVONUX_KBD_POLL_SECONDS:-5}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/vivonux-kbd-backlight-saved"

get_idle_ms() {
    # Output looks like "(uint64 5051,)" — don't run a naive grep -oE '[0-9]+'
    # on this: "uint64" itself contains the digits "64" and would throw the
    # extraction off. Only capture the number that follows "uint64 ".
    gdbus call --session --dest org.gnome.Mutter.IdleMonitor \
        --object-path /org/gnome/Mutter/IdleMonitor/Core \
        --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null \
        | sed -n 's/.*uint64 \([0-9]\+\).*/\1/p'
}

get_brightness() {
    gdbus call --system --dest org.freedesktop.UPower \
        --object-path /org/freedesktop/UPower/KbdBacklight \
        --method org.freedesktop.UPower.KbdBacklight.GetBrightness 2>/dev/null \
        | grep -oE '[0-9]+'
}

set_brightness() {
    gdbus call --system --dest org.freedesktop.UPower \
        --object-path /org/freedesktop/UPower/KbdBacklight \
        --method org.freedesktop.UPower.KbdBacklight.SetBrightness "$1" >/dev/null 2>&1
}

on_ac() {
    local online
    online=$(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -n 1)
    [ -z "$online" ] && online=$(cat /sys/class/power_supply/ADP*/online 2>/dev/null | head -n 1)
    [ "$online" = "1" ]
}

restore_if_saved() {
    if [ -f "$STATE_FILE" ]; then
        set_brightness "$(cat "$STATE_FILE")"
        rm -f "$STATE_FILE"
    fi
}

while true; do
    if on_ac; then
        restore_if_saved
        sleep "$POLL_INTERVAL"
        continue
    fi

    idle_ms=$(get_idle_ms)
    current=$(get_brightness)

    if [ -n "$idle_ms" ] && [ -n "$current" ]; then
        if [ "$idle_ms" -ge "$IDLE_THRESHOLD_MS" ]; then
            if [ "$current" != "0" ]; then
                echo "$current" > "$STATE_FILE"
                set_brightness 0
            fi
        else
            restore_if_saved
        fi
    fi

    sleep "$POLL_INTERVAL"
done
