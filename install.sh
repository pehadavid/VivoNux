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

# --- 1. Kernel channel selection -------------------------------------------
echo "=== 1. Kernel channel ==="
echo "Querying kernel.org for available channels..."
KERNEL_CHANNEL_INFO=$(python3 -c "
import urllib.request, json, re, sys
try:
    with urllib.request.urlopen('https://kernel.org/releases.json') as response:
        data = json.loads(response.read().decode())
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)

print(f\"STABLE_VERSION={data['latest_stable']['version']}\")
mainline = next((r for r in data['releases'] if r['moniker'] == 'mainline'), None)
if mainline:
    if re.search(r'-rc[0-9]+\$', mainline['version']):
        print(f\"RC_VERSION={mainline['version']}\")
    else:
        print(f\"BETA_VERSION={mainline['version']}\")
")
eval "$KERNEL_CHANNEL_INFO"

echo "  1) stable -- $STABLE_VERSION  (default, becomes the GRUB default kernel)"
if [ -n "${RC_VERSION:-}" ]; then
    echo "  2) rc     -- $RC_VERSION  (release candidate, installed but NOT set as GRUB default)"
fi
if [ -n "${BETA_VERSION:-}" ]; then
    echo "  2) beta   -- $BETA_VERSION  (mainline dev snapshot, installed but NOT set as GRUB default)"
fi
if [ -z "${RC_VERSION:-}${BETA_VERSION:-}" ]; then
    echo "  (no mainline RC or beta currently published on kernel.org)"
fi

VIVONUX_KERNEL_CHANNEL="stable"
if [ -n "${RC_VERSION:-}${BETA_VERSION:-}" ]; then
    read -r -p "Which kernel line to build? [stable] " CHANNEL_REPLY
    case "${CHANNEL_REPLY,,}" in
        rc)
            if [ -n "${RC_VERSION:-}" ]; then
                VIVONUX_KERNEL_CHANNEL="rc"
            else
                echo "No RC currently published, falling back to stable."
            fi
            ;;
        beta)
            if [ -n "${BETA_VERSION:-}" ]; then
                VIVONUX_KERNEL_CHANNEL="beta"
            else
                echo "No beta snapshot currently published, falling back to stable."
            fi
            ;;
        ""|stable) ;;
        *) echo "Unrecognized answer, falling back to stable." ;;
    esac
fi
export VIVONUX_KERNEL_CHANNEL
echo "Selected channel: $VIVONUX_KERNEL_CHANNEL"

# --- 2. Hardware guard ---------------------------------------------------
echo ""
echo "=== 2. Hardware check ==="
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

# --- 3. Build dependencies ------------------------------------------------
echo ""
echo "=== 3. Build dependencies ==="
DEPS=(build-essential libncurses-dev flex bison libssl-dev libelf-dev dwarves python3 python3-dbus)
if [ -n "${VIVONUX_ICC_PROFILE:-}" ]; then
    DEPS+=(colord)
fi
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

# --- 4. System configuration deployment -----------------------------------
echo ""
echo "=== 4. TLP / udev / sysctl deployment ==="
sudo cp -v "$VIVONUX_DIR/system/etc/tlp.d/99-amd-power-savings.conf" /etc/tlp.d/
sudo cp -v "$VIVONUX_DIR/system/etc/udev/rules.d/99-wifi-power-mode.rules" /etc/udev/rules.d/
sudo cp -v "$VIVONUX_DIR/system/etc/udev/rules.d/99-battery-charge-limit.rules" /etc/udev/rules.d/
sudo cp -v "$VIVONUX_DIR/system/etc/sysctl.d/99-pehacorp-network.conf" /etc/sysctl.d/
sudo install -m 0755 "$VIVONUX_DIR/system/usr/local/bin/wifi-power-mode.sh" /usr/local/bin/wifi-power-mode.sh
sudo install -m 0755 "$VIVONUX_DIR/system/usr/local/bin/kbd-backlight-idle.sh" /usr/local/bin/kbd-backlight-idle.sh
sudo install -m 0755 "$VIVONUX_DIR/system/usr/local/bin/auto-refresh-rate.py" /usr/local/bin/auto-refresh-rate.py
sudo mkdir -p /etc/systemd/user
sudo cp -v "$VIVONUX_DIR/system/etc/systemd/user/kbd-backlight-idle.service" /etc/systemd/user/
sudo cp -v "$VIVONUX_DIR/system/etc/systemd/user/auto-refresh-rate.service" /etc/systemd/user/

# Migrate away from any pre-VivoNux copy of the refresh-rate service that
# lived in the user's home (pointed at a script outside this repo).
if [ -f "$HOME/.config/systemd/user/auto-refresh-rate.service" ]; then
    echo "Removing the stale user-local auto-refresh-rate.service (replaced by /etc/systemd/user/)..."
    systemctl --user disable --now auto-refresh-rate.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/auto-refresh-rate.service"
fi

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
    systemctl --user enable --now auto-refresh-rate.service
else
    echo "gdbus not found (libglib2.0-bin package) — keyboard backlight and refresh-rate services skipped."
fi

# --- 5. GNOME extension (Full Charge BAT1) --------------------------------
echo ""
echo "=== 5. Battery charge GNOME widget ==="
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

# --- 6. GNOME extension (Game Mode) -----------------------------------------
echo ""
echo "=== 6. Game Mode GNOME widget ==="
if command -v gnome-shell >/dev/null 2>&1; then
    EXT_SRC="$VIVONUX_DIR/gnome-extension/game-mode@peha"
    EXT_DIR="$HOME/.local/share/gnome-shell/extensions/game-mode@peha"
    mkdir -p "$EXT_DIR"
    cp -v "$EXT_SRC/"*.js "$EXT_DIR/"
    cp -v "$EXT_SRC/"*.json "$EXT_DIR/"
    cp -v "$EXT_SRC/"*.css "$EXT_DIR/"
    if [ -d "$EXT_SRC/locale" ]; then
        cp -rv "$EXT_SRC/locale" "$EXT_DIR/"
    fi
    gnome-extensions enable game-mode@peha 2>/dev/null \
        || echo "  (the toggle will show up after opening a GNOME session)"
else
    echo "GNOME Shell not detected, extension skipped."
fi

# --- 7. Optional internal display color profile ----------------------------
echo ""
echo "=== 7. Internal OLED color profile ==="
if [ -n "${VIVONUX_ICC_PROFILE:-}" ]; then
    bash "$VIVONUX_DIR/install-color-profile.sh" "$VIVONUX_ICC_PROFILE"
else
    echo "No ICC profile supplied (optional)."
    echo "To install the bundled default later: ./install-color-profile.sh"
    echo "Or rerun with: VIVONUX_ICC_PROFILE=./ATNA60BX01-1.icc ./install.sh"
fi

# --- 8. Build and install the -pehacorp kernel ----------------------------
echo ""
echo "=== 8. Kernel build and installation (can take a while) ==="
bash "$VIVONUX_DIR/update_kernel_master.sh"

# --- 9. Optional cleanup ---------------------------------------------------
echo ""
echo "=== 9. Cleanup ==="
read -r -p "Clean up the folder now (old kernel sources/builds no longer used)? [y/N] " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    bash "$VIVONUX_DIR/cleanup.sh"
else
    echo "Skipped. Run ./cleanup.sh any time (or ./cleanup.sh --dry-run to preview)."
fi

echo ""
echo "=========================================================="
echo "  VivoNux installed successfully!                         "
echo "  - GRUB safety net: 5s to fall back to the generic Ubuntu kernel"
echo "  - Reboot to activate the new kernel: sudo reboot"
echo "=========================================================="
