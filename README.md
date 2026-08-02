# VivoNux

**[English](#english)** · **[Français](#français)**

---

## English

**VivoNux** turns a standard Ubuntu install into a perf/battery-life optimized environment for one
specific machine: **ASUS Vivobook S16 with an AMD Ryzen AI 9 HX 370 (Zen 5)** and a **MediaTek
MT7922 (`mt7921e`)** Wi-Fi card.

⚠️ **This is not a generic project.** The compiler flags (`-march=znver5`), the Wi-Fi patch, and
the regulatory radio transmit power cap (FR/ARCEP) are specific to this hardware. Don't install
this on another machine without reading every section below first.

The mantra: **performance on AC power, battery life on battery**, while keeping every generic
Ubuntu hardware driver intact (nothing is removed, only tuned/patched).

⚠️ **Secure Boot must be disabled first.** The `-pehacorp` kernel is self-compiled and unsigned
(`compile_kernel.sh` resets `CONFIG_SYSTEM_TRUSTED_KEYS`/`CONFIG_SYSTEM_REVOCATION_KEYS`), so with
Secure Boot enabled the firmware will refuse to boot it (or the third-party Wi-Fi/GPU modules will
fail to load). Disable Secure Boot in the UEFI/BIOS settings **before** running `install.sh` or
`update_kernel_master.sh`.

### 🚀 Quick install

On a freshly installed Ubuntu, on an identical machine:

```bash
git clone https://github.com/pehadavid/VivoNux.git
cd VivoNux
./install.sh
```

`install.sh` checks the hardware, installs the build dependencies, deploys the system
configuration (TLP/udev/sysctl), installs the GNOME widget, then builds and installs the
`-pehacorp` kernel (details below). Expect the build to take a while. At the end:

```bash
sudo reboot
```

The GRUB menu keeps a 5-second safety delay so you can fall back to the generic Ubuntu kernel if
anything goes wrong.

### Kernel channel: stable, rc, beta

`install.sh` starts by querying `kernel.org` and asking which line to build:

- **stable** (default): the latest stable release. Becomes the **GRUB default** kernel, like before.
- **rc**: the current mainline release candidate (`X.Y-rcN`), only offered while one is published.
- **beta**: the current mainline development snapshot (pre-`rc1`, merge-window head), only offered
  while no RC is published — `rc` and `beta` are two states of the same kernel.org `mainline`
  moniker, never both available at once.

`rc` and `beta` are built and installed like any other kernel, but **`update_kernel_master.sh`
never sets them as the GRUB default** — they only show up under "Advanced options for Ubuntu" so
you opt in to booting an unstable kernel instead of it happening automatically. Answering with
just Enter (or anything unrecognized) always falls back to `stable`. Kernel updates run later via
`./update_kernel_master.sh` directly reuse `stable` unless `VIVONUX_KERNEL_CHANNEL=rc` (or `beta`)
is exported first.

`stable` sources still come straight from `cdn.kernel.org`. `rc`/`beta` sources come from GitHub's
official read-only mirror of Linus' tree ([`torvalds/linux`](https://github.com/torvalds/linux))
instead of `git.kernel.org`: kernel.org's own snapshot endpoint for mainline sits behind an
anti-bot JS challenge that rejects plain scripted downloads (HTTP 403), which GitHub's mirror
doesn't have.

### 📁 Repository layout

```text
install.sh                    # Master installer (entry point on a fresh machine)
install-color-profile.sh      # Installs an optional ICC profile for the internal OLED
compile_kernel.sh             # Downloads, patches and builds the -pehacorp kernel
update_kernel_master.sh       # Builds + installs the .deb packages + configures GRUB
cleanup.sh                    # Removes unused kernel sources/old builds (see below)
patches/                      # Patches automatically applied to the kernel sources
system/etc/...                # Mirrors /etc: TLP, udev, sysctl (deployed as-is)
system/usr/local/bin/...      # Mirrors /usr/local/bin: system scripts
gnome-extension/...           # GNOME Quick Settings widget (battery charge)
```

Downloaded kernel sources, compiled `.deb` packages and tarballs (several GB) are **not** tracked
(see `.gitignore`) — they're regenerated on demand by the build.

#### 🧹 Cleaning up unused sources and old builds

Each build leaves the previous kernel source tarball/directory and a few `.deb` build
revisions on disk (several GB). `install.sh` offers to run [`cleanup.sh`](cleanup.sh) at the
end of installation; it can also be run any time on its own:

```bash
./cleanup.sh            # removes everything not needed by the current build
./cleanup.sh --dry-run  # preview what would be removed, deletes nothing
```

It always keeps the source tarball/directory and `.deb` set matching the most recently built
kernel in this folder (so incremental rebuilds and reinstalls still work), and removes: older
kernel.org source archives/directories, older `.deb`/`.buildinfo`/`.changes` build revisions,
and leftover files from an unrelated legacy build (Debian source package for kernel 7.0.0).

### 🛠️ Optimizations and Architectural Choices

The kernel is built from the official **Mainline** sources (kernel.org), starting from Ubuntu's
full hardware base, with the following performance and power-saving optimizations layered on top:

#### 1. Native Zen 5 Build

- **Compiler flags**: `KCFLAGS="-march=znver5 -O3"`
- **Benefit**: full use of Zen 5's hardware instructions (AVX-512, deep vectorization) plus `-O3` execution tuning.

#### 2. Responsiveness & Gaming Performance

- **Tick frequency (`CONFIG_HZ_1000=y`)**: 1000 Hz system clock to minimize input latency and jitter.
- **Dynamic Preemption (`CONFIG_PREEMPT_DYNAMIC=y`)**: makes the preemption model selectable at boot (`preempt=`) or at runtime instead of being fixed at compile time. Note: nothing switches it automatically on AC/battery — it runs with the compiled-in default all the time (the watt impact of the preemption model is negligible; this option is kept for flexibility, not battery life).
- **Zen 5c scheduling (`CONFIG_SCHED_MC_PRIO=y`)**: support for AMD Preferred Cores, steering demanding tasks to the full Zen 5 cores and background tasks to the efficient Zen 5c cores.

#### 3. Power Saving and Battery Life

- **RCU Lazy (`CONFIG_RCU_LAZY=y` & `CONFIG_RCU_NOCB_CPU=y` & `CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y`)**: defers and batches RCU callback processing when the system isn't under heavy load, extending CPU sleep states (C-states). `RCU_NOCB_CPU_DEFAULT_ALL` offloads every CPU by default, which is what actually arms the lazy path without needing an `rcu_nocbs=` boot parameter.
  - **⚠️ Regression found and fixed (2026-07-24)**: same failure mode as the BBR one (section 4) — `RCU_NOCB_CPU` depends on `CONFIG_RCU_EXPERT`, which the script never enabled, so `olddefconfig` silently dropped the whole RCU chain: the installed `7.1.4-pehacorp` kernel had **neither `RCU_LAZY` nor `RCU_NOCB_CPU`** despite the script enabling them. `compile_kernel.sh` now enables `RCU_EXPERT` first and **verifies after `olddefconfig` that every critical option survived**, aborting the build otherwise (covers RCU, BBR, HZ_1000, SCHED_MC_PRIO, PREEMPT_DYNAMIC).
- **Tickless Idle (`CONFIG_NO_HZ_IDLE=y`)**: removes clock interrupts while cores are idle.
- **TEO cpuidle governor (`cpuidle.governor=teo` on the kernel command line)**: replaces the default `menu` governor with TEO, which predicts short idle periods better on modern Zen mobile CPUs and picks deeper C-states more accurately. The governor was already compiled in but never selected.
- **Kernel command line tracked in the repo**: `update_kernel_master.sh` now writes `GRUB_CMDLINE_LINUX_DEFAULT` itself (prefcore, power-efficient workqueues, `nmi_watchdog=0`, `split_lock_detect=off`, `cpuidle.governor=teo`), so the boot parameters are no longer hand-maintained outside version control.

#### 4. Wi-Fi Optimization & Unlocking (MediaTek MT7922 / `mt7921e`)

- **Driver auto-patching (`patches/0001-mt7921e-wifi-throughput-and-txpower.patch`)**:
  - **ASPM disabled by default** to avoid PCI Express L1/L1ss micro-stutter on the MT7922 chipset.
  - **MCU attenuation unlocked** (`txpower_drop`) to allow full throughput under heavy load.
  - **Extended RX DMA ring depth** (`MT7921_RX_RING_SIZE=4096`) to maximize downstream (RX) throughput with zero packet loss under fiber-line saturation.
  - **Accurate transmit power reporting**: fix in `mt76_get_txpower` to show real dBm values (20/23 dBm) in `wavemon`, `iw` and `iwconfig`.
  - **Extended AMPDU aggregation** for Wi-Fi 6/6E to unlock both downstream and upstream throughput.
- **Linux network stack tuning** ([`system/etc/sysctl.d/99-pehacorp-network.conf`](system/etc/sysctl.d/99-pehacorp-network.conf), deployed to `/etc/sysctl.d/`):
  - `netdev_max_backlog = 65536` receive backlog and 64 MB TCP buffers with **TCP BBR** congestion control.
  - **⚠️ Regression found and fixed (2026-07-24)**: `compile_kernel.sh` now explicitly forces `CONFIG_TCP_CONG_BBR` on. Without that, the module can silently disappear across incremental builds/version jumps even though Ubuntu's own base config ships it — this happened for real on the `7.1.4-pehacorp` kernel (BBR simply wasn't there anymore), which made `sudo sysctl --system` fail on `net.ipv4.tcp_congestion_control` and, without the `install.sh` fix below, aborted the whole install. `install.sh` no longer treats one unavailable sysctl key as fatal.
