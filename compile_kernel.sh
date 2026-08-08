#!/usr/bin/env bash
set -e

# Working directory (repo root, wherever it's been cloned)
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"

KERNEL_CHANNEL="${VIVONUX_KERNEL_CHANNEL:-stable}"
case "$KERNEL_CHANNEL" in
    stable|rc|beta) ;;
    *)
        echo "ERROR: unrecognized VIVONUX_KERNEL_CHANNEL '$KERNEL_CHANNEL' (expected stable, rc or beta)."
        exit 1
        ;;
esac
echo "1. Querying the kernel.org API for the '$KERNEL_CHANNEL' channel..."
KERNEL_INFO=$(python3 -c "
import urllib.request, json, re, sys

channel = '$KERNEL_CHANNEL'
try:
    with urllib.request.urlopen('https://kernel.org/releases.json') as response:
        data = json.loads(response.read().decode())
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)

if channel == 'stable':
    rel = data['latest_stable']
    rel = [r for r in data['releases'] if r['moniker'] == 'stable' and r['version'] == rel['version']][0]
else:
    mainline = next((r for r in data['releases'] if r['moniker'] == 'mainline'), None)
    if mainline is None:
        print('ERROR: no mainline release published on kernel.org', file=sys.stderr)
        sys.exit(1)
    is_rc = bool(re.search(r'-rc[0-9]+\$', mainline['version']))
    if channel == 'rc' and not is_rc:
        print('ERROR: no RC currently published (mainline is in the pre-rc1 merge window)', file=sys.stderr)
        sys.exit(1)
    if channel == 'beta' and is_rc:
        print('ERROR: no beta snapshot currently published (mainline is in RC phase)', file=sys.stderr)
        sys.exit(1)
    rel = mainline

print(rel['version'])
print(rel['source'])
")
KERNEL_VERSION=$(echo "$KERNEL_INFO" | sed -n '1p')
SOURCE_URL=$(echo "$KERNEL_INFO" | sed -n '2p')

echo "Version identified: $KERNEL_VERSION"
if [ "$KERNEL_CHANNEL" != "stable" ]; then
    echo "NOTE: '$KERNEL_CHANNEL' channel selected -- this build will NOT be set as the GRUB default kernel."
fi

SRC_DIR="linux-$KERNEL_VERSION"

if [ "$KERNEL_CHANNEL" = "stable" ]; then
    TARBALL="linux-$KERNEL_VERSION.tar.xz"
else
    # kernel.org's own source for mainline/rc (git.kernel.org/torvalds/t/...)
    # sits behind an Anubis anti-bot JS challenge and rejects plain scripted
    # downloads with HTTP 403 -- use GitHub's official read-only mirror of
    # Linus' tree instead, which serves every tag/branch without that gate.
    if [ "$KERNEL_CHANNEL" = "rc" ]; then
        SOURCE_URL="https://github.com/torvalds/linux/archive/refs/tags/v${KERNEL_VERSION}.tar.gz"
    else
        SOURCE_URL="https://github.com/torvalds/linux/archive/refs/heads/master.tar.gz"
    fi
    TARBALL="linux-$KERNEL_VERSION.tar.gz"
fi

echo "2. Downloading sources from $SOURCE_URL..."
if [ ! -f "$TARBALL" ]; then
    python3 -c "
import urllib.request
print('Downloading (this can take a minute)...')
req = urllib.request.Request('$SOURCE_URL', headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req) as response, open('$TARBALL', 'wb') as out:
    out.write(response.read())
print('Download complete.')
"
else
    echo "Source file $TARBALL is already present."
fi

echo "3. Extracting the archive..."
if [ ! -d "$SRC_DIR" ]; then
    # The GitHub mirror names the top-level directory after the ref (e.g. a
    # 'master' branch snapshot extracts as 'linux-master', not '$SRC_DIR') --
    # extract then rename so incremental-build detection above keeps working.
    TOP_DIR=$(tar -tf "$TARBALL" | head -n1 | cut -d/ -f1)
    tar -xf "$TARBALL"
    if [ "$TOP_DIR" != "$SRC_DIR" ]; then
        mv "$TOP_DIR" "$SRC_DIR"
    fi
else
    echo "Source directory $SRC_DIR already exists (kept for incremental builds)."
fi

cd "$SRC_DIR"

