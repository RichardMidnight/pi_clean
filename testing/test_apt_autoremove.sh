#!/bin/bash
# pi_clean.sh — regression suite for the new "apt autoremove" section.
# Non-destructive: chroot and apt-get are PATH shims (see shim_apt/), the
# image is a skeleton dir. Expects: bash, sudo (passwordless, sandbox),
# the script at $PC.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PC=$(cd "$HERE/.." && pwd)/pi_clean.sh
SH="$HERE/shim_apt"
WX=/tmp/pi_clean_test/aptwork
rm -rf "$WX"; mkdir -p "$WX"

PASS=0; FAIL=0
pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

# ---- fixtures (skeleton base dirs) ---------------------------------------
FIX="$WX/aptfix"; FIXNO="$WX/aptfix_noapt"
for d in "$FIX" "$FIXNO"; do
    rm -rf "$d"; mkdir -p "$d/etc"
    printf 'ID=raspbian\nID_LIKE=debian\n' > "$d/etc/os-release"
done
mkdir -p "$FIX/usr/bin"
printf '#!/bin/sh\n' > "$FIX/usr/bin/apt-get"; chmod +x "$FIX/usr/bin/apt-get"

# ---- canned apt outputs ----------------------------------------------------
OUT4=$'Reading package lists... Done\nBuilding dependency tree... Done\nReading state information... Done\nThe following packages will be REMOVED:\n  libc-dev-bin\n  linux-libc-dev\n  manpages-dev\n  udev\n0 upgraded, 0 newly installed, 4 to remove and 1 not to upgrade.\nAfter this operation, 5,639 kB of additional disk space will be freed.'
OUT0=$'Reading package lists... Done\nBuilding dependency tree... Done\nReading state information... Done\n0 to remove and 0 not to upgrade.'
OUTGB=$'Reading package lists... Done\nBuilding dependency tree... Done\nReading state information... Done\nThe following packages will be REMOVED:\n  libreoffice-writer\n  libreoffice-core\n0 upgraded, 0 newly installed, 2 to remove and 0 not to upgrade.\nAfter this operation, 1.25 GB of additional disk space will be freed.'
H4=$(numfmt --to=iec --suffix=B 5774336 2>/dev/null)        # 5,639 kB -> bytes
HGB=$(numfmt --to=iec --suffix=B 1342177280 2>/dev/null)    # 1.25 GB -> bytes

PATH_SH="$SH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# run_base <failall> <fixture> <args...>   (stdin passes through)
run_base() {
    local fa=$1 fx=$2; shift 2
    : > "$WX/apt.log"; : > "$WX/shim.log"
    sudo env PATH="$PATH_SH" FAKE_OUT="$FAKE_OUT_G" \
        FAKE_APT_LOG="$WX/apt.log" SHIM_LOG="$WX/shim.log" SHIM_FAILALL="$fa" \
        bash "$PC" "$fx" "$@" 2> "$WX/stderr"
}

# ---------------------------------------------------------------- 1) -t exact
FAKE_OUT_G="$OUT4"
out=$(run_base 0 "$FIX" -t); rc=$?
[[ $rc == 0 && $out == 5774336 ]] \
    && pass "-t base: exactly apt's own freed-bytes (5774336)" \
    || fail "-t base (rc=$rc out=<$out>, wanted 5774336)"

# ---------------------------------------------------------------- 2) bare line
FAKE_OUT_G="$OUT4"
out=$(run_base 0 "$FIX")
[[ $out == *"could free $H4 across 1 collection(s)"* ]] \
    && pass "bare base: summary line exact (could free $H4)" \
    || fail "bare base (got: <$out>)"
[[ $out == *"APT autoremove (orphaned dependencies)"* ]] \
    && pass "bare base: named in the dry list" \
    || fail "bare base: not in dry list"

# ---------------------------------------------------------------- 3) answer n
FAKE_OUT_G="$OUT4"
out=$(printf 'y\nn\n' | run_base 0 "$FIX" -c --no-log); rc=$?
if grep -q 'APTGET -y autoremove' "$WX/apt.log"; then
    fail "n: real autoremove invoked (bad)"
else
    pass "n: no real autoremove invoked"
fi
[[ $rc == 0 && $out == *"SKIPPED:    1 collection(s)"* && $out == *"APT autoremove"* ]] \
    && pass "n: counted as skipped with right name" \
    || fail "n: skip summary (rc=$rc got: <$out>)"

# ---------------------------------------------------------------- 4) answer y
FAKE_OUT_G="$OUT4"
: > "$WX/apt.log"
out=$(printf 'y\ny\n' | run_base 0 "$FIX" -c --no-log); rc=$?
grep -q 'APTGET -y autoremove' "$WX/apt.log" \
    && pass "y: real 'apt-get -y autoremove' was run" \
    || fail "y: no real autoremove (log: $(cat "$WX/apt.log" 2>/dev/null))"
[[ $out == *"CLEANED:    1 collection(s), approx. $H4"* ]] \
    && pass "y: summary 'CLEANED: 1 collection(s), approx. $H4'" \
    || fail "y: summary (got: <$out>)"
