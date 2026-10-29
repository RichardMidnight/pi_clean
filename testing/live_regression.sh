#!/bin/bash
# Live-mode regression for pi_clean.sh (no target), against a planted HOME.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$HERE/.." && pwd)/pi_clean.sh
H=/tmp/pi_clean_test/pi_clean_test2/home
# The script resolves the live home as $HOME (pi_clean.sh:93) — the test
# MUST point HOME at the fixture, and every destructive step below is
# guarded by checking the header really names the fixture.
export HOME="$H"

plant() {
    rm -rf "$H"
    mkdir -p "$H/.cache/thumbnails/large" "$H/.cache/pip/http-v2" "$H/.npm/_cacache/content-v2" \
             "$H/.config/chromium/Default/Cache" \
             "$H/.config/chromium/Default/Code Cache" \
             "$H/.config/chromium/Default/Service Worker/CacheStorage" \
             "$H/.config/chromium/Default/History" \
             "$H/Downloads" "$H/Documents" \
             "$H/.local/share/Trash/files" "$H/.local/share/Trash/info"
    for p in "$H/.cache/thumbnails/large/a" "$H/.cache/pip/http-v2/b" \
             "$H/.npm/_cacache/content-v2/c" "$H/.config/chromium/Default/Cache/d" \
             "$H/.config/chromium/Default/Code Cache/e" \
             "$H/.config/chromium/Default/Service Worker/CacheStorage/f" \
             "$H/Downloads/pkg.deb"; do
        head -c 262144 /dev/zero > "$p"
    done
    head -c 131072 /dev/zero > "$H/.config/chromium/Default/History/1"   # DECOY: must survive
    head -c 1024    /dev/zero > "$H/Documents/notes.txt"                  # DECOY: must survive
    echo "trashed"  > "$H/.local/share/Trash/files/waste.txt"
    echo "info"     > "$H/.local/share/Trash/info/waste.txt.trashinfo"
}

plant

echo "=== 1) -h: usage only, exit 0 ==="
out=$(bash "$P" -h); rc=$?
echo "$out" | head -8; echo "[rc=$rc]"
[[ $rc -eq 0 && "$out" == *Usage* ]] && echo "PASS: -h" || { echo "FAIL: -h"; exit 1; }

echo
echo "=== 2) -n -t: exactly one numeric line, nothing deleted ==="
out=$(bash "$P" -n -t); rc=$?
lines=$(printf '%s\n' "$out" | wc -l)
echo "out='$out' [rc=$rc lines=$lines]"
[[ $rc -eq 0 && $lines -eq 1 && "$out" =~ ^[0-9]+$ ]] && echo "PASS: -n -t" || { echo "FAIL: -n -t"; exit 1; }
[[ -f "$H/Downloads/pkg.deb" ]] && echo "PASS: nothing deleted" || { echo "FAIL: already deleted"; exit 1; }

echo
echo "=== 3) -n: compact summary, nothing deleted ==="
bash "$P" -n; rc=$?
echo "[rc=$rc]"
[[ -f "$H/Downloads/pkg.deb" && -f "$H/.local/share/Trash/files/waste.txt" ]] && echo "PASS: nothing deleted" || { echo "FAIL: already deleted"; exit 1; }

echo
echo "=== 4) default run is a safe dry report (no gate, no delete) ==="
out=$(printf '\n' | bash "$P" 2>&1); rc=$?
echo "$out" | tail -3; echo "[rc=$rc]"
# default is now the compact form: "could free XMB across N collection(s)"
[[ $rc -eq 0 ]] && echo "PASS: default rc=0" || { echo "FAIL: default rc=$rc"; exit 1; }
[[ "$out" == *"could free"*"collection(s)"* && "$out" != *"approx. could free"* ]] \
    && echo "PASS: default is the compact summary" || { echo "FAIL: default form (got: $out)"; exit 1; }
[[ "$out" == *"machine    : this box"* && "$out" == *"report only — nothing will be deleted"* ]] \
    && echo "PASS: default states what it is inspecting" || { echo "FAIL: target/mode lines (got: $out)"; exit 1; }
[[ "$out" == *"aborted"* ]] && { echo "FAIL: default must not gate"; exit 1; }
[[ -f "$H/Downloads/pkg.deb" ]] && echo "PASS: nothing deleted" || { echo "FAIL: already deleted"; exit 1; }

echo
echo "=== 4b) -c keeps the 'continue?' gate (Enter aborts) ==="
out=$(printf '\n' | bash "$P" -c --no-log 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"aborted — nothing was touched"* ]] \
    && echo "PASS: -c gate abort" || { echo "FAIL: -c gate abort"; exit 1; }
[[ -f "$H/Downloads/pkg.deb" ]] && echo "PASS: nothing deleted" || { echo "FAIL: already deleted"; exit 1; }

echo
echo "=== 5) full y run (non-root: system sections skipped) ==="
# -v: the header is verbose-only chatter (default is now the compact report)
hdr=$(bash "$P" -v -n 2>&1 | head -5 | tr '\n' ' ')
case "$hdr" in
    *"user home: $H"*) : ;;   # fixture is the target — proceed
    *) printf 'ABORT: header does not name the fixture (%s)\n' "$hdr"; exit 1 ;;
esac
bash "$P" -c --no-log < <(yes y) | tail -20
echo "[rc=${PIPESTATUS[0]}]"
[[ ! -f "$H/Downloads/pkg.deb" && ! -f "$H/.local/share/Trash/files/waste.txt" ]] \
    && echo "PASS: junk deleted" || { echo "FAIL: junk remains"; exit 1; }
[[ -f "$H/.config/chromium/Default/History/1" && -f "$H/Documents/notes.txt" ]] \
    && echo "PASS: decoys survived" || { echo "FAIL: decoys lost"; exit 1; }

echo
echo "ALL LIVE REGRESSION CHECKS PASSED"
