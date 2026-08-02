#!/usr/bin/env bash
# Nettoie le dossier VivoNux des fichiers volumineux devenus inutiles :
# anciennes archives/sources kernel.org, anciens builds .deb, et résidus
# d'un ancien workflow (paquet source Debian, version 7.0.0). Tout ce qui
# est supprimé ici est régénérable via install.sh / compile_kernel.sh
# (mêmes motifs que .gitignore).
set -e

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"
shopt -s nullglob

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [simulation] rm -f -- $*"
    else
        echo "  Suppression : $*"
        rm -rf -- "$@"
    fi
}

echo "=========================================================="
echo "  VivoNux — Nettoyage du dossier                          "
echo "=========================================================="
[ "$DRY_RUN" -eq 1 ] && echo "(mode simulation --dry-run : rien ne sera supprimé)"
echo ""

DISK_BEFORE=$(du -sh "$KERNEL_DIR" 2>/dev/null | cut -f1)

# --- 1. Versions noyau ayant encore un build .deb dans ce dossier --------
# Chaque canal (stable / rc / beta) a sa propre version source ; on garde,
# pour chaque version source présente, uniquement le build (.deb) le plus
# récent -- ce qui permet à un build stable et un build rc/beta de coexister
# sans que l'un efface les sources de l'autre.
declare -A KEPT_BUILD_VER   # version source -> version de build à conserver
while IFS= read -r f; do
    [ -n "$f" ] || continue
    srcver=$(echo "$f" | sed -E 's/^linux-image-(.*)-pehacorp_.*/\1/')
    buildver=$(echo "$f" | sed -E 's/.*_([0-9][^_]*)_amd64\.deb$/\1/')
    # ls -t liste du plus récent au plus ancien : la première fois qu'on
    # rencontre une version source donnée, c'est donc son build le plus récent.
    if [ -z "${KEPT_BUILD_VER[$srcver]:-}" ]; then
        KEPT_BUILD_VER[$srcver]="$buildver"
    fi
done < <(ls -t linux-image-*-pehacorp_*_amd64.deb 2>/dev/null)

if [ ${#KEPT_BUILD_VER[@]} -eq 0 ]; then
    echo "Aucun paquet linux-image-*-pehacorp_*.deb trouvé : les archives et sources"
    echo "kernel.org seront conservées par prudence (impossible de savoir lesquelles sont actives)."
else
    for srcver in "${!KEPT_BUILD_VER[@]}"; do
        echo "Noyau compilé ici : $srcver (build ${KEPT_BUILD_VER[$srcver]}) -- conservé"
    done
fi
echo ""

# --- 2. Anciennes archives sources kernel.org (linux-X.Y.Z.tar.xz) -------
if [ ${#KEPT_BUILD_VER[@]} -gt 0 ]; then
    echo "=== Archives sources (linux-*.tar.xz) ==="
    for f in linux-*.tar.xz; do
        ver=$(echo "$f" | sed -E 's/^linux-(.*)\.tar\.xz$/\1/')
        if [ -n "${KEPT_BUILD_VER[$ver]:-}" ]; then
            echo "  Conservé (version active) : $f"
        else
            run "$f"
        fi
    done
    echo ""

    # --- 3. Anciens répertoires sources extraits (linux-X.Y.Z/) ----------
    echo "=== Répertoires sources extraits (linux-*/) ==="
    for d in linux-*/; do
        ver="${d%/}"
        ver="${ver#linux-}"
        if [ -n "${KEPT_BUILD_VER[$ver]:-}" ]; then
            echo "  Conservé (version active, permet un rebuild incrémental) : $d"
        else
            run "$d"
        fi
    done
    echo ""
fi

# --- 4. Résidus d'un ancien workflow (paquet source Debian, 7.0.0) -------
echo "=== Fichiers hérités (ancien format paquet source Debian) ==="
LEGACY_FILES=(linux_*.orig.tar.gz linux_*.diff linux_*.diff.gz linux_*.dsc)
if [ ${#LEGACY_FILES[@]} -eq 0 ]; then
    echo "  Rien à nettoyer."
else
    for f in "${LEGACY_FILES[@]}"; do
        run "$f"
    done
fi
echo ""

# --- 5. Anciens builds .deb (on garde le dernier build de chaque version) --
if [ ${#KEPT_BUILD_VER[@]} -gt 0 ]; then
    echo "=== Anciens paquets .deb (on garde le dernier build de chaque version noyau) ==="
    OLD_PKG_FILES=(linux-image-*-pehacorp_*_amd64.deb linux-headers-*-pehacorp_*_amd64.deb \
        linux-libc-dev_*_amd64.deb linux-upstream_*_amd64.buildinfo linux-upstream_*_amd64.changes)
    if [ ${#OLD_PKG_FILES[@]} -eq 0 ]; then
        echo "  Rien à nettoyer."
    else
        for f in "${OLD_PKG_FILES[@]}"; do
            kept=0
            for buildver in "${KEPT_BUILD_VER[@]}"; do
                case "$f" in
                    *"_${buildver}_"*) kept=1; break ;;
                esac
            done
            if [ "$kept" -eq 1 ]; then
                echo "  Conservé (build actif) : $f"
            else
                run "$f"
            fi
        done
    fi
    echo ""
fi

# --- 6. Fichiers résiduels de test ----------------------------------------
TEST_FILES=(*_TESTCOPY)
if [ ${#TEST_FILES[@]} -gt 0 ]; then
    echo "=== Fichiers résiduels ==="
    for f in "${TEST_FILES[@]}"; do
        run "$f"
    done
    echo ""
fi

DISK_AFTER=$(du -sh "$KERNEL_DIR" 2>/dev/null | cut -f1)
echo "=========================================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  Simulation terminée : aucun fichier supprimé."
    echo "  Taille actuelle du dossier : $DISK_BEFORE"
else
    echo "  Nettoyage terminé."
    echo "  Taille du dossier : $DISK_BEFORE -> $DISK_AFTER"
fi
echo "=========================================================="
