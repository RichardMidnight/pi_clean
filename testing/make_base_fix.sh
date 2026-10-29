#!/bin/bash
# Build the fake rootfs fixture for target tests
set -euo pipefail
F=/tmp/pi_clean_test/base_fix
rm -rf "$F"
mkdir -p "$F"/etc

# --- os-release (validation anchor) -----------------------------------
cat > "$F/etc/os-release" <<'EOF'
PRETTY_NAME="Raspberry Pi OS (bookworm)"
NAME="Raspberry Pi OS"
VERSION="13 (bookworm)"
ID=raspbian
ID_LIKE=debian
EOF

# --- kernels: two versions, NEWEST must be the one kept ---------------
# 6.18.50 (newest, kept) and 6.12.47 (old, offered)
KNEW=6.18.50+rpi-v8
KOLD=6.12.47+rpi-v8
for v in "$KNEW" "$KOLD"; do
    for art in System.map config vmlinux initrd.img; do
        mkdir -p "$F/boot"
        # vmlinux biggest, config medium, others small
        case $art in
            vmlinux)    sz=$(( 3000 * 1024 ));;
            config)     sz=$(( 1500 * 1024 ));;
            System.map) sz=$(( 2000 * 1024 ));;
            initrd.img) sz=$(( 5000 * 1024 ));;
        esac
        dd if=/dev/zero of="$F/boot/$art-$v" bs=1024 count=$((sz/1024)) status=none
    done
    mkdir -p "$F/usr/lib/modules/$v/kernel"
    dd if=/dev/zero of="$F/usr/lib/modules/$v/kernel/modules.bin" bs=1024 count=2048 status=none