- **Dynamic AC vs battery handling (French ARCEP / ETSI regulation)**:
  - **On AC power**: automatically switches radio transmit power to the French legal cap (**20 dBm / 100 mW**) and disables Wi-Fi Power Save.
  - **On battery**: automatically reverts to `txpower auto` mode and enables Wi-Fi Power Save to preserve battery life.

#### 5. System Power Management Stack (TLP + udev)

On top of the kernel settings above, the AC/battery switch relies on a userspace stack (verified 2026-07-24):

- **TLP** (`tlp.service`, active and started at boot) drives most of the AC/BAT switching via the drop-in [`system/etc/tlp.d/99-amd-power-savings.conf`](system/etc/tlp.d/99-amd-power-savings.conf) (deployed to `/etc/tlp.d/`):
  - `powersave` governor on both profiles, with EPP (`energy_performance_preference`) set to `balance_performance` on AC and `power` on battery.
  - `CPU_BOOST` enabled on AC, disabled on battery.
  - **Global** PCIe ASPM policy: `default` on AC, `powersupersave` on battery.
  - NVMe link power state, AHCI runtime PM, ACPI platform profile (`balanced` on AC / `quiet` on battery), HDA audio controller power-save.
  - `power-profiles-daemon` is **masked** on purpose (it would duplicate and conflict with TLP — never re-enable both at once).

- **[`wifi-power-mode.sh`](system/usr/local/bin/wifi-power-mode.sh)** (deployed to `/usr/local/bin/`) + udev rule [`99-wifi-power-mode.rules`](system/etc/udev/rules.d/99-wifi-power-mode.rules) triggered on any `power_supply` event: manages transmit power (txpower, FR regulation) on AC/battery. TLP *also* manages Wi-Fi power-save on its own side (`WIFI_PWR_ON_AC/BAT`) — redundant with this script but harmless, both converge to the same value.

- **Battery charge threshold**: [`99-battery-charge-limit.rules`](system/etc/udev/rules.d/99-battery-charge-limit.rules) makes `BAT1/charge_control_end_threshold` writable (0666). Default value: **80%** (managed day-to-day afterwards by the GNOME widget, section 8). TLP's `START/STOP_CHARGE_THRESH_BAT*` settings exist in `/etc/tlp.conf` but are **commented out/disabled**: the threshold is therefore neither driven nor persisted by TLP, just made manually adjustable.

- **⚠️ Note (intended behavior, not a bug)**: the patched Wi-Fi driver (`mt7921_disable_aspm=true` by default) disables ASPM **specifically for the MT7922 card**, regardless of the global ASPM policy driven by TLP. Other PCIe devices (NVMe, etc.) do follow TLP's AC/battery switching, but Wi-Fi always stays with ASPM disabled (even on battery) to avoid micro-stutter — don't "fix" this thinking it's an inconsistency.

#### 6. Keyboard Backlight Idle Timeout (Battery Only)

On battery, [`kbd-backlight-idle.sh`](system/usr/local/bin/kbd-backlight-idle.sh) turns the keyboard backlight off after **1 minute** without any keyboard/trackpad activity, and restores the previous brightness as soon as activity resumes or AC is plugged back in. Run as a `systemd --user` service, [`kbd-backlight-idle.service`](system/etc/systemd/user/kbd-backlight-idle.service), deployed to `/etc/systemd/user/` by `install.sh`.

