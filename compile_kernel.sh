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
