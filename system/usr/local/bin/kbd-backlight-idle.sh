#!/usr/bin/env bash
# VivoNux — éteint le rétroéclairage clavier après une minute d'inactivité,
# uniquement sur batterie. Restaure la luminosité précédente dès qu'une
# activité clavier/trackpad reprend, ou dès le rebranchement secteur.
#
# Utilise l'IdleMonitor de Mutter (fonctionne sous Wayland, contrairement à
# xprintidle) et l'interface UPower KbdBacklight (accessible sans sudo, et
# indépendante du nom exact du LED sysfs).

IDLE_THRESHOLD_MS="${VIVONUX_KBD_IDLE_MS:-60000}"
POLL_INTERVAL="${VIVONUX_KBD_POLL_SECONDS:-5}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/vivonux-kbd-backlight-saved"

get_idle_ms() {
    # La sortie est du type "(uint64 5051,)" — ne pas faire un grep -oE '[0-9]+'
    # naïf dessus : "uint64" contient lui-même les chiffres "64" et fausserait
    # l'extraction. On capture uniquement le nombre qui suit "uint64 ".
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
