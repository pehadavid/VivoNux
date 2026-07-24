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

### 🚀 Quick install

On a freshly installed Ubuntu, on an identical machine:

```bash
git clone <repo-url> VivoNux
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

### 📁 Repository layout

```text
install.sh                    # Master installer (entry point on a fresh machine)
compile_kernel.sh             # Downloads, patches and builds the -pehacorp kernel
update_kernel_master.sh       # Builds + installs the .deb packages + configures GRUB
patches/                      # Patches automatically applied to the kernel sources
system/etc/...                # Mirrors /etc: TLP, udev, sysctl (deployed as-is)
system/usr/local/bin/...      # Mirrors /usr/local/bin: system scripts
gnome-extension/...           # GNOME Quick Settings widget (battery charge)
```

Downloaded kernel sources, compiled `.deb` packages and tarballs (several GB) are **not** tracked
(see `.gitignore`) — they're regenerated on demand by the build.

### 🛠️ Optimizations and Architectural Choices

The kernel is built from the official **Mainline** sources (kernel.org), starting from Ubuntu's
full hardware base, with the following performance and power-saving optimizations layered on top:

#### 1. Native Zen 5 Build

- **Compiler flags**: `KCFLAGS="-march=znver5 -O3"`
- **Benefit**: full use of Zen 5's hardware instructions (AVX-512, deep vectorization) plus `-O3` execution tuning.

#### 2. Responsiveness & Gaming Performance

- **Tick frequency (`CONFIG_HZ_1000=y`)**: 1000 Hz system clock to minimize input latency and jitter.
- **Dynamic Preemption (`CONFIG_PREEMPT_DYNAMIC=y`)**: lets preemption switch on the fly depending on usage (Full Preempt while gaming, Voluntary on battery).
- **Zen 5c scheduling (`CONFIG_SCHED_MC_PRIO=y`)**: support for AMD Preferred Cores, steering demanding tasks to the full Zen 5 cores and background tasks to the efficient Zen 5c cores.

#### 3. Power Saving and Battery Life

- **RCU Lazy (`CONFIG_RCU_LAZY=y` & `CONFIG_RCU_NOCB_CPU=y`)**: defers and batches RCU callback processing when the system isn't under heavy load, extending CPU sleep states (C-states).
- **Tickless Idle (`CONFIG_NO_HZ_IDLE=y`)**: removes clock interrupts while cores are idle.

#### 4. Wi-Fi Optimization & Unlocking (MediaTek MT7922 / `mt7921e`)

- **Driver auto-patching (`patches/0001-mt7921e-wifi-throughput-and-txpower.patch`)**:
  - **ASPM disabled by default** to avoid PCI Express L1/L1ss micro-stutter on the MT7922 chipset.
  - **MCU attenuation unlocked** (`txpower_drop`) to allow full throughput under heavy load.
  - **Extended RX DMA ring depth** (`MT7921_RX_RING_SIZE=4096`) to maximize downstream (RX) throughput with zero packet loss under fiber-line saturation.
  - **Accurate transmit power reporting**: fix in `mt76_get_txpower` to show real dBm values (20/23 dBm) in `wavemon`, `iw` and `iwconfig`.
  - **Extended AMPDU aggregation** for Wi-Fi 6/6E to unlock both downstream and upstream throughput.
- **Linux network stack tuning** ([`system/etc/sysctl.d/99-pehacorp-network.conf`](system/etc/sysctl.d/99-pehacorp-network.conf), deployed to `/etc/sysctl.d/`):
  - `netdev_max_backlog = 65536` receive backlog and 64 MB TCP buffers with **TCP BBR** congestion control.
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

- **Battery charge threshold**: [`99-battery-charge-limit.rules`](system/etc/udev/rules.d/99-battery-charge-limit.rules) makes `BAT1/charge_control_end_threshold` writable (0666). Default value: **80%** (managed day-to-day afterwards by the GNOME widget, section 6). TLP's `START/STOP_CHARGE_THRESH_BAT*` settings exist in `/etc/tlp.conf` but are **commented out/disabled**: the threshold is therefore neither driven nor persisted by TLP, just made manually adjustable.

- **⚠️ Note (intended behavior, not a bug)**: the patched Wi-Fi driver (`mt7921_disable_aspm=true` by default) disables ASPM **specifically for the MT7922 card**, regardless of the global ASPM policy driven by TLP. Other PCIe devices (NVMe, etc.) do follow TLP's AC/battery switching, but Wi-Fi always stays with ASPM disabled (even on battery) to avoid micro-stutter — don't "fix" this thinking it's an inconsistency.

#### 6. GNOME Widget: 80% / 100% Battery Charge Toggle

To occasionally allow charging to 100% (e.g. before a trip) without permanently giving up the 80% cap that preserves battery health, a GNOME Shell extension provides a toggle in the **Quick Settings** menu (next to Wi-Fi/Bluetooth):

- **Tracked source**: [`gnome-extension/charge-complete-bat1@peha/`](gnome-extension/charge-complete-bat1@peha/) (`extension.js` + `metadata.json`), deployed by `install.sh` to `~/.local/share/gnome-shell/extensions/`.
- **How it works**: writes `80` or `100` directly to `/sys/class/power_supply/BAT1/charge_control_end_threshold` (made writable by the udev rule from section 5) and persists the choice in `~/.config/charge_limit.conf` so it survives a reboot.
- **Enabling**: `gnome-extensions enable charge-complete-bat1@peha` (done automatically by `install.sh` — check with `gnome-extensions info charge-complete-bat1@peha`, should show `State: ACTIVE`).

**⚠️ Fixed pitfall (2026-07-24)**: the first version used `GLib.file_set_contents()` to write to sysfs, which fails every time (`Permission denied`) because that function writes via a temp file followed by a rename — a pattern that's impossible on `/sys` (you can't create a new dentry in a pseudo-filesystem). Fixed by opening the existing file directly via `Gio.File.open_readwrite()`. If the extension is ever modified again, don't reintroduce `GLib.file_set_contents()` for a path under `/sys` or `/proc`.

If the toggle doesn't show up after a GNOME Shell update, check version compatibility in `metadata.json` (`shell-version`) and any errors with:
```bash
journalctl --user -u gnome-shell --since "-5 min" | grep -i charge
```

#### 7. Full Hardware Integration

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

1. **Build & auto-patching**: looks up the latest stable release on `kernel.org`, automatically applies every `.patch` file in `patches/`, and runs `compile_kernel.sh` with all optimizations.
2. **Identification**: automatically finds the generated `.deb` packages and extracts the exact version (e.g. `7.1.4-pehacorp`).
3. **Installation**: runs `sudo dpkg -i` to install the new kernel image and headers.
4. **Safe GRUB configuration**:
   - Sets the new `-pehacorp` kernel as the **default boot kernel**.
   - Keeps a **5-second GRUB menu delay** so you can easily boot back into the generic Ubuntu kernel if something goes wrong.
5. **GRUB update**: runs `sudo update-grub`.

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

### 🚀 Installation rapide

Sur un Ubuntu fraîchement installé sur une machine identique :

```bash
git clone <url-du-dépôt> VivoNux
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

