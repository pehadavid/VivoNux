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

# 3. Kernel command line (tracked here so the repo is the single source of truth).
#    - amdgpu.abmlevel=3              : static ABM level. On this OLED panel, the driver
#      reports aux_support=true unconditionally (drivers/gpu/drm/amd/display/amdgpu_dm/
#      amdgpu_dm.c: amdgpu_dm_should_create_sysfs()), so panel_power_savings never
#      appears in sysfs, and the DRM ABM property is explicitly withheld for OLED
#      panels too (same file, ~line 5498) — this boot parameter is the ONLY way to
#      set ABM on this hardware. Leaving it unset doesn't make ABM "dynamic", it
#      leaves amdgpu_dm_abm_level at its default (-1), which the driver then forces
#      to ABM_LEVEL_IMMEDIATE_DISABLE (same file, ~line 7911) — i.e. ABM permanently
#      OFF on both AC and battery. Confirmed the hard way on 2026-07-24: don't remove
#      this again to chase a dynamic AC/battery ABM switch, it isn't possible here.
#    - amd_prefcore=enable            : AMD Preferred Cores (Zen 5 / Zen 5c steering)
#    - workqueue.power_efficient=y    : power-efficient workqueues
#    - nmi_watchdog=0                 : no periodic NMI wakeups
#    - split_lock_detect=off          : no split-lock penalty (gaming)
#    - cpuidle.governor=teo           : better C-state selection than menu on modern Zen
CMDLINE='quiet splash amdgpu.abmlevel=3 amd_prefcore=enable workqueue.power_efficient=y nmi_watchdog=0 split_lock_detect=off cpuidle.governor=teo'
sudo sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="'"$CMDLINE"'"|' "$GRUB_FILE"

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
