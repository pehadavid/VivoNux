#!/usr/bin/env bash
# VivoNux master installer — turns a freshly installed Ubuntu into VivoNux on
# an identical machine (ASUS Vivobook S16 / AMD Ryzen AI 9 HX 370 + MediaTek MT7922).
set -e

VIVONUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$VIVONUX_DIR"

echo "=========================================================="
echo "  VivoNux — Installation                                  "
echo "=========================================================="
echo ""

# --- 1. Hardware guard ---------------------------------------------------
echo "=== 1. Hardware check ==="
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")

echo "Detected CPU     : $CPU_MODEL"
echo "Detected model   : $PRODUCT_NAME"

if ! echo "$CPU_MODEL" | grep -qiE "HX ?370|HX-370" || ! echo "$PRODUCT_NAME" | grep -qi "vivobook"; then
    echo ""
    echo "⚠️  This hardware doesn't look like an ASUS Vivobook S16 / Ryzen AI 9 HX 370."
    echo "    VivoNux applies settings specific to that machine:"
    echo "    - native -march=znver5 compilation (will fail on a non-Zen5 CPU)"
    echo "    - MediaTek MT7922 Wi-Fi patch and txpower unlocking"
    echo "    - French (ARCEP/ETSI) regulatory radio transmit power cap"
    echo ""
    read -r -p "Continue anyway? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 1
    fi
fi

# --- 2. Build dependencies ------------------------------------------------
echo ""
echo "=== 2. Build dependencies ==="
DEPS=(build-essential libncurses-dev flex bison libssl-dev libelf-dev dwarves python3)
MISSING=()
for pkg in "${DEPS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Installing missing packages: ${MISSING[*]}"
    sudo apt-get update
    sudo apt-get install -y "${MISSING[@]}"
else
    echo "All build dependencies are already present."
fi

# --- 3. System configuration deployment -----------------------------------
echo ""
echo "=== 3. TLP / udev / sysctl deployment ==="
sudo cp -v "$VIVONUX_DIR/system/etc/tlp.d/99-amd-power-savings.conf" /etc/tlp.d/
sudo cp -v "$VIVONUX_DIR/system/etc/udev/rules.d/99-wifi-power-mode.rules" /etc/udev/rules.d/
sudo cp -v "$VIVONUX_DIR/system/etc/udev/rules.d/99-battery-charge-limit.rules" /etc/udev/rules.d/
sudo cp -v "$VIVONUX_DIR/system/etc/sysctl.d/99-pehacorp-network.conf" /etc/sysctl.d/
sudo install -m 0755 "$VIVONUX_DIR/system/usr/local/bin/wifi-power-mode.sh" /usr/local/bin/wifi-power-mode.sh
sudo install -m 0755 "$VIVONUX_DIR/system/usr/local/bin/kbd-backlight-idle.sh" /usr/local/bin/kbd-backlight-idle.sh
sudo mkdir -p /etc/systemd/user
sudo cp -v "$VIVONUX_DIR/system/etc/systemd/user/kbd-backlight-idle.service" /etc/systemd/user/

sudo udevadm control --reload-rules
sudo udevadm trigger

if dpkg -s tlp >/dev/null 2>&1; then
    sudo systemctl enable --now tlp
else
    echo "TLP isn't installed — installing it (with tlp-rdw)..."
    sudo apt-get install -y tlp tlp-rdw
    sudo systemctl enable --now tlp
fi
sudo systemctl mask power-profiles-daemon 2>/dev/null || true

sudo sysctl --system >/dev/null 2>&1 || echo "  (warning: at least one sysctl key couldn't be applied — expected if the tcp_bbr module isn't loaded on the currently running kernel yet, resolves itself after the next reboot into the freshly built -pehacorp kernel)"

if command -v gdbus >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now kbd-backlight-idle.service
else
    echo "gdbus not found (libglib2.0-bin package) — keyboard backlight service skipped."
fi

# --- 4. GNOME extension (Full Charge BAT1) --------------------------------
echo ""
echo "=== 4. Battery charge GNOME widget ==="
if command -v gnome-shell >/dev/null 2>&1; then
    EXT_SRC="$VIVONUX_DIR/gnome-extension/charge-complete-bat1@peha"
    EXT_DIR="$HOME/.local/share/gnome-shell/extensions/charge-complete-bat1@peha"
    mkdir -p "$EXT_DIR"
    cp -v "$EXT_SRC/"*.js "$EXT_DIR/"
    cp -v "$EXT_SRC/"*.json "$EXT_DIR/"
    if [ -d "$EXT_SRC/locale" ]; then
        cp -rv "$EXT_SRC/locale" "$EXT_DIR/"
    fi
    gnome-extensions enable charge-complete-bat1@peha 2>/dev/null \
        || echo "  (the toggle will show up after opening a GNOME session)"
else
    echo "GNOME Shell not detected, extension skipped."
fi

# --- 5. Build and install the -pehacorp kernel ----------------------------
echo ""
echo "=== 5. Kernel build and installation (can take a while) ==="
bash "$VIVONUX_DIR/update_kernel_master.sh"

echo ""
echo "=========================================================="
echo "  VivoNux installed successfully!                         "
echo "  - GRUB safety net: 5s to fall back to the generic Ubuntu kernel"
echo "  - Reboot to activate the new kernel: sudo reboot"
echo "=========================================================="
