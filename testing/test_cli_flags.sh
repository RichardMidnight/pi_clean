#!/bin/bash
# pi_clean.sh — suite for the log / --no-log / -y CLI behaviours.
# The script is COPIED into a scratch dir so real log files never land in the
# repo (CIFS live surface). runs against the skeleton apt fixture with
# the PATH shims (fake chroot/apt-get), same as test_apt_autoremove.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)/pi_clean.sh
SH="$HERE/shim_apt"
WX=/tmp/pi_clean_test/logtest
rm -rf "$WX"; mkdir -p "$WX"

PASS=0; FAIL=0
pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

# working copy + fixture
cp "$SRC" "$WX/pi_clean.sh"
FIX="$WX/aptfix"
mkdir -p "$FIX/etc" "$FIX/usr/bin"
printf 'ID=raspbian\nID_LIKE=debian\n' > "$FIX/etc/os-release"
printf '#!/bin/sh\n' > "$FIX/usr/bin/apt-get"; chmod +x "$FIX/usr/bin/apt-get"

OUT4=$'Reading package lists... Done\nBuilding dependency tree... Done\nReading state information... Done\nThe following packages will be REMOVED:\n  libc-dev-bin\n  linux-libc-dev\n  manpages-dev\n  udev\n0 upgraded, 0 newly installed, 4 to remove and 1 not to upgrade.\nAfter this operation, 5,639 kB of additional disk space will be freed.'

PATH_SH="$SH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
run() {  # run <args...> — stdin passes through, env fixed, run as root so
         # the maybe_root-gated apt section actually runs (as the other suite does)
    : > "$WX/apt.log"
    sudo env PATH="$PATH_SH" FAKE_OUT="$OUT4" FAKE_APT_LOG="$WX/apt.log" \
        SHIM_LOG="$WX/shim.log" \
        bash "$WX/pi_clean.sh" "$FIX" "$@" 2> "$WX/stderr"
}
LOGF="$WX/pi_clean.log"

echo "=== 1) -c writes a log next to the script, with header + content ==="
: > "$WX/apt.log"
out=$(printf 'y\ny\n' | run -c); rc=$?
[[ -f $LOGF ]] && pass "-c: pi_clean.log created next to the script" \
    || { fail "-c: no log file at $LOGF (rc=$rc)"; }
hdr=$(grep -m1 '^==== pi_clean' "$LOGF" 2>/dev/null)
[[ -n $hdr && $hdr == *" args: "$FIX" -c"* ]] \
    && pass "-c: header line present with args" || fail "-c: header line (got: <$hdr>)"
[[ $hdr == *"(user pi)"* ]] \
    && pass "-c: header records the user" || fail "-c: header user (got: <$hdr>)"
grep -q 'APT autoremove (orphaned dependencies)' "$LOGF" \
    && pass "-c: transcript includes the offering" || fail "-c: offering missing from log"
grep -q 'size on disk : ' "$LOGF" && pass "-c: transcript includes the size line" \
    || fail "-c: size line missing from log"
grep -q 'approx. could free\|CLEANED' "$LOGF" \
    && pass "-c: transcript includes the summary" || fail "-c: summary missing from log"
grep -q 'APTGET -y autoremove' "$WX/apt.log" \
    && pass "-c: the real autoremove was performed (y,y input)" || fail "-c: no perform (apt.log: $(cat "$WX/apt.log" 2>/dev/null))"
[[ $rc == 0 ]] && pass "-c: rc=0" || fail "-c: rc=$rc"

echo
echo "=== 2) -c -y: no stdin at all, fully automatic, logged ==="
: > "$WX/apt.log"
out=$(run -c -y < /dev/null); rc=$?
[[ $rc == 0 ]] && pass "-c -y: rc=0 with stdin closed" || fail "-c -y: rc=$rc (out: $(tail -3 <<<"$out"))"
grep -q 'APTGET -y autoremove' "$WX/apt.log" \
    && pass "-c -y: auto-approved and performed" || fail "-c -y: not performed (apt.log: $(cat "$WX/apt.log" 2>/dev/null))"
grep -q '(continuing: -y answers yes to this and every collection)' "$LOGF" \
    && pass "-c -y: gate auto-approve line in the log" || fail "-c -y: gate line missing (log: $(grep -c 'continuing' "$LOGF") hit(s))"
grep -q '(auto-approved: -y)' "$LOGF" \
    && pass "-c -y: per-collection auto-approve line in the log" || fail "-c -y: collection line missing"
[[ $out != *"delete? [y/N]"* && $out != *"continue? [y/N]"* ]] \
    && pass "-c -y: no prompts appeared on the terminal either" \
    || fail "-c -y: a prompt still appeared (out: $(grep -m1 'y/N' <<<"$out"))"

