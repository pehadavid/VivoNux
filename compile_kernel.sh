#!/usr/bin/env bash
set -e

# Dossier de travail (racine du dépôt, quel que soit l'endroit où il est cloné)
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"

echo "1. Interrogation de l'API kernel.org pour trouver la dernière version stable..."
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

echo "Dernière version stable identifiée : $LATEST_STABLE"

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

echo "2. Téléchargement des sources depuis $SOURCE_URL..."
if [ ! -f "$TARBALL" ]; then
    python3 -c "
import urllib.request
print('Téléchargement en cours (ceci peut prendre une minute)...')
urllib.request.urlretrieve('$SOURCE_URL', '$TARBALL')
print('Téléchargement terminé.')
"
else
    echo "Le fichier de sources $TARBALL est déjà présent."
fi

echo "3. Extraction de l'archive..."
if [ ! -d "$SRC_DIR" ]; then
    tar -xf "$TARBALL"
else
    echo "Le dossier de sources $SRC_DIR existe déjà (conservé pour la compilation incrémentale)."
fi

cd "$SRC_DIR"

echo "3b. Application des patches matériel et Wi-Fi (si présents dans $KERNEL_DIR/patches)..."
PATCH_STAMP=".pehacorp-patches-applied"
if [ -d "$KERNEL_DIR/patches" ]; then
    if [ -f "$PATCH_STAMP" ]; then
        echo "Patches déjà appliqués sur cet arbre source (stamp $PATCH_STAMP présent), on ne les réapplique pas."
    else
        for p in "$KERNEL_DIR/patches"/*.patch; do
            if [ -f "$p" ]; then
                echo "Application du patch : $(basename "$p")"
                patch -p1 --forward --no-backup-if-mismatch < "$p"
            fi
        done
        touch "$PATCH_STAMP"
    fi
fi

echo "4. Configuration du noyau..."
if [ -f .config ]; then
    echo "Un .config existe déjà dans $SRC_DIR, on le réutilise tel quel (préserve la compilation incrémentale)."
else
    echo "Pas de .config existant, initialisation depuis le noyau actif (contenant tous les pilotes génériques)..."
    cp /boot/config-$(uname -r) .config
fi

echo "5. Application des optimisations énergétiques, de jeu et du suffixe..."
# Suffixe du noyau
./scripts/config --set-str CONFIG_LOCALVERSION "-pehacorp"

# Optimisations énergétiques
./scripts/config --enable CONFIG_RCU_LAZY
./scripts/config --enable CONFIG_RCU_NOCB_CPU
./scripts/config --enable CONFIG_NO_HZ_IDLE
./scripts/config --disable CONFIG_NO_HZ_FULL

# Fréquence et planification pour le jeu (1000 HZ, Preferred Cores)
./scripts/config --disable CONFIG_HZ_100
./scripts/config --disable CONFIG_HZ_250
./scripts/config --disable CONFIG_HZ_300
./scripts/config --enable CONFIG_HZ_1000
./scripts/config --set-val CONFIG_HZ 1000
./scripts/config --enable CONFIG_SCHED_MC_PRIO

# Préemption dynamique (full pour le jeu, voluntary pour la batterie)
./scripts/config --enable CONFIG_PREEMPT_DYNAMIC

# TCP BBR (requis par /etc/sysctl.d/99-pehacorp-network.conf) : forcé explicitement
# à chaque build, sinon un olddefconfig sur une base .config qui ne l'a plus (ça
# arrive lors d'un saut de version) le laisse désactivé silencieusement — vécu le
# 24/07/2026 sur le noyau 7.1.4-pehacorp (CONFIG_TCP_CONG_BBR absent alors que la
# config Ubuntu générique de base l'avait en module).
./scripts/config --enable CONFIG_TCP_CONG_BBR

# Désactivation des certificats de confiance spécifiques à Ubuntu (évite les erreurs de clé manquante)
./scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# Désactivation des symboles de débogage pour accélérer la compilation de 10x et économiser l'espace
./scripts/config --disable CONFIG_DEBUG_INFO
./scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
./scripts/config --disable CONFIG_DEBUG_INFO_DWARF4
./scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
./scripts/config --disable CONFIG_DEBUG_INFO_BTF
./scripts/config --disable CONFIG_DEBUG_INFO_COMPRESSED
./scripts/config --disable CONFIG_DEBUG_INFO_REDUCED
./scripts/config --disable CONFIG_DEBUG_INFO_SPLIT

echo "6. Application des valeurs par défaut pour les nouvelles options de la version $LATEST_STABLE..."
make olddefconfig

echo "7. Lancement de la compilation native Zen 5 en arrière-plan..."
echo "Les paquets Debian seront générés dans $KERNEL_DIR."
make -j$(nproc) KCFLAGS="-march=znver5 -O3" bindeb-pkg