# exactly one sim call per confirm cycle: one -s, one -y
[[ $(grep -c 'APTGET -s autoremove' "$WX/apt.log") == 1 ]] \
    && pass "y: exactly one dry-run simulation" \
    || fail "y: sim count ($(grep -c 'APTGET -s autoremove' "$WX/apt.log"))"

# ---------------------------------------------------------------- 5) 0 to remove
FAKE_OUT_G="$OUT0"
out=$(run_base 0 "$FIX" -t); rc=$?
[[ $rc == 0 && $out == 0 ]] \
    && pass "0-to-remove -t: reports 0" \
    || fail "0-to-remove -t (rc=$rc out=<$out>)"

# ---------------------------------------------------------------- 6) chroot fails
FAKE_OUT_G="$OUT4"
out=$(run_base 1 "$FIX" -t); rc=$?
err=$(cat "$WX/stderr" 2>/dev/null)
[[ $rc == 0 && $out == 0 ]] && pass "chroot-fail -t: rc=0, total 0" \
    || fail "chroot-fail -t (rc=$rc out=<$out>)"
# non-quiet run: the reason must be visible on the script's stderr
err2=$(cat "$WX/stderr" 2>/dev/null)
echo y | out_i=$(run_base 1 "$FIX" -c --no-log)
err2=$(cat "$WX/stderr" 2>/dev/null)
[[ $err2 == *"could not be evaluated"* && $err2 == *"Invalid argument"* ]] \
    && pass "chroot-fail: stderr explains the failure" \
    || fail "chroot-fail stderr (err: <$err2>)"

# ---------------------------------------------------------------- 7) no apt in image
FAKE_OUT_G="$OUT4"
out=$(echo y | run_base 0 "$FIXNO" -c --no-log)
[[ $out == *"not applicable — no /usr/bin/apt-get"* ]] \
    && pass "no-apt image: polite 'not applicable' skip" \
    || fail "no-apt image (got: <$out>)"

# ---------------------------------------------------------------- 8) GB parsing
FAKE_OUT_G="$OUTGB"
out=$(run_base 0 "$FIX" -t); rc=$?
[[ $rc == 0 && $out == 1342177280 ]] \
    && pass "GB parse: 1.25 GB -> 1342177280 bytes" \
    || fail "GB parse (rc=$rc out=<$out>, wanted 1342177280)"
# and the package list still surfaced
out=$(printf 'y\nn\n' | run_base 0 "$FIX" -c --no-log)
[[ $out == *"  - libreoffice-writer"* && $out == *"  - libreoffice-core"* ]] \
    && pass "GB variant: package list shown" \
    || fail "GB variant: package list (got: <$out>)"

# ---------------------------------------------------------------- 9) live non-root gate
# -v: the gate line is verbose-only chatter (default is now the compact report)
out=$(echo y | bash "$PC" -v 2>&1)
[[ $out == *"[apt autoremove] skipped — needs root"* ]] \
    && pass "live non-root: section correctly gated" \
    || fail "live non-root gate"

# ---------------------------------------------------------------- 10) default is a compact dry report
FAKE_OUT_G="$OUT4"
: > "$WX/apt.log"
out=$(run_base 0 "$FIX"); rc=$?
[[ $rc == 0 ]] \
    && pass "default: rc=0 with no flags at all" || fail "default (rc=$rc)"
[[ $out == *"could free $H4 across 1 collection(s)"* ]] \
    && pass "default: compact summary lists the collection and its size" \
    || fail "default: compact summary (got: <$out>)"
[[ $out != *"approx. could free"* && $out != *"collections offered"* ]] \
    && pass "default: compact form (not the verbose transcript)" \
    || fail "default: verbose form leaked in (got: <$out>)"
[[ $out == *"image root : $FIX"* && $out == *"report only — nothing will be deleted"* ]] \
    && pass "default: states what it is inspecting and that it only reports" \
    || fail "default: target/mode lines missing (got: <$out>)"
[[ $out == *"delete? [y/N]"* ]] && fail "default: must not prompt" || pass "default: no delete prompts"
[[ $out == *"continue? [y/N]"* ]] && fail "default: must not ask 'continue'" || pass "default: no 'continue' gate"
grep -q 'APTGET -y autoremove' "$WX/apt.log" && fail "default: must not delete" \
    || pass "default: nothing deleted (real apt-get never invoked)"

# ---------------------------------------------------------------- 11) -n is the same safe alias
out=$(run_base 0 "$FIX" -n); rc=$?
[[ $rc == 0 && $out == *"could free $H4 across 1 collection(s)"* && $out != *"delete?"* ]] \
    && pass "-n alias: compact summary, no prompts" || fail "-n alias (rc=$rc got: <$out>)"

# ---------------------------------------------------------------- 12) -c still wins nothing over -t
out=$(run_base 0 "$FIX" -c -t); rc=$?
[[ $rc == 0 && $out == 5774336 ]] \
    && pass "-c -t: reporting mode wins, exact bytes" || fail "-c -t (rc=$rc out=<$out>)"

echo
echo "apt-autoremove suite: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