### 📁 Structure du dépôt

```text
install.sh                    # Installeur maître (point d'entrée sur machine neuve)
compile_kernel.sh             # Télécharge, patch et compile le noyau -pehacorp
update_kernel_master.sh       # Compile + installe les .deb + configure GRUB
patches/                      # Patchs appliqués automatiquement aux sources du noyau
system/etc/...                # Miroir de /etc : TLP, udev, sysctl (déployés tels quels)
system/usr/local/bin/...      # Miroir de /usr/local/bin : scripts système
gnome-extension/...           # Widget GNOME Quick Settings (charge batterie)
```

Les sources noyau téléchargées, les `.deb` compilés et les tarballs (plusieurs Go) ne sont **pas**
versionnés (voir `.gitignore`) — ils se régénèrent à la demande via la compilation.

### 🛠️ Optimisations et Choix Architecturaux

Le noyau est compilé à partir des sources officielles **Mainline (kernel.org)** en reprenant la base matérielle complète d'Ubuntu tout en injectant les optimisations de performance et d'économie d'énergie suivantes :

#### 1. Compilation Native Zen 5

- **Flags du compilateur** : `KCFLAGS="-march=znver5 -O3"`
- **Bénéfice** : Exploitation maximale des instructions matérielles du processeur Zen 5 (AVX-512, vectorisation poussée) et optimisations d'exécution `-O3`.

#### 2. Réactivité & Performance en Jeu

- **Fréquence du tick (`CONFIG_HZ_1000=y`)** : Horloge système à 1000 Hz pour réduire au strict minimum la latence d'entrée et la gigue (jitter).
- **Préemption Dynamique (`CONFIG_PREEMPT_DYNAMIC=y`)** : Permet de basculer la préemption à chaud selon l'usage (Full Preempt en jeu, Voluntary sur batterie).
- **Ordonnancement Zen 5c (`CONFIG_SCHED_MC_PRIO=y`)** : Prise en charge d'AMD Preferred Cores pour orienter les tâches gourmandes vers les cœurs Zen 5 classiques et laisser les tâches de fond aux cœurs Zen 5c économes.

#### 3. Économie d'Énergie et Autonomie sur Batterie

- **RCU Lazy (`CONFIG_RCU_LAZY=y` & `CONFIG_RCU_NOCB_CPU=y`)** : Diffère et regroupe le traitement des callbacks RCU quand le système n'est pas sous forte charge pour prolonger les états de sommeil du CPU (C-states).
- **Tickless Idle (`CONFIG_NO_HZ_IDLE=y`)** : Supprime les interruptions d'horloge lorsque les cœurs sont inactifs.

#### 4. Optimisations & Débridage Wi-Fi (MediaTek MT7922 / `mt7921e`)