- **Idle detection**: polls Mutter's `IdleMonitor` over the **session** D-Bus bus (`org.gnome.Mutter.IdleMonitor.GetIdletime`) every 5 seconds — works under Wayland, unlike `xprintidle`, which needs X11.
- **Backlight control**: reads/writes brightness through UPower's `org.freedesktop.UPower.KbdBacklight` interface on the **system** bus, rather than writing `/sys/class/leds/asus::kbd_backlight/brightness` directly — this is callable by a regular user with no polkit prompt and no udev permission hack needed, and isn't tied to this specific LED's sysfs name.
- **AC/battery check**: same `/sys/class/power_supply/AC*/online` (or `ADP*`) read used by `wifi-power-mode.sh` (section 5). On AC, any saved brightness is restored immediately and the idle check is skipped entirely.
- **State**: the brightness value the script dimmed *from* is saved to `$XDG_RUNTIME_DIR/vivonux-kbd-backlight-saved` so it can restore the exact previous level rather than assuming a fixed value. If the backlight was already off before the idle timer fired (user turned it off manually), no state file is written and nothing gets touched on resume.

**⚠️ Pitfall found in testing**: a first version parsed `GetIdletime`'s `(uint64 5051,)` output with a naive `grep -oE '[0-9]+'`, which also matches the "64" inside the literal word `uint64` and breaks the numeric comparison. Fixed by anchoring the extraction to the value following `uint64` specifically (`sed -n 's/.*uint64 \([0-9]\+\).*/\1/p'`). If this script is ever touched again, don't reintroduce a blind digit-grep on raw `gdbus call` output.

Tune the threshold/poll interval without editing the script via environment variables in the unit file (`VIVONUX_KBD_IDLE_MS`, default `60000`; `VIVONUX_KBD_POLL_SECONDS`, default `5`).

#### 7. Display: 60 Hz on Battery & Static OLED ABM

The 3.2K OLED panel is one of the biggest battery consumers; two mechanisms tune it:

- **Refresh rate switching** ([`auto-refresh-rate.py`](system/usr/local/bin/auto-refresh-rate.py) + user service [`auto-refresh-rate.service`](system/etc/systemd/user/auto-refresh-rate.service)): **120 Hz on AC, 60 Hz on battery** (roughly halves display scan-out work). The panel is not VRR-capable, so GNOME's dynamic refresh rate can't be used — the script applies a real mode switch through Mutter's `DisplayConfig` D-Bus interface (session bus, hence a `systemd --user` service like the keyboard backlight one). It uses the *persistent* `ApplyMonitorsConfig` method on purpose: the *temporary* one triggers GNOME's "keep these settings?" confirmation pop-up on every switch. Historical note: this script predates its integration into the repo — it originally lived untracked in a scratch directory; `install.sh` removes the old user-local unit when deploying this one.
- **Static ABM (Adaptive Backlight Management), `amdgpu.abmlevel=3` on the kernel command line**: this is a boot-time-only setting — **there is no dynamic AC/battery ABM switch on this hardware**, and none is possible. Tried and reverted on 2026-07-24: the driver (`drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c`) reports `aux_support=true` unconditionally for any OLED panel, which makes `amdgpu_dm_should_create_sysfs()` refuse to create the `panel_power_savings` sysfs entry regardless of `abmlevel` — and the equivalent DRM property is explicitly withheld for OLED panels too. Worse, dropping `abmlevel` from the command line doesn't leave ABM "auto": the driver's default (`amdgpu_dm_abm_level = -1`) is forced to `ABM_LEVEL_IMMEDIATE_DISABLE`, i.e. ABM permanently **off** on both AC and battery — the opposite of the intended saving. `abmlevel=3` must stay in the command line.
- **Optional ICC color profile** ([`install-color-profile.sh`](install-color-profile.sh)): validates an `.icc`/`.icm` file, checks the eDP EDID for the exact Samsung `ATNA60BX01-1` panel, imports the profile through `colord`, and makes it the default for the device marked as the internal display. Run it as the desktop user, never with `sudo`: `./install-color-profile.sh`. A fresh install can do the same with `VIVONUX_ICC_PROFILE=./ATNA60BX01-1.icc ./install.sh`. The repo bundles [`ATNA60BX01-1.icc`](ATNA60BX01-1.icc) as the default profile — a display measurement of the same Samsung panel published by [Notebookcheck](https://www.notebookcheck.net/) (X-Rite i1Basic Pro 3, ΔE 2.42 calibrated), not an ASUS factory profile. VivoNux still does not redistribute ASUS or other commercial factory profiles; pass any other `.icc`/`.icm` path as an argument to use one obtained legally or created with a colorimeter instead.

#### 8. GNOME Widget: 80% / 100% Battery Charge Toggle

To occasionally allow charging to 100% (e.g. before a trip) without permanently giving up the 80% cap that preserves battery health, a GNOME Shell extension provides a toggle in the **Quick Settings** menu (next to Wi-Fi/Bluetooth):

- **Tracked source**: [`gnome-extension/charge-complete-bat1@peha/`](gnome-extension/charge-complete-bat1@peha/) (`extension.js` + `metadata.json`), deployed by `install.sh` to `~/.local/share/gnome-shell/extensions/`.
- **How it works**: writes `80` or `100` directly to `/sys/class/power_supply/BAT1/charge_control_end_threshold` (made writable by the udev rule from section 5) and persists the choice in `~/.config/charge_limit.conf` so it survives a reboot.
- **Enabling**: `gnome-extensions enable charge-complete-bat1@peha` (done automatically by `install.sh` — check with `gnome-extensions info charge-complete-bat1@peha`, should show `State: ACTIVE`).
- **Localization**: unlike the shell scripts in this repo (English-only, since the README already covers French/English separately), this GNOME extension follows the desktop convention of matching the system locale. UI strings are wrapped in `_()` and translated through standard gettext, with the French translation source in [`po/fr.po`](gnome-extension/charge-complete-bat1@peha/po/fr.po) compiled to [`locale/fr/LC_MESSAGES/charge-complete-bat1@peha.mo`](gnome-extension/charge-complete-bat1@peha/locale/fr/LC_MESSAGES/charge-complete-bat1@peha.mo) (`msgfmt po/fr.po -o locale/fr/LC_MESSAGES/charge-complete-bat1@peha.mo` to rebuild after editing the `.po`). GNOME Shell only picks up metadata/locale changes on the next re-enable or session restart, not instantly on file write.

**⚠️ Fixed pitfall (2026-07-24)**: the first version used `GLib.file_set_contents()` to write to sysfs, which fails every time (`Permission denied`) because that function writes via a temp file followed by a rename — a pattern that's impossible on `/sys` (you can't create a new dentry in a pseudo-filesystem). Fixed by opening the existing file directly via `Gio.File.open_readwrite()`. If the extension is ever modified again, don't reintroduce `GLib.file_set_contents()` for a path under `/sys` or `/proc`.

