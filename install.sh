#!/usr/bin/env bash
# Installeur maître VivoNux — transforme un Ubuntu fraîchement installé en VivoNux
# sur une machine identique (ASUS Vivobook S16 / AMD Ryzen AI 9 HX 370 + MediaTek MT7922).
set -e

VIVONUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$VIVONUX_DIR"

echo "=========================================================="
echo "  VivoNux — Installation                                  "
echo "=========================================================="
echo ""

# --- 1. Garde matérielle -------------------------------------------------
echo "=== 1. Vérification du matériel ==="
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "inconnu")

echo "CPU détecté     : $CPU_MODEL"
echo "Modèle détecté  : $PRODUCT_NAME"

if ! echo "$CPU_MODEL" | grep -qiE "HX ?370|HX-370" || ! echo "$PRODUCT_NAME" | grep -qi "vivobook"; then
    echo ""
    echo "⚠️  Ce matériel ne ressemble pas à un ASUS Vivobook S16 / Ryzen AI 9 HX 370."
    echo "    VivoNux applique des réglages spécifiques à cette machine :"
    echo "    - compilation native -march=znver5 (échouera sur un CPU non-Zen5)"
    echo "    - patch et débridage txpower du Wi-Fi MediaTek MT7922"
    echo "    - plafond d'émission radio réglementaire FR (ARCEP/ETSI 20 dBm)"
    echo ""
    read -r -p "Continuer quand même ? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Installation annulée."
        exit 1
    fi
fi

# --- 2. Dépendances de compilation --------------------------------------
echo ""
echo "=== 2. Dépendances de compilation ==="
DEPS=(build-essential libncurses-dev flex bison libssl-dev libelf-dev dwarves python3)
MISSING=()
for pkg in "${DEPS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Installation des paquets manquants : ${MISSING[*]}"
    sudo apt-get update
    sudo apt-get install -y "${MISSING[@]}"
else
    echo "Toutes les dépendances de compilation sont déjà présentes."
fi

# --- 3. Déploiement de la configuration système -------------------------
echo ""
echo "=== 3. Déploiement TLP / udev / sysctl ==="
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
    echo "TLP n'est pas installé — installation (avec tlp-rdw)..."
    sudo apt-get install -y tlp tlp-rdw
    sudo systemctl enable --now tlp
fi
sudo systemctl mask power-profiles-daemon 2>/dev/null || true

sudo sysctl --system >/dev/null 2>&1 || echo "  (avertissement : au moins une clé sysctl n'a pas pu s'appliquer — normal si le module tcp_bbr n'est pas encore chargé sur le noyau actuel, sera résolu après le prochain reboot sur le noyau -pehacorp fraîchement compilé)"

if command -v gdbus >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now kbd-backlight-idle.service
else
    echo "gdbus introuvable (paquet libglib2.0-bin) — service de rétroéclairage clavier ignoré."
fi

# --- 4. Extension GNOME (Charge Complète BAT1) --------------------------
echo ""
echo "=== 4. Widget GNOME de charge batterie ==="
if command -v gnome-shell >/dev/null 2>&1; then
    EXT_DIR="$HOME/.local/share/gnome-shell/extensions/charge-complete-bat1@peha"
    mkdir -p "$EXT_DIR"
    cp -v "$VIVONUX_DIR/gnome-extension/charge-complete-bat1@peha/"*.js "$EXT_DIR/"
    cp -v "$VIVONUX_DIR/gnome-extension/charge-complete-bat1@peha/"*.json "$EXT_DIR/"
    gnome-extensions enable charge-complete-bat1@peha 2>/dev/null \
        || echo "  (le toggle apparaîtra après ouverture de session GNOME)"
else
    echo "GNOME Shell non détecté, extension ignorée."
fi

# --- 5. Compilation et installation du noyau -pehacorp ------------------
echo ""
echo "=== 5. Compilation et installation du noyau (peut prendre longtemps) ==="
bash "$VIVONUX_DIR/update_kernel_master.sh"

echo ""
echo "=========================================================="
echo "  VivoNux installé avec succès !                          "
echo "  - Filet de sécurité GRUB : 5s pour revenir au noyau Ubuntu générique"
echo "  - Redémarre pour activer le nouveau noyau : sudo reboot"
echo "=========================================================="