- **Auto-Patching du pilote (`patches/0001-mt7921e-wifi-throughput-and-txpower.patch`)** :
  - **Désactivation ASPM par défaut** pour éviter les micro-saccades PCI Express L1/L1ss sur le chipset MT7922.
  - **Débridage de l'atténuation MCU (`txpower_drop`)** pour autoriser le plein débit sous forte charge.
  - **Extension de la profondeur du ring DMA RX (`MT7921_RX_RING_SIZE=4096`)** pour maximiser les débits descendants (RX) sans aucune perte de paquets sous saturation Fibre.
  - **Rapport de puissance émission réelle** : Correction dans `mt76_get_txpower` pour afficher les vrais dBm (20/23 dBm) dans `wavemon`, `iw` et `iwconfig`.
  - **Extension de l'agrégation AMPDU** Wi-Fi 6/6E pour débrider les débits descendants et montants.
- **Optimisations de la Pile Réseau Linux** ([`system/etc/sysctl.d/99-pehacorp-network.conf`](system/etc/sysctl.d/99-pehacorp-network.conf), déployé vers `/etc/sysctl.d/`) :
  - Backlog de réception `netdev_max_backlog = 65536` et buffers TCP de 64 Mo avec contrôle de congestion **TCP BBR**.
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

- **Seuil de charge batterie** : [`99-battery-charge-limit.rules`](system/etc/udev/rules.d/99-battery-charge-limit.rules) rend `BAT1/charge_control_end_threshold` accessible en écriture (0666). Valeur par défaut : **80 %** (géré ensuite au jour le jour par le widget GNOME, section 6). Les paramètres `START/STOP_CHARGE_THRESH_BAT*` de TLP existent dans `/etc/tlp.conf` mais sont **commentés/désactivés** : le seuil n'est donc pas piloté ni persisté par TLP, seulement rendu modifiable manuellement.

- **⚠️ Point d'attention (comportement voulu, pas un bug)** : le driver Wi-Fi patché (`mt7921_disable_aspm=true` par défaut) désactive l'ASPM **spécifiquement pour la carte MT7922**, quelle que soit la policy ASPM globale pilotée par TLP. Les autres périphériques PCIe (NVMe...) suivent bien la bascule secteur/batterie de TLP, mais le Wi-Fi reste toujours en ASPM désactivé (même sur batterie) pour éviter les micro-saccades — ne pas "corriger" ça en pensant à une incohérence.

#### 6. Widget GNOME : Bascule Charge Batterie 80% / 100%

Pour autoriser ponctuellement la charge à 100% (ex. avant un déplacement) sans renoncer en permanence à la limite de 80% qui préserve la santé de la batterie, une extension GNOME Shell fournit un toggle dans le menu **Quick Settings** (à côté du Wi-Fi/Bluetooth) :

- **Source versionnée** : [`gnome-extension/charge-complete-bat1@peha/`](gnome-extension/charge-complete-bat1@peha/) (`extension.js` + `metadata.json`), déployée par `install.sh` vers `~/.local/share/gnome-shell/extensions/`.
- **Fonctionnement** : écrit directement `80` ou `100` dans `/sys/class/power_supply/BAT1/charge_control_end_threshold` (rendu accessible en écriture par la règle udev de la section 5) et persiste le choix dans `~/.config/charge_limit.conf` pour survivre à un redémarrage.
- **Activation** : `gnome-extensions enable charge-complete-bat1@peha` (fait automatiquement par `install.sh` — vérifier avec `gnome-extensions info charge-complete-bat1@peha`, doit afficher `État: ACTIVE`).

**⚠️ Piège corrigé (24/07/2026)** : la première version utilisait `GLib.file_set_contents()` pour écrire dans le sysfs, ce qui échoue systématiquement (`Permission non accordée`) car cette fonction écrit via un fichier temporaire suivi d'un renommage — un schéma impossible sur `/sys` (impossible de créer un nouveau dentry dans un pseudo-filesystem). Corrigé en ouvrant le fichier existant directement via `Gio.File.open_readwrite()`. Si l'extension est un jour modifiée, ne pas réintroduire `GLib.file_set_contents()` pour un chemin sous `/sys` ou `/proc`.

Si le toggle n'apparaît pas après une mise à jour de GNOME Shell, vérifier la compatibilité de version dans `metadata.json` (`shell-version`) et les erreurs éventuelles avec :
```bash
journalctl --user -u gnome-shell --since "-5 min" | grep -i charge
```

#### 7. Intégration Matérielle Complète

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

1. **Compilation & Auto-Patching** : Recherche la dernière version stable sur `kernel.org`, applique automatiquement tous les fichiers `.patch` présents dans `patches/` et lance `compile_kernel.sh` avec toutes les optimisations.
2. **Identification** : Détecte automatiquement les paquets `.deb` générés et extrait la version exacte (ex: `7.1.4-pehacorp`).
3. **Installation** : Exécute `sudo dpkg -i` pour installer l'image et les en-têtes du nouveau noyau.
4. **Configuration GRUB Sécurisée** :
   - Définit le nouveau noyau `-pehacorp` comme **noyau par défaut au démarrage**.
   - Maintient un **délai de 5 secondes au menu GRUB** pour te laisser la possibilité de démarrer facilement sur le noyau générique Ubuntu en cas d'imprévu.
5. **Mise à jour GRUB** : Exécute `sudo update-grub`.

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
