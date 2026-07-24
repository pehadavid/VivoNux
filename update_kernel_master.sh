#!/usr/bin/env bash
set -e

# Working directory (repo root, wherever it's been cloned)
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"

echo "=========================================================="
echo "  MASTER SCRIPT: Kernel Build & Installation               "
echo "=========================================================="
echo ""

echo "=== 1. Running the kernel build ==="
bash "$KERNEL_DIR/compile_kernel.sh"

echo ""
echo "=== 2. Identifying the generated .deb packages ==="
IMAGE_DEB=$(ls -t "$KERNEL_DIR"/linux-image-*-pehacorp_*.deb 2>/dev/null | head -n 1)
HEADERS_DEB=$(ls -t "$KERNEL_DIR"/linux-headers-*-pehacorp_*.deb 2>/dev/null | head -n 1)

if [ -z "$IMAGE_DEB" ] || [ -z "$HEADERS_DEB" ]; then
  echo "Error: couldn't find the generated .deb packages in $KERNEL_DIR."
  exit 1
fi

echo "Image package   : $IMAGE_DEB"
echo "Headers package : $HEADERS_DEB"

# Automatically extract the kernel version (e.g. 7.1.4-pehacorp)
NEW_KERNEL_VER=$(dpkg-deb -f "$IMAGE_DEB" Package | sed 's/linux-image-//')
echo "Identified kernel version: $NEW_KERNEL_VER"

echo ""
echo "=== 3. Installing the kernel packages (sudo dpkg) ==="
sudo dpkg -i "$IMAGE_DEB" "$HEADERS_DEB"

echo ""
echo "=== 4. Configuring GRUB ==="
GRUB_FILE="/etc/default/grub"

# 1. Set the new pehacorp kernel as default
sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux '"$NEW_KERNEL_VER"'"|' "$GRUB_FILE"

# 2. Keep the GRUB menu with a 5-second delay (safety net back to the original kernel)
sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_FILE"
sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$GRUB_FILE"

echo ""
echo "=== 5. Applying the GRUB configuration ==="
sudo update-grub

echo ""
echo "=== 6. Cleaning up old builds (keeping the last 3) ==="
KEEP=3
mapfix_versions() {
  ls -t "$KERNEL_DIR"/linux-image-*-pehacorp_*_amd64.deb 2>/dev/null \
    | tail -n +$((KEEP + 1)) \
    | sed -E 's/.*_([0-9][^_]*)_amd64\.deb$/\1/'
}
mapfile -t OLD_VERSIONS < <(mapfix_versions)

if [ "${#OLD_VERSIONS[@]}" -eq 0 ]; then
  echo "Nothing to clean up (3 builds or fewer present)."
else
  for ver in "${OLD_VERSIONS[@]}"; do
    echo "Removing files from old build $ver..."
    rm -fv "$KERNEL_DIR"/*"_${ver}_amd64".*
  done
fi

echo ""
echo "=========================================================="
echo "  INSTALLATION COMPLETE!"
echo "  - Default kernel: $NEW_KERNEL_VER"
echo "  - GRUB menu: active (5-second safety delay)"
echo "  - Reboot command: sudo reboot"
echo "=========================================================="
