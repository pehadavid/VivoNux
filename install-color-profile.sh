#!/usr/bin/env bash
# Import an ICC/ICM profile for the VivoNux internal OLED panel and make it
# the default in colord. Defaults to the bundled ATNA60BX01-1.icc (measured
# by Notebookcheck on the same Samsung panel, X-Rite i1Basic Pro 3, ΔE 2.42
# calibrated) but accepts any other profile obtained legally instead.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROFILE="$SCRIPT_DIR/ATNA60BX01-1.icc"
EXPECTED_PANEL="ATNA60BX01-1"
FORCE=0

usage() {
    cat <<EOF
Usage: ./install-color-profile.sh [--force] [PROFILE.icc]

Imports an ICC/ICM profile into colord and assigns it to the internal display.
The detected panel must be Samsung ATNA60BX01-1 unless --force is specified.
PROFILE.icc defaults to the bundled $DEFAULT_PROFILE if omitted.

Run this command as the logged-in desktop user, not with sudo.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            [ -z "${PROFILE_ARG:-}" ] || die "only one profile can be installed at a time"
            PROFILE_ARG="$1"
            shift
            ;;
    esac
done

PROFILE_ARG="${PROFILE_ARG:-$DEFAULT_PROFILE}"
[ -f "$PROFILE_ARG" ] || {
    usage >&2
    die "no profile given and bundled default not found: $DEFAULT_PROFILE"
}

[ "${EUID:-$(id -u)}" -ne 0 ] \
    || die "do not run this script with sudo; colord profiles are installed per user"

PROFILE_PATH="$(readlink -f -- "$PROFILE_ARG")"
[ -f "$PROFILE_PATH" ] || die "profile not found: $PROFILE_ARG"
[ -r "$PROFILE_PATH" ] || die "profile is not readable: $PROFILE_PATH"

# Validate the header before passing the file to colord:
# bytes 12-15 are the device class ("mntr"), bytes 16-19 the data color
# space ("RGB "), and bytes 36-39 the mandatory "acsp" signature.
ICC_DEVICE_CLASS="$(od -An -tx1 -j12 -N4 "$PROFILE_PATH" 2>/dev/null | tr -d '[:space:]')"
ICC_COLORSPACE="$(od -An -tx1 -j16 -N4 "$PROFILE_PATH" 2>/dev/null | tr -d '[:space:]')"
ICC_SIGNATURE="$(od -An -tx1 -j36 -N4 "$PROFILE_PATH" 2>/dev/null | tr -d '[:space:]')"
[ "$ICC_SIGNATURE" = "61637370" ] \
    || die "$PROFILE_PATH is not a valid ICC/ICM profile (missing acsp signature)"
[ "$ICC_DEVICE_CLASS" = "6d6e7472" ] \
    || die "$PROFILE_PATH is not a display profile (ICC device class is not mntr)"
[ "$ICC_COLORSPACE" = "52474220" ] \
    || die "$PROFILE_PATH is not an RGB display profile"

PANEL_FOUND=""
shopt -s nullglob
for edid_path in /sys/class/drm/card*-eDP-*/edid; do
    [ -r "$edid_path" ] || continue
    if grep -aFq "$EXPECTED_PANEL" "$edid_path"; then
        PANEL_FOUND="$EXPECTED_PANEL"
        break
    fi
done
shopt -u nullglob

if [ -z "$PANEL_FOUND" ] && [ "$FORCE" -ne 1 ]; then
    die "Samsung $EXPECTED_PANEL was not detected on an internal eDP connector; use --force only if this is intentional"
fi

command -v colormgr >/dev/null 2>&1 \
    || die "colormgr is missing; install the 'colord' package first"

echo "Profile : $PROFILE_PATH"
if [ -n "$PANEL_FOUND" ]; then
    echo "Panel   : Samsung $PANEL_FOUND (verified from EDID)"
else
    echo "Panel   : verification bypassed with --force"
fi

if ! colormgr get-profiles >/dev/null 2>&1; then
    die "cannot connect to colord; run this script from the logged-in graphical session"
fi

# Importing an already known profile can return a non-zero status. Resolution
# below is authoritative: it accepts an existing profile but rejects a real
# import failure.
IMPORT_OUTPUT="$(colormgr import-profile "$PROFILE_PATH" 2>/dev/null || true)"

PROFILE_OBJECT="$(
    awk -F': ' '/^Object Path:/ { print $2; exit }' <<<"$IMPORT_OUTPUT"
)"

if [ -z "$PROFILE_OBJECT" ]; then
    PROFILE_OBJECT="$(
        colormgr find-profile-by-filename "$PROFILE_PATH" 2>/dev/null \
            | awk -F': ' '/^Object Path:/ { print $2; exit }' \
            || true
    )"
fi

# Some colord versions resolve only the copied ~/.local/share/icc filename
# rather than the original source filename.
if [ -z "$PROFILE_OBJECT" ]; then
    IMPORTED_PATH="$HOME/.local/share/icc/$(basename "$PROFILE_PATH")"
    PROFILE_OBJECT="$(
        colormgr find-profile-by-filename "$IMPORTED_PATH" 2>/dev/null \
            | awk -F': ' '/^Object Path:/ { print $2; exit }' \
            || true
    )"
fi

[ -n "$PROFILE_OBJECT" ] || die "profile was imported but its colord object could not be resolved"

DISPLAY_LIST="$(colormgr get-devices-by-kind display 2>/dev/null || true)"
DEVICE_OBJECT="$(
    awk -F': ' '
        /^Object Path:/ { object = $2 }
        /^[[:space:]]*Embedded:/ && $2 == "Yes" {
            print object
            exit
        }
    ' <<<"$DISPLAY_LIST"
)"

if [ -z "$DEVICE_OBJECT" ]; then
    echo "Profile imported successfully, but no internal display is currently registered in colord."
    echo "Log into GNOME, then run this script again to assign it automatically."
    exit 0
fi

# Adding an existing association is harmless; only fail if the profile still
# cannot be selected as the default afterwards.
colormgr device-add-profile "$DEVICE_OBJECT" "$PROFILE_OBJECT" >/dev/null 2>&1 || true
colormgr device-make-profile-default "$DEVICE_OBJECT" "$PROFILE_OBJECT" \
    || die "the profile was imported but could not be made the internal display default"

DEFAULT_OBJECT="$(
    colormgr device-get-default-profile "$DEVICE_OBJECT" 2>/dev/null \
        | awk -F': ' '/^Object Path:/ { print $2; exit }' \
        || true
)"
[ "$DEFAULT_OBJECT" = "$PROFILE_OBJECT" ] \
    || die "colord did not retain the profile as the internal display default"

echo "Color profile installed and selected for the internal display."
