#!/usr/bin/env bash
# Script d'ajustement dynamique Wi-Fi MT7922 (Secteur vs Batterie) - Norme FR

IFACE="wlp98s0"
if [ ! -d "/sys/class/net/$IFACE" ]; then
    IFACE=$(ls /sys/class/net | grep -E '^wl' | head -n 1)
fi

[ -z "$IFACE" ] && exit 0

ONLINE=$(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -n 1)
if [ -z "$ONLINE" ]; then
    ONLINE=$(cat /sys/class/power_supply/ADP*/online 2>/dev/null | head -n 1)
fi

if [ "$ONLINE" = "1" ]; then
    # Mode SECTEUR : Puissance d'émission maximale FR (20 dBm = 100 mW) & Power Save OFF
    iw dev "$IFACE" set txpower fixed 2000 2>/dev/null || true
    iw dev "$IFACE" set power_save off 2>/dev/null || true
else
    # Mode BATTERIE : Puissance d'émission automatique & Power Save ON
    iw dev "$IFACE" set txpower auto 2>/dev/null || true
    iw dev "$IFACE" set power_save on 2>/dev/null || true
fi
