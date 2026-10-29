#!/bin/bash
# Unit test for pi_clean.sh dup_apps_report — extracts the real function
# text, runs it against stubbed dpkg-query / flatpak / du mirroring the
# /media/pi/rootfs image (chromium + google-chrome-stable + firefox,
# 7zip + p7zip-full + flatpak PeaZip, single vlc/evince/libreoffice-core).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)/pi_clean.sh

# --- stubs (image ground truth) -------------------------------------------
dpkg_installed_db="chromium google-chrome-stable firefox vlc evince libreoffice-core 7zip p7zip-full flatpak"

dpkg_size_kb() { # name -> KiB (image-like magnitudes)
    case "$1" in
        chromium) echo 520000 ;;
        google-chrome-stable) echo 460000 ;;
        firefox) echo 300000 ;;
        vlc) echo 120000 ;;
        evince) echo 60000 ;;
        libreoffice-core) echo 420000 ;;
        7zip) echo 30000 ;;
        p7zip-full) echo 25000 ;;
        *) return 1 ;;
    esac
}

dpkg-query() {
    local fmt=${2:-} p=${3:-} kb
    case $fmt in
        '%{Status}')
            case " $dpkg_installed_db " in
                *" $p "*) printf 'install ok installed\n' ;;
                *) printf 'dpkg-query: no packages found matching %s\n' "$p" >&2; return 1 ;;
            esac ;;
        '${Installed-Size}')
            if kb=$(dpkg_size_kb "$p"); then printf '%s\n' "$kb"; else return 1; fi ;;
        *) return 1 ;;
    esac
}

flatpak() {
    # flatpak list --app --show-columns=application
    printf 'io.github.peazip.PeaZip\ncom.github.some.other.App\n'
    return 0
}
command_dummy() { :; }

du() {
    # du -sk PATH
    shift
    while [[ $1 == -* ]]; do shift; done
    case $1 in
        /var/lib/flatpak/app/io.github.peazip.PeaZip|"$FAKE_HOME/.local/share/flatpak/app/io.github.peazip.PeaZip")
            printf '40960\t%s\n' "$1" ;;
        *) return 1 ;;
    esac
}

human() {
    local b=$1
    if   awk "BEGIN{exit !($b >= 1073741824)}"; then printf '%sGB' "$(awk "BEGIN{printf \"%.0f\", $b/1073741824}")"
    elif awk "BEGIN{exit !($b >= 1048576)}";    then printf '%sMB' "$(awk "BEGIN{printf \"%.0f\", $b/1048576}")"
    else printf '%sB' "$b"
    fi
}

FAKE_HOME=$(mktemp -d)
export HOME="$FAKE_HOME"
BASE=""   # pi_clean always defines this ("" = live mode); the stubs model live lookups

# --- extract the real block (DUPAPP_CATS .. end of dup_apps_report) -------
TMPF=$(mktemp)
# own fixtures (FAKE_HOME dir + TMPF file) must not leak into /tmp
trap 'rm -rf -- "$FAKE_HOME" "$TMPF"' EXIT
awk '/^DUPAPP_CATS=\($/{f=1} /\[11\]/{f=0} f' "$SRC" > "$TMPF"
grep -q 'dup_apps_report()' "$TMPF" || { echo "FATAL: extraction missed dup_apps_report"; exit 2; }
source "$TMPF"

# --- run -------------------------------------------------------------------
echo '================ RUN 1 (image: duplicates present) ================'
dup_apps_report

echo
echo '================ RUN 2 (clean box: one app per category) ================'
dpkg_installed_db="firefox vlc evince nomacs"
flatpak() { printf '\n'; }
dup_apps_report
