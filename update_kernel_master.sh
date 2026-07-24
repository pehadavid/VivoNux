#!/usr/bin/env bash
set -e

# Dossier de travail (racine du dépôt, quel que soit l'endroit où il est cloné)
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"

echo "=========================================================="
echo "  SCRIPT MAÎTRE : Compilation & Installation du Noyau     "
echo "=========================================================="
echo ""

echo "=== 1. Exécution de la compilation du noyau ==="
bash "$KERNEL_DIR/compile_kernel.sh"

echo ""
echo "=== 2. Identification des paquets .deb générés ==="
IMAGE_DEB=$(ls -t "$KERNEL_DIR"/linux-image-*-pehacorp_*.deb 2>/dev/null | head -n 1)
HEADERS_DEB=$(ls -t "$KERNEL_DIR"/linux-headers-*-pehacorp_*.deb 2>/dev/null | head -n 1)

if [ -z "$IMAGE_DEB" ] || [ -z "$HEADERS_DEB" ]; then
  echo "Erreur: Impossible de trouver les paquets .deb générés dans $KERNEL_DIR."
  exit 1
fi

echo "Paquet Image   : $IMAGE_DEB"
echo "Paquet Headers : $HEADERS_DEB"

# Extraction automatique de la version du noyau (ex: 7.1.4-pehacorp)
NEW_KERNEL_VER=$(dpkg-deb -f "$IMAGE_DEB" Package | sed 's/linux-image-//')
echo "Version du noyau identifiée : $NEW_KERNEL_VER"

echo ""
echo "=== 3. Installation des paquets du noyau (sudo dpkg) ==="
sudo dpkg -i "$IMAGE_DEB" "$HEADERS_DEB"

echo ""
echo "=== 4. Configuration de GRUB ==="
GRUB_FILE="/etc/default/grub"

# 1. Définir le nouveau noyau pehacorp par défaut
sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux '"$NEW_KERNEL_VER"'"|' "$GRUB_FILE"

# 2. Conserver le menu GRUB avec un délai de 5 secondes (pour secours sur le noyau d'origine)
sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_FILE"
sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$GRUB_FILE"

echo ""
echo "=== 5. Application de la configuration GRUB ==="
sudo update-grub

echo ""
echo "=== 6. Nettoyage des anciennes builds (conservation des 3 dernières) ==="
KEEP=3
mapfix_versions() {
  ls -t "$KERNEL_DIR"/linux-image-*-pehacorp_*_amd64.deb 2>/dev/null \
    | tail -n +$((KEEP + 1)) \
    | sed -E 's/.*_([0-9][^_]*)_amd64\.deb$/\1/'
}
mapfile -t OLD_VERSIONS < <(mapfix_versions)

if [ "${#OLD_VERSIONS[@]}" -eq 0 ]; then
  echo "Rien à nettoyer (3 builds ou moins présentes)."
else
  for ver in "${OLD_VERSIONS[@]}"; do
    echo "Suppression des fichiers de l'ancienne build $ver..."
    rm -fv "$KERNEL_DIR"/*"_${ver}_amd64".*
  done
fi

echo ""
echo "=========================================================="
echo "  INSTALLATION TERMINÉE AVEC SUCCÈS !"
echo "  - Noyau par défaut : $NEW_KERNEL_VER"
echo "  - Menu GRUB : Actif (5 secondes de sécurité)"
echo "  - Commande pour redémarrer : sudo reboot"
echo "=========================================================="