echo
echo "=== 3) --no-log: appends nothing to the log ==="
size_before=$(wc -c < "$LOGF" 2>/dev/null); size_before=${size_before:-0}
hdrs_before=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs_before=${hdrs_before:-0}
out=$(printf 'y\ny\n' | run -c --no-log); rc=$?
[[ $rc == 0 ]] && pass "--no-log: rc=0" || fail "--no-log: rc=$rc"
size_after=$(wc -c < "$LOGF" 2>/dev/null); size_after=${size_after:-0}
hdrs_after=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs_after=${hdrs_after:-0}
[[ $size_after -eq $size_before && $hdrs_after -eq $hdrs_before ]] \
    && pass "--no-log: log untouched (same size + header count)" \
    || fail "--no-log: log changed (bytes $size_before->$size_after, hdrs $hdrs_before->$hdrs_after)"
grep -q 'APTGET -y autoremove' "$WX/apt.log" \
    && pass "--no-log: the work itself still happened" || fail "--no-log: work not performed"

echo
echo "=== 4) second -c run appends a second header (same file) ==="
hdrs=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs=${hdrs:-0}
out=$(printf 'y\nn\n' | run -c); rc=$?
hdrs2=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs2=${hdrs2:-0}
[[ $hdrs2 -eq $((hdrs + 1)) ]] \
    && pass "append: header count $hdrs -> $hdrs2" || fail "append: header count $hdrs -> $hdrs2"
# the n run: nothing performed, decline visible
grep -q 'skipped\.' "$LOGF" && pass "append: declined collection logged" || fail "append: no 'skipped.' in log"

echo
echo "=== 5) reporting modes never log ==="
hdrs_before=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs_before=${hdrs_before:-0}
out1=$(run -t); rc=$?
hdrs_after=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs_after=${hdrs_after:-0}
[[ $out1 == 5774336 ]] && pass "-t: exact total still 5774336 (logging did not alter it)" \
    || fail "-t: got <$out1>"
[[ $hdrs_after -eq $hdrs_before ]] \
    && pass "-t: no header appended" || fail "-t: header appended"
hdrs_q=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs_q=${hdrs_q:-0}
out2=$(run); rc=$?
[[ $rc == 0 && $hdrs_q -eq $hdrs_before ]] \
    && pass "bare: no log, rc=0" || fail "bare: log or rc (rc=$rc headers $hdrs_q vs $hdrs_before)"
out3=$(run); rc3=$?   # default = compact report (nothing deleted)
[[ $rc3 -eq 0 && $out3 != *"delete?"* && $(grep -c '^==== pi_clean' "$LOGF") -eq $hdrs_after ]] \
    && pass "default (no flags): report, no log, no prompts" \
    || fail "default: rc=$rc3 headers=$(grep -c '^==== pi_clean' "$LOGF") out=<$out3>"
[[ $(run --no-log -t) == 5774336 ]] && pass "--no-log -t: harmless, same total" \
    || fail "--no-log -t: total changed"

echo
echo "=== 6) -y without -c: nothing is deleted, nothing asked ==="
: > "$WX/apt.log"
out=$(run -y < /dev/null); rc=$?
grep -q 'APTGET -y autoremove' "$WX/apt.log" \
    && fail "-y bare: a deletion happened!" || pass "-y bare: no deletion (dry-report semantics kept)"
[[ $rc == 0 && $out == *"collection(s)"* && $out != *"approx. could free"* ]] \
    && pass "-y bare: still a dry compact report (default form, nothing deleted)" \
    || fail "-y bare (rc=$rc out-tail: $(tail -3 <<<"$out"))"

echo
echo "=== 7) -V / --version: exact line, rc=0, no logging ==="
hdrs_before=$(grep -c '^==== pi_clean' "$LOGF" 2>/dev/null); hdrs_before=${hdrs_before:-0}
v1=$(run --version); rc=$?
[[ $rc == 0 && $v1 == "pi_clean 0.9.1" ]] && pass "--version: exact 'pi_clean 0.9.1'" \
    || fail "--version: rc=$rc got <$v1>"
v2=$(run -V); rc=$?
[[ $rc == 0 && $v2 == "pi_clean 0.9.1" ]] && pass "-V: exact 'pi_clean 0.9.1'" \
    || fail "-V: rc=$rc got <$v2>"
[[ $(grep -c '^==== pi_clean' "$LOGF") -eq $hdrs_before ]] \
    && pass "version: no log header appended" || fail "version: header appended"

echo
echo "log/no-log/-y suite: $PASS passed, $FAIL failed"
exit "$(( FAIL > 0 ))"
