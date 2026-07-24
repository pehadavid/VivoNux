#!/usr/bin/env bash
set -e

# Working directory (repo root, wherever it's been cloned)
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"

echo "1. Querying the kernel.org API for the latest stable version..."
LATEST_STABLE=$(python3 -c "
import urllib.request, json
try:
    with urllib.request.urlopen('https://kernel.org/releases.json') as response:
        data = json.loads(response.read().decode())
        print(data['latest_stable']['version'])
except Exception as e:
    import sys
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
")

echo "Latest stable version identified: $LATEST_STABLE"

SOURCE_URL=$(python3 -c "
import urllib.request, json
try:
    with urllib.request.urlopen('https://kernel.org/releases.json') as response:
        data = json.loads(response.read().decode())
        stable = [r for r in data['releases'] if r['moniker'] == 'stable' and r['version'] == '$LATEST_STABLE'][0]
        print(stable['source'])
except Exception as e:
    import sys
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
")

TARBALL="linux-$LATEST_STABLE.tar.xz"
SRC_DIR="linux-$LATEST_STABLE"

echo "2. Downloading sources from $SOURCE_URL..."
if [ ! -f "$TARBALL" ]; then
    python3 -c "
import urllib.request
print('Downloading (this can take a minute)...')
urllib.request.urlretrieve('$SOURCE_URL', '$TARBALL')
print('Download complete.')
"
else
    echo "Source file $TARBALL is already present."
fi

echo "3. Extracting the archive..."
if [ ! -d "$SRC_DIR" ]; then
    tar -xf "$TARBALL"
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
                patch -p1 --forward --no-backup-if-mismatch < "$p"
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

# Power-saving optimizations
./scripts/config --enable CONFIG_RCU_LAZY
./scripts/config --enable CONFIG_RCU_NOCB_CPU
./scripts/config --enable CONFIG_NO_HZ_IDLE
./scripts/config --disable CONFIG_NO_HZ_FULL

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

echo "6. Applying defaults for new options introduced in $LATEST_STABLE..."
make olddefconfig

echo "7. Starting the native Zen 5 build..."
echo "Debian packages will be generated in $KERNEL_DIR."
make -j$(nproc) KCFLAGS="-march=znver5 -O3" bindeb-pkg