If the toggle doesn't show up after a GNOME Shell update, check version compatibility in `metadata.json` (`shell-version`) and any errors with:
```bash
journalctl --user -u gnome-shell --since "-5 min" | grep -i charge
```

#### 9. Full Hardware Integration

- **Driver coverage**: based on Ubuntu's `/boot/config-$(uname -r)` configuration to keep every generic hardware driver (USB, HDA audio, Wi-Fi, Bluetooth, Radeon 890M GPU, NVMe...).
- **Debug info stripped (`CONFIG_DEBUG_INFO=n`)**: cuts build time by 10x and significantly shrinks the kernel image size.
- **Trusted keys reset (`CONFIG_SYSTEM_TRUSTED_KEYS=""`)**: lets the build complete without errors related to Ubuntu's X.509 keys.

### 🔄 Updating the kernel later

`install.sh` is only needed once, on a fresh machine. To rebuild and install a new version of the
`-pehacorp` kernel on a machine already running VivoNux (e.g. a new stable release on kernel.org),
just run the master script directly:

```bash
cd VivoNux
./update_kernel_master.sh
```

**What this all-in-one script does automatically:**

1. **Build & auto-patching**: looks up the selected channel on `kernel.org` (see [Kernel channel](#kernel-channel-stable-rc-beta) above), automatically applies every `.patch` file in `patches/`, and runs `compile_kernel.sh` with all optimizations.
2. **Identification**: automatically finds the generated `.deb` packages and extracts the exact version (e.g. `7.1.4-pehacorp`).
3. **Installation**: runs `sudo dpkg -i` to install the new kernel image and headers.
4. **Safe GRUB configuration**:
   - Sets the new `-pehacorp` kernel as the **default boot kernel** — only for the `stable` channel; an `rc`/`beta` build is installed and available from the GRUB menu but is **never** made the default (see below).
   - Keeps a **5-second GRUB menu delay** so you can easily boot back into the generic Ubuntu kernel if something goes wrong.
5. **GRUB update**: runs `sudo update-grub`.
6. **Build cleanup**: keeps only the **3 most recent** `-pehacorp` builds (`.deb` packages + `.buildinfo`/`.changes`) in the repo directory, removing older ones to avoid piling up several GB over time. This only touches build artifacts on disk — never the currently installed kernel packages or `/boot`.

All that's left is to reboot:
```bash
sudo reboot
```

### ⚠️ Things to check when a new kernel version comes out

When a new major Linux kernel version is released on `kernel.org` (e.g. a future 7.2.x or 7.3.x):

#### 1. Check that the Wi-Fi patch applied cleanly

At the start of the build process in `compile_kernel.sh`, watch the console during step **3b**:

- Make sure the line `Application du patch : 0001-mt7921e-wifi-throughput-and-txpower.patch` prints successfully.
- If the upstream `mt76` driver code has changed, a rejection (`.rej`) may occur. If there's a conflict:

  ```bash
  cd linux-X.Y.Z
  patch -p1 --dry-run < ../patches/0001-mt7921e-wifi-throughput-and-txpower.patch
  ```

  If needed, regenerate the patch with `git diff` against the new sources.

#### 2. Native upstream integration

If MediaTek maintainers (`linux-wireless`) merge the MT7922 fixes natively into the new kernel version, the patch becomes unnecessary and can be moved out of, or removed from, `patches/`.

#### 3. Post-update check after reboot

After booting into the new `-pehacorp` kernel version, run these quick checks:
```bash
# 1. Check the active kernel
uname -r

# 2. Check MT7922 Wi-Fi card detection and logs
dmesg | grep -i mt7921e

# 3. Check AC-power behavior (20 dBm / power save off)
iw dev wlp98s0 info | grep -E "txpower|power save"
```

### 🔍 Quick check

After booting, check the active kernel and that everything works:
```bash
uname -r
# Should print: 7.X.Y-pehacorp
```

---

## Français

**VivoNux** transforme une installation Ubuntu standard en environnement optimisé perf/autonomie
pour une machine précise : **ASUS Vivobook S16 avec AMD Ryzen AI 9 HX 370 (Zen 5)** et carte
Wi-Fi **MediaTek MT7922 (`mt7921e`)**.

⚠️ **Ce n'est pas un projet générique.** Les flags de compilation (`-march=znver5`), le patch
Wi-Fi et le plafond d'émission radio réglementaire (FR/ARCEP) sont spécifiques à ce matériel.
Ne l'installe pas sur une autre machine sans relire chaque section ci-dessous.

Le mantra : **perf sur secteur, autonomie sur batterie**, en gardant l'intégralité des pilotes
matériels génériques d'Ubuntu (rien n'est retiré, seulement optimisé/patché).

⚠️ **Il faut d'abord désactiver le Secure Boot.** Le noyau `-pehacorp` est auto-compilé et non
signé (`compile_kernel.sh` réinitialise `CONFIG_SYSTEM_TRUSTED_KEYS`/`CONFIG_SYSTEM_REVOCATION_KEYS`),
donc avec le Secure Boot activé, le firmware refusera de le démarrer (ou les modules tiers
Wi-Fi/GPU refuseront de se charger). Désactive le Secure Boot dans le BIOS/UEFI **avant** de lancer
`install.sh` ou `update_kernel_master.sh`.

### 🚀 Installation rapide

Sur un Ubuntu fraîchement installé sur une machine identique :

```bash
git clone https://github.com/pehadavid/VivoNux.git
cd VivoNux
./install.sh
```

`install.sh` vérifie le matériel, installe les dépendances de compilation, déploie la
configuration système (TLP/udev/sysctl), installe le widget GNOME, puis compile et installe le
noyau `-pehacorp` (voir détail plus bas). Prévoir un long moment pour la compilation. À la fin :

```bash
sudo reboot
```

Le menu GRUB garde un délai de sécurité de 5 secondes pour revenir au noyau Ubuntu générique en
cas de souci.

### Canal du noyau : stable, rc, beta

`install.sh` commence par interroger `kernel.org` et demande quelle ligne compiler :

- **stable** (par défaut) : la dernière version stable. Devient le noyau **par défaut dans GRUB**,
  comme avant.
- **rc** : la release candidate mainline en cours (`X.Y-rcN`), proposée uniquement quand il y en a une.
- **beta** : le snapshot de développement mainline en cours (avant `rc1`, tête de la fenêtre de
  fusion), proposé uniquement quand aucune RC n'est publiée — `rc` et `beta` sont deux états du même
  repère `mainline` de kernel.org, jamais disponibles en même temps.

`rc` et `beta` sont compilés et installés comme n'importe quel noyau, mais
**`update_kernel_master.sh` ne les définit jamais comme noyau par défaut dans GRUB** — ils
n'apparaissent que sous « Advanced options for Ubuntu », pour choisir explicitement de démarrer
sur un noyau instable plutôt que ça arrive automatiquement. Répondre juste avec Entrée (ou une
réponse non reconnue) retombe toujours sur `stable`. Les mises à jour lancées plus tard via
`./update_kernel_master.sh` directement réutilisent `stable`, sauf si `VIVONUX_KERNEL_CHANNEL=rc`
(ou `beta`) est exporté avant.

Les sources `stable` viennent toujours directement de `cdn.kernel.org`. Les sources `rc`/`beta`
viennent du miroir officiel en lecture seule de l'arbre de Linus sur GitHub
([`torvalds/linux`](https://github.com/torvalds/linux)) plutôt que de `git.kernel.org` : le point
de génération de snapshot de kernel.org pour mainline est protégé par un challenge JS anti-bot qui
rejette les téléchargements scriptés (HTTP 403), ce que le miroir GitHub n'a pas.

### 📁 Structure du dépôt

```text
install.sh                    # Installeur maître (point d'entrée sur machine neuve)
install-color-profile.sh      # Installe un profil ICC optionnel pour l'OLED interne
compile_kernel.sh             # Télécharge, patch et compile le noyau -pehacorp
update_kernel_master.sh       # Compile + installe les .deb + configure GRUB
cleanup.sh                    # Supprime les sources/anciens builds inutilisés (voir ci-dessous)
patches/                      # Patchs appliqués automatiquement aux sources du noyau
system/etc/...                # Miroir de /etc : TLP, udev, sysctl (déployés tels quels)
system/usr/local/bin/...      # Miroir de /usr/local/bin : scripts système
gnome-extension/...           # Widget GNOME Quick Settings (charge batterie)
```

Les sources noyau téléchargées, les `.deb` compilés et les tarballs (plusieurs Go) ne sont **pas**
versionnés (voir `.gitignore`) — ils se régénèrent à la demande via la compilation.

#### 🧹 Nettoyer les sources inutilisées et les anciens builds

Chaque compilation laisse sur le disque l'archive/le répertoire source du noyau précédent
ainsi que quelques anciennes révisions de `.deb` (plusieurs Go). `install.sh` propose de
lancer [`cleanup.sh`](cleanup.sh) en fin d'installation ; il peut aussi être lancé seul à
tout moment :

```bash
./cleanup.sh            # supprime tout ce qui n'est plus utile au build actuel
./cleanup.sh --dry-run  # simule le nettoyage, ne supprime rien
```

Il conserve toujours l'archive/le répertoire source et le jeu de `.deb` correspondant au
dernier noyau compilé dans ce dossier (pour ne pas casser les rebuilds incrémentaux ni les
réinstallations), et supprime : les anciennes archives/répertoires sources kernel.org, les
anciennes révisions `.deb`/`.buildinfo`/`.changes`, et les résidus d'un ancien build sans
rapport (paquet source Debian du noyau 7.0.0).

### 🛠️ Optimisations et Choix Architecturaux

Le noyau est compilé à partir des sources officielles **Mainline (kernel.org)** en reprenant la base matérielle complète d'Ubuntu tout en injectant les optimisations de performance et d'économie d'énergie suivantes :

#### 1. Compilation Native Zen 5

- **Flags du compilateur** : `KCFLAGS="-march=znver5 -O3"`
- **Bénéfice** : Exploitation maximale des instructions matérielles du processeur Zen 5 (AVX-512, vectorisation poussée) et optimisations d'exécution `-O3`.

#### 2. Réactivité & Performance en Jeu

- **Fréquence du tick (`CONFIG_HZ_1000=y`)** : Horloge système à 1000 Hz pour réduire au strict minimum la latence d'entrée et la gigue (jitter).
- **Préemption Dynamique (`CONFIG_PREEMPT_DYNAMIC=y`)** : Rend le modèle de préemption sélectionnable au boot (`preempt=`) ou à chaud au lieu d'être figé à la compilation. Note : rien ne le bascule automatiquement en secteur/batterie — le défaut compilé s'applique en permanence (l'impact en watts du modèle de préemption est négligeable ; l'option est gardée pour la flexibilité, pas pour l'autonomie).
- **Ordonnancement Zen 5c (`CONFIG_SCHED_MC_PRIO=y`)** : Prise en charge d'AMD Preferred Cores pour orienter les tâches gourmandes vers les cœurs Zen 5 classiques et laisser les tâches de fond aux cœurs Zen 5c économes.

#### 3. Économie d'Énergie et Autonomie sur Batterie

- **RCU Lazy (`CONFIG_RCU_LAZY=y` & `CONFIG_RCU_NOCB_CPU=y` & `CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y`)** : Diffère et regroupe le traitement des callbacks RCU quand le système n'est pas sous forte charge pour prolonger les états de sommeil du CPU (C-states). `RCU_NOCB_CPU_DEFAULT_ALL` décharge tous les CPUs par défaut — c'est ce qui arme réellement le mode lazy sans nécessiter de paramètre de boot `rcu_nocbs=`.
  - **⚠️ Régression trouvée et corrigée (24/07/2026)** : même mécanique que celle du BBR (section 4) — `RCU_NOCB_CPU` dépend de `CONFIG_RCU_EXPERT`, que le script n'activait jamais, donc `olddefconfig` jetait silencieusement toute la chaîne RCU : le noyau `7.1.4-pehacorp` installé n'avait **ni `RCU_LAZY` ni `RCU_NOCB_CPU`** malgré leur activation par le script. `compile_kernel.sh` active désormais `RCU_EXPERT` en premier et **vérifie après `olddefconfig` que chaque option critique a survécu**, en interrompant le build sinon (couvre RCU, BBR, HZ_1000, SCHED_MC_PRIO, PREEMPT_DYNAMIC).
- **Tickless Idle (`CONFIG_NO_HZ_IDLE=y`)** : Supprime les interruptions d'horloge lorsque les cœurs sont inactifs.
- **Gouverneur cpuidle TEO (`cpuidle.governor=teo` sur la ligne de commande kernel)** : Remplace le gouverneur `menu` par défaut par TEO, qui prédit mieux les périodes d'inactivité courtes sur les Zen mobiles récents et choisit les C-states profonds plus justement. Le gouverneur était déjà compilé mais jamais sélectionné.
- **Ligne de commande kernel suivie dans le dépôt** : `update_kernel_master.sh` écrit désormais lui-même `GRUB_CMDLINE_LINUX_DEFAULT` (prefcore, workqueues power-efficient, `nmi_watchdog=0`, `split_lock_detect=off`, `cpuidle.governor=teo`) — les paramètres de boot ne sont plus maintenus à la main hors du contrôle de version.

#### 4. Optimisations & Débridage Wi-Fi (MediaTek MT7922 / `mt7921e`)

- **Auto-Patching du pilote (`patches/0001-mt7921e-wifi-throughput-and-txpower.patch`)** :
  - **Désactivation ASPM par défaut** pour éviter les micro-saccades PCI Express L1/L1ss sur le chipset MT7922.
  - **Débridage de l'atténuation MCU (`txpower_drop`)** pour autoriser le plein débit sous forte charge.
  - **Extension de la profondeur du ring DMA RX (`MT7921_RX_RING_SIZE=4096`)** pour maximiser les débits descendants (RX) sans aucune perte de paquets sous saturation Fibre.
  - **Rapport de puissance émission réelle** : Correction dans `mt76_get_txpower` pour afficher les vrais dBm (20/23 dBm) dans `wavemon`, `iw` et `iwconfig`.
  - **Extension de l'agrégation AMPDU** Wi-Fi 6/6E pour débrider les débits descendants et montants.
- **Optimisations de la Pile Réseau Linux** ([`system/etc/sysctl.d/99-pehacorp-network.conf`](system/etc/sysctl.d/99-pehacorp-network.conf), déployé vers `/etc/sysctl.d/`) :
  - Backlog de réception `netdev_max_backlog = 65536` et buffers TCP de 64 Mo avec contrôle de congestion **TCP BBR**.
  - **⚠️ Régression trouvée et corrigée (24/07/2026)** : `compile_kernel.sh` force désormais explicitement `CONFIG_TCP_CONG_BBR`. Sans ça, le module peut disparaître silencieusement au fil des builds incrémentaux/sauts de version même si la config Ubuntu de base l'embarque — c'est arrivé pour de vrai sur le noyau `7.1.4-pehacorp` (BBR n'était simplement plus là), ce qui a fait échouer `sudo sysctl --system` sur `net.ipv4.tcp_congestion_control` et, sans le correctif `install.sh` ci-dessous, interrompait toute l'installation. `install.sh` ne traite plus une clé sysctl indisponible comme fatale.
- **Gestion Dynamique SECTEUR vs BATTERIE (Normes ARCEP / ETSI `FR`)** :
  - **Sur SECTEUR (AC)** : Bascule automatique de la puissance d'émission radio au plafond légal français (**20 dBm / 100 mW**) et désactivation du Wi-Fi Power Save.
  - **Sur BATTERIE (BAT)** : Retour automatique en mode `txpower auto` et Wi-Fi Power Save activé pour préserver la batterie.

#### 5. Pile de Gestion d'Alimentation Système (TLP + udev)

En complément des réglages kernel ci-dessus, la bascule secteur/batterie repose sur une pile userspace (vérifiée le 24/07/2026) :

- **TLP** (`tlp.service`, actif et démarré au boot) pilote la majorité des bascules AC/BAT via le drop-in [`system/etc/tlp.d/99-amd-power-savings.conf`](system/etc/tlp.d/99-amd-power-savings.conf) (déployé vers `/etc/tlp.d/`) :
  - Governor `powersave` sur les deux profils, avec EPP (`energy_performance_preference`) `balance_performance` sur secteur et `power` sur batterie.
  - `CPU_BOOST` activé sur secteur, désactivé sur batterie.
  - Policy ASPM PCIe **globale** : `default` sur secteur, `powersupersave` sur batterie.
  - Link power state NVMe, runtime PM AHCI, profil plateforme ACPI (`balanced` secteur / `quiet` batterie), power-save du contrôleur audio HDA.
  - `power-profiles-daemon` est **masqué** volontairement (il ferait doublon et entrerait en conflit avec TLP — ne jamais réactiver les deux en même temps).

- **[`wifi-power-mode.sh`](system/usr/local/bin/wifi-power-mode.sh)** (déployé vers `/usr/local/bin/`) + règle udev [`99-wifi-power-mode.rules`](system/etc/udev/rules.d/99-wifi-power-mode.rules) déclenchée sur tout événement `power_supply` : gère la puissance d'émission (txpower, norme FR) en secteur/batterie. TLP gère *aussi* le power-save Wi-Fi de son côté (`WIFI_PWR_ON_AC/BAT`) — redondant avec ce script mais sans conflit, les deux convergent vers la même valeur.

- **Seuil de charge batterie** : [`99-battery-charge-limit.rules`](system/etc/udev/rules.d/99-battery-charge-limit.rules) rend `BAT1/charge_control_end_threshold` accessible en écriture (0666). Valeur par défaut : **80 %** (géré ensuite au jour le jour par le widget GNOME, section 8). Les paramètres `START/STOP_CHARGE_THRESH_BAT*` de TLP existent dans `/etc/tlp.conf` mais sont **commentés/désactivés** : le seuil n'est donc pas piloté ni persisté par TLP, seulement rendu modifiable manuellement.

- **⚠️ Point d'attention (comportement voulu, pas un bug)** : le driver Wi-Fi patché (`mt7921_disable_aspm=true` par défaut) désactive l'ASPM **spécifiquement pour la carte MT7922**, quelle que soit la policy ASPM globale pilotée par TLP. Les autres périphériques PCIe (NVMe...) suivent bien la bascule secteur/batterie de TLP, mais le Wi-Fi reste toujours en ASPM désactivé (même sur batterie) pour éviter les micro-saccades — ne pas "corriger" ça en pensant à une incohérence.

#### 6. Extinction du rétroéclairage clavier après inactivité (batterie seulement)

Sur batterie, [`kbd-backlight-idle.sh`](system/usr/local/bin/kbd-backlight-idle.sh) éteint le rétroéclairage du clavier après **1 minute** sans activité clavier/trackpad, et restaure la luminosité précédente dès qu'une activité reprend ou que le secteur est rebranché. Tourne en tant que service `systemd --user`, [`kbd-backlight-idle.service`](system/etc/systemd/user/kbd-backlight-idle.service), déployé dans `/etc/systemd/user/` par `install.sh`.

- **Détection d'inactivité** : interroge l'`IdleMonitor` de Mutter sur le bus D-Bus **session** (`org.gnome.Mutter.IdleMonitor.GetIdletime`) toutes les 5 secondes — fonctionne sous Wayland, contrairement à `xprintidle` qui nécessite X11.
- **Contrôle du rétroéclairage** : lit/écrit la luminosité via l'interface UPower `org.freedesktop.UPower.KbdBacklight` sur le bus **système**, plutôt que d'écrire directement `/sys/class/leds/asus::kbd_backlight/brightness` — appelable par un utilisateur normal sans invite polkit ni bidouille de permission udev, et indépendant du nom sysfs exact de ce LED.
- **Vérification secteur/batterie** : même lecture de `/sys/class/power_supply/AC*/online` (ou `ADP*`) que `wifi-power-mode.sh` (section 5). Sur secteur, toute luminosité sauvegardée est restaurée immédiatement et la vérification d'inactivité est entièrement sautée.
- **État** : la valeur de luminosité depuis laquelle le script a éteint est sauvegardée dans `$XDG_RUNTIME_DIR/vivonux-kbd-backlight-saved`, pour restaurer le niveau exact précédent plutôt que de supposer une valeur fixe. Si le rétroéclairage était déjà éteint avant le déclenchement du minuteur d'inactivité (éteint manuellement par l'utilisateur), aucun fichier d'état n'est écrit et rien n'est touché à la reprise.

**⚠️ Piège trouvé en testant** : une première version parsait la sortie `(uint64 5051,)` de `GetIdletime` avec un `grep -oE '[0-9]+'` naïf, qui capture aussi le "64" contenu dans le mot littéral `uint64` et casse la comparaison numérique. Corrigé en ancrant l'extraction sur la valeur qui suit `uint64` spécifiquement (`sed -n 's/.*uint64 \([0-9]\+\).*/\1/p'`). Si ce script est retouché un jour, ne pas réintroduire un grep de chiffres aveugle sur la sortie brute de `gdbus call`.

Le seuil et l'intervalle de sondage se réglent sans toucher au script via des variables d'environnement dans le fichier d'unité (`VIVONUX_KBD_IDLE_MS`, défaut `60000` ; `VIVONUX_KBD_POLL_SECONDS`, défaut `5`).

#### 7. Affichage : 60 Hz sur Batterie & ABM OLED Statique

La dalle OLED 3.2K est l'un des plus gros consommateurs sur batterie ; deux mécanismes l'ajustent :

- **Bascule de fréquence de rafraîchissement** ([`auto-refresh-rate.py`](system/usr/local/bin/auto-refresh-rate.py) + service utilisateur [`auto-refresh-rate.service`](system/etc/systemd/user/auto-refresh-rate.service)) : **120 Hz sur secteur, 60 Hz sur batterie** (divise environ par deux le travail de scan-out de l'affichage). La dalle n'est pas compatible VRR, donc le rafraîchissement dynamique de GNOME est inutilisable — le script applique un vrai changement de mode via l'interface D-Bus `DisplayConfig` de Mutter (bus session, donc un service `systemd --user` comme celui du rétroéclairage clavier). Il utilise volontairement la méthode `ApplyMonitorsConfig` *persistante* : la méthode *temporaire* déclenche la pop-up de confirmation GNOME « conserver ces réglages ? » à chaque bascule. Note historique : ce script est antérieur à son intégration dans le dépôt — il vivait non-versionné dans un répertoire scratch ; `install.sh` supprime l'ancienne unité utilisateur locale en déployant celle-ci.
- **ABM statique (Adaptive Backlight Management), `amdgpu.abmlevel=3` sur la ligne de commande kernel** : c'est un réglage figé au boot uniquement — **il n'existe aucune bascule ABM dynamique secteur/batterie possible sur ce matériel**. Testé puis annulé le 24/07/2026 : le driver (`drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c`) remonte `aux_support=true` de façon inconditionnelle pour toute dalle OLED, ce qui fait que `amdgpu_dm_should_create_sysfs()` refuse de créer l'entrée sysfs `panel_power_savings` quel que soit `abmlevel` — et la propriété DRM équivalente est elle aussi explicitement désactivée pour les dalles OLED. Pire : retirer `abmlevel` de la ligne de commande ne laisse pas l'ABM en mode "auto" : la valeur par défaut du driver (`amdgpu_dm_abm_level = -1`) est forcée à `ABM_LEVEL_IMMEDIATE_DISABLE`, c'est-à-dire l'ABM **coupé en permanence** sur secteur comme sur batterie — l'inverse de l'économie recherchée. `abmlevel=3` doit rester dans la ligne de commande.
- **Profil colorimétrique ICC optionnel** ([`install-color-profile.sh`](install-color-profile.sh)) : valide un fichier `.icc`/`.icm`, vérifie dans l'EDID eDP la référence exacte Samsung `ATNA60BX01-1`, importe le profil via `colord` et en fait le profil par défaut du périphérique marqué comme écran intégré. À lancer comme utilisateur de la session graphique, jamais avec `sudo` : `./install-color-profile.sh`. Une installation neuve peut faire la même chose avec `VIVONUX_ICC_PROFILE=./ATNA60BX01-1.icc ./install.sh`. Le dépôt embarque [`ATNA60BX01-1.icc`](ATNA60BX01-1.icc) comme profil par défaut — une mesure de la même dalle Samsung publiée par [Notebookcheck](https://www.notebookcheck.net/) (X-Rite i1Basic Pro 3, ΔE 2.42 calibré), pas un profil usine ASUS. VivoNux ne redistribue toujours aucun profil usine ASUS ou commercial ; passe le chemin d'un autre `.icc`/`.icm` en argument pour utiliser un profil obtenu légalement ou créé avec une sonde à la place.

#### 8. Widget GNOME : Bascule Charge Batterie 80% / 100%

Pour autoriser ponctuellement la charge à 100% (ex. avant un déplacement) sans renoncer en permanence à la limite de 80% qui préserve la santé de la batterie, une extension GNOME Shell fournit un toggle dans le menu **Quick Settings** (à côté du Wi-Fi/Bluetooth) :

- **Source versionnée** : [`gnome-extension/charge-complete-bat1@peha/`](gnome-extension/charge-complete-bat1@peha/) (`extension.js` + `metadata.json`), déployée par `install.sh` vers `~/.local/share/gnome-shell/extensions/`.
- **Fonctionnement** : écrit directement `80` ou `100` dans `/sys/class/power_supply/BAT1/charge_control_end_threshold` (rendu accessible en écriture par la règle udev de la section 5) et persiste le choix dans `~/.config/charge_limit.conf` pour survivre à un redémarrage.
- **Activation** : `gnome-extensions enable charge-complete-bat1@peha` (fait automatiquement par `install.sh` — vérifier avec `gnome-extensions info charge-complete-bat1@peha`, doit afficher `État: ACTIVE`).
- **Localisation** : contrairement aux scripts shell de ce dépôt (anglais uniquement, puisque le README couvre déjà français/anglais séparément), cette extension GNOME suit la convention du bureau qui consiste à suivre la langue du système. Les chaînes d'interface sont enveloppées dans `_()` et traduites via gettext standard, avec la source de traduction française dans [`po/fr.po`](gnome-extension/charge-complete-bat1@peha/po/fr.po) compilée vers [`locale/fr/LC_MESSAGES/charge-complete-bat1@peha.mo`](gnome-extension/charge-complete-bat1@peha/locale/fr/LC_MESSAGES/charge-complete-bat1@peha.mo) (`msgfmt po/fr.po -o locale/fr/LC_MESSAGES/charge-complete-bat1@peha.mo` pour recompiler après modification du `.po`). GNOME Shell ne prend en compte les changements de métadonnées/traductions qu'à la prochaine réactivation ou au redémarrage de session, pas instantanément à l'écriture du fichier.

**⚠️ Piège corrigé (24/07/2026)** : la première version utilisait `GLib.file_set_contents()` pour écrire dans le sysfs, ce qui échoue systématiquement (`Permission non accordée`) car cette fonction écrit via un fichier temporaire suivi d'un renommage — un schéma impossible sur `/sys` (impossible de créer un nouveau dentry dans un pseudo-filesystem). Corrigé en ouvrant le fichier existant directement via `Gio.File.open_readwrite()`. Si l'extension est un jour modifiée, ne pas réintroduire `GLib.file_set_contents()` pour un chemin sous `/sys` ou `/proc`.

Si le toggle n'apparaît pas après une mise à jour de GNOME Shell, vérifier la compatibilité de version dans `metadata.json` (`shell-version`) et les erreurs éventuelles avec :
```bash
journalctl --user -u gnome-shell --since "-5 min" | grep -i charge
```

#### 9. Intégration Matérielle Complète

- **Conservation des pilotes** : Basé sur la configuration `/boot/config-$(uname -r)` d'Ubuntu pour conserver l'intégralité des pilotes matériels génériques (USB, audio HDA, Wi-Fi, Bluetooth, GPU Radeon 890M, NVMe...).
- **Suppression du débogage (`CONFIG_DEBUG_INFO=n`)** : Divise par 10 le temps de compilation et allège considérablement la taille de l'image noyau.
- **Clés de confiance réinitialisées (`CONFIG_SYSTEM_TRUSTED_KEYS=""`)** : Permet la compilation sans erreur liée aux clés X.509 d'Ubuntu.

### 🔄 Mettre à jour le noyau plus tard

`install.sh` n'est nécessaire qu'une fois, sur une machine neuve. Pour recompiler et installer une
nouvelle version du noyau `-pehacorp` sur une machine déjà VivoNux (ex. nouvelle version stable sur
kernel.org), utilise directement le script maître :

```bash
cd VivoNux
./update_kernel_master.sh
```

**Ce que fait ce script tout-en-un automatiquement :**

1. **Compilation & Auto-Patching** : Recherche le canal sélectionné sur `kernel.org` (voir [Canal du noyau](#canal-du-noyau--stable-rc-beta) plus haut), applique automatiquement tous les fichiers `.patch` présents dans `patches/` et lance `compile_kernel.sh` avec toutes les optimisations.
2. **Identification** : Détecte automatiquement les paquets `.deb` générés et extrait la version exacte (ex: `7.1.4-pehacorp`).
3. **Installation** : Exécute `sudo dpkg -i` pour installer l'image et les en-têtes du nouveau noyau.
4. **Configuration GRUB Sécurisée** :
   - Définit le nouveau noyau `-pehacorp` comme **noyau par défaut au démarrage** — uniquement pour le canal `stable` ; un build `rc`/`beta` est installé et disponible dans le menu GRUB mais **jamais** défini par défaut (voir plus haut).
   - Maintient un **délai de 5 secondes au menu GRUB** pour te laisser la possibilité de démarrer facilement sur le noyau générique Ubuntu en cas d'imprévu.
5. **Mise à jour GRUB** : Exécute `sudo update-grub`.
6. **Nettoyage des builds** : ne garde que les **3 builds `-pehacorp` les plus récentes** (paquets `.deb` + `.buildinfo`/`.changes`) dans le dossier du dépôt, en supprimant les plus anciennes pour éviter d'accumuler plusieurs Go au fil du temps. Ça ne touche qu'aux artefacts de build sur disque — jamais aux paquets noyau réellement installés ni à `/boot`.

Il ne te reste plus qu'à redémarrer :
```bash
sudo reboot
```

### ⚠️ Points d'Attention lors de l'Arrivée d'une Nouvelle Version du Noyau

Lorsqu'une nouvelle version majeure du noyau Linux est publiée sur `kernel.org` (ex. mise à jour vers un futur noyau 7.2.x ou 7.3.x) :

#### 1. Vérification de l'Application du Patch Wi-Fi

Au début du processus de compilation dans `compile_kernel.sh`, surveille la console lors de l'étape **3b** :

- Assure-toi que la ligne `Application du patch : 0001-mt7921e-wifi-throughput-and-txpower.patch` s'affiche avec succès.
- Si le code amont du pilote `mt76` a évolué, un rejet (`.rej`) peut survenir. En cas de conflit :

  ```bash
  cd linux-X.Y.Z
  patch -p1 --dry-run < ../patches/0001-mt7921e-wifi-throughput-and-txpower.patch
  ```

  Si nécessaire, mets à jour le patch avec `git diff` sur les nouvelles sources.

#### 2. Intégration Upstream Native

Si les mainteneurs MediaTek (`linux-wireless`) intègrent nativement les fixs MT7922 dans la nouvelle version du noyau, le patch deviendra inutile et pourra être déplacé ou supprimé du dossier `patches/`.

#### 3. Contrôle Post-Mise à Jour après Redémarrage

Après avoir démarré sur la nouvelle version du noyau `-pehacorp`, effectue ces contrôles rapides :
```bash
# 1. Vérifier le noyau actif
uname -r

# 2. Vérifier la détection et les logs de la carte Wi-Fi MT7922
dmesg | grep -i mt7921e

# 3. Vérifier le comportement en secteur (20 dBm / power save off)
iw dev wlp98s0 info | grep -E "txpower|power save"
```

### 🔍 Vérification Rapide

Après le démarrage, vérifier le noyau actif et le fonctionnement :
```bash
uname -r
# Doit afficher : 7.X.Y-pehacorp
```