echo "3b. Applying hardware and Wi-Fi patches (if present in $KERNEL_DIR/patches)..."
PATCH_STAMP=".pehacorp-patches-applied"
if [ -d "$KERNEL_DIR/patches" ]; then
    if [ -f "$PATCH_STAMP" ]; then
        echo "Patches already applied to this source tree (stamp $PATCH_STAMP present), not reapplying."
    else
        for p in "$KERNEL_DIR/patches"/*.patch; do
            if [ -f "$p" ]; then
                echo "Applying patch: $(basename "$p")"
                # Some patches target files specific to one kernel line (e.g. rc-only
                # drivers not present in stable) -- don't let one irrelevant patch
                # abort the whole build, just flag it for manual review.
                if ! patch -p1 --forward --no-backup-if-mismatch < "$p"; then
                    echo "WARNING: patch $(basename "$p") did not apply cleanly against $SRC_DIR (kernel source has likely diverged, or this patch doesn't target this kernel line) -- skipped, verify manually."
                fi
            fi
        done
        touch "$PATCH_STAMP"
    fi
fi

echo "4. Configuring the kernel..."
if [ -f .config ]; then
    echo "A .config already exists in $SRC_DIR, reusing it as-is (preserves incremental builds)."
else
    echo "No existing .config, initializing from the active kernel (has every generic driver)..."
    cp /boot/config-$(uname -r) .config
fi

echo "5. Applying power-saving, gaming and suffix optimizations..."
# Kernel suffix
./scripts/config --set-str CONFIG_LOCALVERSION "-pehacorp"

# Power-saving optimizations.
# The whole RCU chain must be enabled explicitly: RCU_NOCB_CPU depends on
# RCU_EXPERT, and RCU_LAZY depends on RCU_NOCB_CPU — without RCU_EXPERT,
# olddefconfig silently drops all of them (found missing for real in the
# installed 7.1.4-pehacorp config on 2026-07-24, same failure mode as the
# BBR regression below). RCU_NOCB_CPU_DEFAULT_ALL offloads every CPU without
# needing an rcu_nocbs= boot parameter, which is what makes RCU_LAZY
# actually take effect.
./scripts/config --enable CONFIG_RCU_EXPERT
./scripts/config --enable CONFIG_RCU_NOCB_CPU
./scripts/config --enable CONFIG_RCU_NOCB_CPU_DEFAULT_ALL
./scripts/config --enable CONFIG_RCU_LAZY
./scripts/config --disable CONFIG_RCU_LAZY_DEFAULT_OFF
./scripts/config --enable CONFIG_NO_HZ_IDLE
./scripts/config --disable CONFIG_NO_HZ_FULL

# USB game controllers (Xbox/DualSense/etc): found CONFIG_USB_HID silently
# disabled in the installed 7.1.4-pehacorp config on 2026-07-25 (no gamepad
# was recognized at all, USB devices looped connect/disconnect in dmesg since
# nothing claimed the interface) — same "silently dropped Kconfig option"
# failure mode as BBR/RCU above, just never forced explicitly before. Ubuntu's
# own base config ships all of these as modules (debian.master/config/
# annotations), so this only regresses via an unguarded olddefconfig on a
# reused .config.
# HID_PLAYSTATION and HID_LOGITECH both `depends on LEDS_CLASS_MULTICOLOR`
# (drivers/hid/Kconfig), which was itself off in the base config — without
# forcing it first, olddefconfig silently drops both regardless of the
# --enable below (caught by the 6b guard on 2026-07-25, 7.1.5 build).
./scripts/config --enable CONFIG_LEDS_CLASS_MULTICOLOR
./scripts/config --enable CONFIG_USB_HID
./scripts/config --enable CONFIG_JOYSTICK_XPAD
./scripts/config --enable CONFIG_JOYSTICK_XPAD_FF
./scripts/config --enable CONFIG_JOYSTICK_XPAD_LEDS
./scripts/config --enable CONFIG_HID_MICROSOFT
./scripts/config --enable CONFIG_HID_SONY
./scripts/config --enable CONFIG_HID_PLAYSTATION
./scripts/config --enable CONFIG_HID_LOGITECH

# Bluetooth game controllers (8BitDo SN30 Pro, etc): CONFIG_BT_HIDP was absent
# from the installed 7.2.0-rc5-pehacorp config (found 2026-08-05) — bluetoothd
# fails with "Can't open HIDP control socket" / "Host is down" because the
# hidp module (net/bluetooth/hidp) doesn't even exist under /lib/modules,
# unlike its sibling bnep which builds fine. Depends on BT_BREDR (on by
# default) && HID (already forced above), so no dependency chain to drag in —
# just never forced explicitly before. Same silently-dropped-Kconfig failure
# mode as USB_HID/JOYSTICK_XPAD above, one layer over in the Bluetooth stack.
./scripts/config --enable CONFIG_BT_HIDP

# Wired Nintendo Switch Pro Controller / 8BitDo in Switch mode over USB:
# CONFIG_HID_NINTENDO absent from the installed 7.2.0-rc6-pehacorp config
# (found 2026-08-07) — device enumerates fine (057e:2009, "Pro Controller"
# in the USB strings) and hid-generic claims it, so RetroArch sees a device
# named "Switch Pro Controller", but hid-generic never sends the vendor
# init handshake the Nintendo protocol needs, so no usable button/stick
# reports come through. Depends on NEW_LEDS + LEDS_CLASS, both already y
# in the base config, so nothing else to drag in.
./scripts/config --enable CONFIG_HID_NINTENDO

# USB mass storage (external drives, USB SD/MMC card readers): found both
# CONFIG_USB_STORAGE and CONFIG_USB_UAS absent from the installed
# 7.1.5-pehacorp config on 2026-07-31 (the internal USB SD card reader,
# 058f:6366, enumerates fine as a USB Mass Storage interface — class 08,
# subclass 06, protocol 50 — but nothing ever binds to it: no usb-storage or
# uas module even exists under /lib/modules). Same silently-dropped-Kconfig
# failure mode as BBR/RCU/HID above, never forced explicitly before.
./scripts/config --enable CONFIG_USB_STORAGE
./scripts/config --enable CONFIG_USB_UAS

# Filesystems for removable media: VFAT/FAT_FS were already on in the base
# config, but CONFIG_EXFAT_FS and CONFIG_NTFS3_FS were both absent — most SD
# cards 64GB+ ship pre-formatted exFAT, so even with USB_STORAGE/UAS fixed
# above the block device would show up but fail to mount. Forcing both so
# the block layer and the filesystem layer don't regress independently.
./scripts/config --enable CONFIG_FAT_FS
./scripts/config --enable CONFIG_VFAT_FS
./scripts/config --enable CONFIG_EXFAT_FS
./scripts/config --enable CONFIG_NTFS3_FS

# Frequency and scheduling for gaming (1000 HZ, Preferred Cores)
./scripts/config --disable CONFIG_HZ_100
./scripts/config --disable CONFIG_HZ_250
./scripts/config --disable CONFIG_HZ_300
./scripts/config --enable CONFIG_HZ_1000
./scripts/config --set-val CONFIG_HZ 1000
./scripts/config --enable CONFIG_SCHED_MC_PRIO

# Dynamic preemption (full while gaming, voluntary on battery)
./scripts/config --enable CONFIG_PREEMPT_DYNAMIC

# TCP BBR (required by /etc/sysctl.d/99-pehacorp-network.conf): forced explicitly
# on every build, otherwise an olddefconfig on a base .config that no longer has
# it (happens on a version jump) leaves it silently disabled — happened for real
# on 2026-07-24 on the 7.1.4-pehacorp kernel (CONFIG_TCP_CONG_BBR missing even
# though Ubuntu's own generic base config had it as a module).
./scripts/config --enable CONFIG_TCP_CONG_BBR

# Disable Ubuntu-specific trusted keys (avoids missing-key build errors)
./scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# Strip debug symbols to cut build time by 10x and save space
./scripts/config --disable CONFIG_DEBUG_INFO
./scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
./scripts/config --disable CONFIG_DEBUG_INFO_DWARF4
./scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
./scripts/config --disable CONFIG_DEBUG_INFO_BTF
./scripts/config --disable CONFIG_DEBUG_INFO_COMPRESSED
./scripts/config --disable CONFIG_DEBUG_INFO_REDUCED
./scripts/config --disable CONFIG_DEBUG_INFO_SPLIT

echo "6. Applying defaults for new options introduced in $KERNEL_VERSION..."
make olddefconfig

echo "6b. Verifying that no critical option was silently dropped by olddefconfig..."
# Guard against the BBR/RCU class of regression: an option we force above can
# be discarded without any error if one of its dependencies is missing in the
# base config. Fail the build instead of shipping a kernel without them.
CRITICAL_OPTIONS=(
    CONFIG_RCU_EXPERT
    CONFIG_RCU_NOCB_CPU
    CONFIG_RCU_NOCB_CPU_DEFAULT_ALL
    CONFIG_RCU_LAZY
    CONFIG_TCP_CONG_BBR
    CONFIG_HZ_1000
    CONFIG_SCHED_MC_PRIO
    CONFIG_PREEMPT_DYNAMIC
    CONFIG_USB_HID
    CONFIG_JOYSTICK_XPAD
    CONFIG_HID_MICROSOFT
    CONFIG_HID_SONY
    CONFIG_HID_PLAYSTATION
    CONFIG_HID_LOGITECH
    CONFIG_BT_HIDP
    CONFIG_HID_NINTENDO
    CONFIG_LEDS_CLASS_MULTICOLOR
    CONFIG_USB_STORAGE
    CONFIG_USB_UAS
    CONFIG_FAT_FS
    CONFIG_VFAT_FS
    CONFIG_EXFAT_FS
    CONFIG_NTFS3_FS
)
CONFIG_ERRORS=0
for opt in "${CRITICAL_OPTIONS[@]}"; do
    if ! grep -qE "^${opt}=(y|m)$" .config; then
        echo "ERROR: $opt is missing from the final .config (silently dropped by olddefconfig)."
        CONFIG_ERRORS=1
    fi
done
if [ "$CONFIG_ERRORS" -ne 0 ]; then
    echo "Aborting the build: fix the dependency chain in compile_kernel.sh first."
    exit 1
fi
echo "All critical options verified present."

echo "7. Starting the native Zen 5 build..."
echo "Debian packages will be generated in $KERNEL_DIR."
make -j$(nproc) KCFLAGS="-march=znver5 -O3" bindeb-pkg