done
# newest mtime: newest wins the keep
touch -d '2026-10-27 12:00' "$F/boot"/*-"$KNEW"
touch -d '2026-10-01 09:00' "$F/boot"/*-"$KOLD"
touch -d '2026-10-27 12:00' "$F/usr/lib/modules/$KNEW"
touch -d '2026-10-01 09:00' "$F/usr/lib/modules/$KOLD"

# --- dpkg status (dup-apps report) ------------------------------------
mkdir -p "$F/var/lib/dpkg"
cat > "$F/var/lib/dpkg/status" <<'EOF'
Package: chromium
Status: install ok installed
Installed-Size: 600000
Description: Chromium browser

Package: google-chrome-stable
Status: install ok installed
Installed-Size: 150000
Description: Google Chrome

Package: firefox
Status: install ok installed
Installed-Size: 400000
Description: Firefox browser

Package: 7zip
Status: install ok installed
Installed-Size: 10000
Description: 7-Zip archive manager

Package: p7zip-full
Status: install ok installed
Installed-Size: 11000
Description: 7-Zip (full package)

Package: vlc
Status: install ok installed
Installed-Size: 350000
Description: VLC media player

Package: evince
Status: install ok installed
Installed-Size: 90000
Description: PDF viewer (gnome)

Package: libreoffice-core
Status: install ok installed
Installed-Size: 200000
Description: LibreOffice core
EOF

# --- flatpak: KeaZip references Platform; org.kde.Platform unused -----
FP=$F/var/lib/flatpak
mkdir -p "$FP/app/io.github.peazip.PeaZip/x86_64/stable/deadbeef"
cat > "$FP/app/io.github.peazip.PeaZip/x86_64/stable/deadbeef/metadata" <<'EOF'
[Application]
name=io.github.peazip.PeaZip
runtime=org.freedesktop.Platform
sdk=org.freedesktop.Sdk

[Metadata]
app=io.github.peazip.PeaZip
EOF
mkdir -p "$FP/app/io.github.peazip.PeaZip/x86_64/stable/deadbeef/files"
dd if=/dev/zero of="$FP/app/io.github.peazip.PeaZip/x86_64/stable/deadbeef/files/app.bin" bs=1024 count=512 status=none

# referenced runtime (KEPT)
PT="$FP/runtime/org.freedesktop.Platform/x86_64/24.08/cafef00d"
mkdir -p "$PT/files"
echo 'name=org.freedesktop.Platform' > "$PT/metadata"
dd if=/dev/zero of="$PT/files/lib" bs=1024 count=2048 status=none
cat > "$PT/extensions.yaml" <<'EOF'
org.freedesktop.Platform.Locale:
  add-extensions:
    - org.freedesktop.Platform.Locale
org.freedesktop.Platform.OpenGLES:
  add-extensions:
    - org.freedesktop.Platform.OpenGLES
openh264:
  autodelete: false
EOF
# referenced SDK (KEPT via the app's sdk= metadata line)
SK="$FP/sdk/org.freedesktop.Sdk/x86_64/24.08/deadbeef"
mkdir -p "$SK/files"
echo 'name=org.freedesktop.Sdk' > "$SK/metadata"
dd if=/dev/zero of="$SK/files/libsdk" bs=1024 count=3072 status=none
# unreferenced runtime (OFFERED)
KT="$FP/runtime/org.kde.Platform/x86_64/6.1.0/f00d1122"
mkdir -p "$KT/files"
echo 'name=org.kde.Platform' > "$KT/metadata"
dd if=/dev/zero of="$KT/files/libkde" bs=1024 count=4096 status=none

# --- journal: one old, one fresh ---------------------------------------
mkdir -p "$F/var/log/journal"
dd if=/dev/zero of="$F/var/log/journal/old.journal" bs=1024 count=1024 status=none
touch -d '2026-10-01' "$F/var/log/journal/old.journal"
dd if=/dev/zero of="$F/var/log/journal/fresh.journal" bs=1024 count=512 status=none

# --- apt cache + lists ---------------------------------------------------
mkdir -p "$F/var/cache/apt/archives" "$F/var/lib/apt/lists"
dd if=/dev/zero of="$F/var/cache/apt/archives/foo.deb" bs=1024 count=2048 status=none
dd if=/dev/zero of="$F/var/cache/apt/archives/bar.deb" bs=1024 count=1024 status=none
mkdir -p "$F/var/lib/apt/lists/partial"
dd if=/dev/zero of="$F/var/lib/apt/lists/partial/x" bs=1024 count=256 status=none

# --- home de: browser junk + decoys + downloads --------------------------
H=$F/home/de
mkdir -p \
  "$H/.cache/thumbnails/large" \
  "$H/.cache/pip/http-v2" \
  "$H/.npm/_cacache/content-v2" \
  "$H/.config/chromium/Default/Cache" \
  "$H/.config/chromium/Default/Code Cache" \
  "$H/.config/chromium/Default/Service Worker/CacheStorage" \
  "$H/.config/chromium/Default/IndexedDB" \
  "$H/.config/chromium/Default/Local Storage/leveldb" \
  "$H/.config/chromium/Default/History" \
  "$H/Downloads" \
  "$H/.local/share/Trash/files" \
  "$H/.local/share/Trash/info" \
  "$F/tmp"
# junk (deletable)
for p in \
  "$H/.cache/thumbnails/large/a" \
  "$H/.cache/pip/http-v2/b" \
  "$H/.npm/_cacache/content-v2/c" \
  "$H/.config/chromium/Default/Cache/d" \
  "$H/.config/chromium/Default/Code Cache/e" \
  "$H/.config/chromium/Default/Service Worker/CacheStorage/f" \
  "$H/.config/chromium/Default/IndexedDB/g" \
  "$H/.config/chromium/Default/Local Storage/leveldb/h" \
  "$H/.local/share/Trash/files/waste.img" \
  "$H/Downloads/some-install.deb"; do
  dd if=/dev/zero of="$p" bs=1024 count=256 status=none
done
# DECOY that must survive (live data)
dd if=/dev/zero of="$H/.config/chromium/Default/History/1" bs=1024 count=128 status=none
# trash info dir
echo 'trashinfo' > "$H/.local/share/Trash/info/waste.img.trashinfo"
# stale tmp
dd if=/dev/zero of="$F/tmp/stale" bs=1024 count=256 status=none
touch -d '2026-10-01' "$F/tmp/stale"

echo "fixture at $F :"
du -sh "$F" 2>/dev/null || true
