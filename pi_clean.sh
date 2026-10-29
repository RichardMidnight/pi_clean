#!/bin/bash
# pi_clean.sh — scan a Raspberry Pi for reclaimable files and propose
# deletions, one collection at a time, with a description and an
# explicit y/N prompt before anything is removed.
#
# Usage:  pi_clean.sh [options]
#   (no flags)     default — read-only report: what could be cleaned,
#                  with sizes; deletes nothing, prompts nothing
#   -c, --clean    enable the deletion pass (each collection still
#                  asks y/N before it is removed; logged to
#                  pi_clean.log next to the script unless --no-log)
#                  WARNING — destructive: -c DELETES files and uninstalls
#                  packages. Back up the card first (e.g. PiSafe /
#                  Raspberry Pi Imager); pi_clean is provided as-is and the
#                  authors are not responsible for data loss or damage
#   -y, --yes      answer y to every question (gate + all collections);
#                  meaningful with -c
#   -n, --dry-run  same as no flags (kept as an explicit alias)
#   --no-log       run -c without logging into pi_clean.log beside the
#                  script
#   -v, --verbose  full report: per-collection descriptions and sizes
#   -t, --total    dry run, print only reclaimable bytes (one number)
#   -V, --version  show the pi_clean version and exit
#   -h, --help     show this help and exit
#   TARGET (plain argument)  work on another system root instead of this
#                            machine — pass a directory, a /dev device, or an
#                            image file as a single plain argument:
#                   DIR  = a system root already mounted (e.g. /media/pi/rootfs)
#                   DEV  = /dev/sdX or /dev/sdXn — the rootfs partition is
#                          found, mounted rw and unmounted again on exit
#                   IMG  = an image file (plain, .img.xz, .img.zst/.zstd, or
#                          a zip of the image — compressed ones are extracted
#                          first, raw extract deleted on exit);
#                          attached as a loop device, scanned the same way,
#                          detached on exit
#                   DEV/IMG need root (for the mount) and for deleting;
#                   DIR only needs root for deleting
#
# Covers, for the running user AND (when run as root) for root:
#   thumbnail / pip / npm caches, browser caches, browser profile
#   caches, other app caches, downloaded .deb installers, trash can,
#   duplicate files. System-wide (root):
#   apt cache, apt index, orphaned dependency packages (apt autoremove),
#   journal, old kernels (incl. initrds and module trees), flatpak unused
#   runtimes, core dumps, rotated logs, stale /tmp + /var/tmp files
#   (user and root alike).
#
# At the end it reports what was cleaned, what you skipped (with the
# space that would have been freed), and what needs root.
#
# ======================================================================
# LAYOUT — a small library, plus a main() that runs it
#
#   pi_clean is organised into numbered modules, one per concern.  Each
#   module is self-contained: its functions are the module's public API
#   (documented by their signature line), and any top-level code is either
#   one-time setup (blocks 1-6) or the runbook (blocks 11-12).  Read it
#   top to bottom; jump straight to a module with:
#
#       grep -nE '#   \[[0-9]+\]' pi_clean.sh
#
#   [1]  OPTIONS & HELP         version, usage(), and command-line parsing
#   [2]  LIFECYCLE & CLEANUP    the EXIT trap that undoes mounts / loops / temps
#   [3]  LOGGING                the -c transcript capture (and refusal rules)
#   [4]  BANNER                 the first line printed, before any slow setup
#   [5]  TARGET SETUP         DIR / DEV / IMG classification and the rootfs mount
#   [6]  SESSION                quiet mode, IS_ROOT, which homes, and the ledger
#   [7]  CORE HELPERS           human · size_of · maybe_root · confirm · is_browser_cache
#   [8]  COLLECTIONS · per home  the 9 per-home sections (duplicate files included)
#   [9]  COLLECTIONS · system    apt · journal · flatpak · kernels · cores · logs · temp
#   [10] REPORTERS · duplicate   report-only: apps installed more than once
#   [11] MAIN                   the runbook: banner -> gate -> run every section
#   [12] SUMMARY & EXIT         the final tally (compact or full) and the exit code
# ======================================================================

set -u
shopt -s nullglob

# ======================================================================
#   [1] OPTIONS & HELP
#       PI_CLEAN_VER, usage(), and the command-line parse loop. Every mode
#       of pi_clean is decided right here; a plain argument names the target root (default: this machine).
# ======================================================================

usage() {
    printf 'pi_clean %s\n' "$PI_CLEAN_VER"
    printf 'pi_clean — scan a Raspberry Pi for reclaimable files\n\n'
    printf 'By default pi_clean only REPORTS — a compact summary of what could be\n'
    printf 'cleaned and how much it would free. It deletes nothing. -v shows the full\n'
    printf 'report with per-collection detail. Pass -c to enable the deletion pass;\n'
    printf 'every collection still asks y/N before it is removed. A -c run is logged\n'
    printf 'to pi_clean.log next to this script (append mode); --no-log skips that.\n'
    printf '%s\n\n' '-y answers yes to the gate and to every collection.'
    printf 'WARNING — destructive when used with -c:\n'
    printf '  pi_clean DELETES files and uninstalls packages the moment you answer y;\n'
    printf '  some of it is irreversible (emptied trash, duplicates, apt autoremove).\n'
    printf '  1) the default is a read-only report — -c is what turns deletion on;\n'
    printf '  2) back the card up FIRST (e.g. PiSafe / Raspberry Pi Imager);\n'
    printf '  3) pi_clean is provided as-is, without warranty — we are not responsible\n'
    printf '     for data loss or damage; you are responsible for what you delete.\n\n'
    printf 'Usage: pi_clean.sh [options] [TARGET]\n'
    printf '   (no arguments) compact read-only report (nothing deleted)\n'
    printf '   -v, --verbose  full report: per-collection descriptions and sizes\n'
    printf '   -c, --clean  enable the deletion pass (per-item y/N still applies)\n'
    printf '   -y, --yes    answer y to every question (gate + all collections)\n'
    printf '   -n, --dry-run  alias for the compact report (nothing deleted)\n'
    printf '   --no-log     run -c without writing pi_clean.log next to the script\n'
    printf '   -t, --total  print only reclaimable bytes (one line)\n'
    printf '   -V, --version  show the pi_clean version and exit\n'
    printf '   -h, --help   show this help and exit\n'
    printf '   TARGET (plain argument, zero or one)  work on another system\n'
    printf '                   root instead of this machine:\n'
    printf '                     DIR = already mounted (/media/pi/rootfs, ...)\n'
    printf '                   — needs root to delete\n'
    printf '                     DEV = /dev/sdX or /dev/sdXn — the rootfs\n'
    printf '                   partition is found among them, mounted rw and\n'
    printf '                   unmounted on exit; needs root for both\n'
    printf '                     IMG = an image file (plain, .xz, .zst/.zstd,\n'
    printf '                   or a zip — compressed ones are extracted first,\n'
    printf '                   raw extract deleted on exit) — attached as a\n'
    printf '                   loop device, scanned the same way, detached on\n'
    printf '                   exit; needs root for both\n\n'
    printf 'Walks the known junk spots (caches, old kernels, journal, duplicate\n'
    printf 'files, downloaded installers, ...) and offers each group with its\n'
    printf 'size and why it is safe to remove. Nothing is deleted unless you\n'
    printf 'answer y. Run with sudo to include the root-only sections.\n'
    printf 'At the end it also lists apps installed redundantly (report only).\n'
}

PI_CLEAN_VER="0.9.0"

DRY=0
QUIET=0
VERBOSE=0
TOTAL=0
CLEAN=0
YES=0
NOLOG=0
BASE=""
ORIGARGS="$*"   # captured before the option loop consumes $*

while (( $# > 0 )); do
    case $1 in
        -n|--dry-run) DRY=1 ;;
        -c|--clean)   CLEAN=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -y|--yes)     YES=1 ;;
        --no-log)     NOLOG=1 ;;
        -t|--total)   TOTAL=1 ;;
        -V|--version) printf 'pi_clean %s\n' "$PI_CLEAN_VER"; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        --base)
            # removed — the target is now a plain argument; point old
            # invocations at the new form
            printf 'pi_clean: --base is no longer an option — pass the target as a plain argument:\n' >&2
            printf '           pi_clean.sh %s\n' "${2:-TARGET}" >&2
            exit 2 ;;
        -*)
            printf 'pi_clean: unknown option: %s\n\n' "$1" >&2
            usage; exit 2 ;;
        *)
            # one plain argument = the target root to work on (dir, /dev
            # device, or image file); it is zero or one, anywhere in $@
            if [[ -n $BASE ]]; then
                printf 'pi_clean: unexpected argument: %s (target already given: %s)\n' \
                       "$1" "$BASE" >&2
                exit 2
            fi
            BASE=${1%/} ;;
    esac
    shift
done

# Default (no flags at all) = the compact read-only report: safest default
# for a destructive tool. -v opts into the full per-collection transcript
# (what bare used to show); -c is the interactive deletion pass, whose
# offerings are always on screen. Neither -v nor bare ever deletes.
if (( ! CLEAN )); then
    DRY=1
    if (( ! VERBOSE && ! TOTAL )); then
        QUIET=1
    fi
fi

# ======================================================================
#   [2] LIFECYCLE & CLEANUP
#       The BASE_* state this run may create, and base_release() — called
#       from the EXIT trap — that always tears it back down (mount, loop
#       device, temp extract), no matter how the run ends.
# ======================================================================

BASE_DEV=""   # rootfs partition pi_clean mounted while scanning the target
BASE_DISK=""  # the target device the user asked for (shown in the header)
BASE_LOOP=""  # loop device attached when the target was an image file
BASE_SRC=""   # the image file the target was given as, if any
BASE_EXTRACT=""  # temp file holding a compressed image's raw extract (deleted on exit)
BASE_MP=""    # that mount point (unmounted again on exit)
base_release() {
    if [[ -n $BASE_MP ]]; then
        umount "$BASE_MP" 2>/dev/null
        rmdir "$BASE_MP" 2>/dev/null
    fi
    if [[ -n $BASE_LOOP ]]; then
        losetup -d "$BASE_LOOP" 2>/dev/null
    fi
    if [[ -n $BASE_EXTRACT ]]; then
        rm -f -- "$BASE_EXTRACT"
    fi
}
trap base_release EXIT

# ======================================================================
#   [3] LOGGING
#       The -c transcript is captured alongside this script; the refusal
#       rules and the coproc-tee wiring are explained in the note below.
# ======================================================================
#
# The deletion pass (-c) is logged by default: a full transcript appended
# to pi_clean.log right beside this script (one "====" header per run).
# --no-log opts out. Refusing -c without a log when we cannot write one is
# deliberate: a destructive run should not go unrecorded unless asked to.
# Report-only runs (default, -t) never log.
if (( CLEAN )) && (( ! QUIET )) && (( ! TOTAL )) && (( ! NOLOG )); then
    ldir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)
    if [[ -z ${ldir:-} || ! -w ${ldir:-/nonexistent} ]]; then
        printf 'pi_clean: the log directory would be: %s (not writable?)\n' "${ldir:-?}" >&2
        printf 'pi_clean: refusing -c without a log — rerun with --no-log to allow it\n' >&2
        exit 2
    fi
    LOGF="$ldir/pi_clean.log"
    if ! printf '\n==== pi_clean %s %s (user %s) args: %s\n' \
        "$PI_CLEAN_VER" "$(date '+%Y-%m-%d %H:%M:%S')" "${SUDO_USER:-$(id -un)}" "$ORIGARGS" >> "$LOGF"; then
        printf 'pi_clean: cannot write the log file %s\n' "$LOGF" >&2
        printf 'pi_clean: refusing -c without a log — rerun with --no-log to allow it\n' >&2
        exit 2
    fi
    coproc LOGTEE { tee -a "$LOGF"; }
    exec 1>&"${LOGTEE[1]}" 2>&"${LOGTEE[1]}"
    # exit path: close the copy of tee's stdin (fd 1/2), then tee's own
    # stdin (LOGTEE[1]) so tee sees EOF, then wait for it to flush fully
    # (verified: no hang, complete output)
    trap 'base_release; exec 1>&- 2>&-; exec {LOGTEE[1]}<&- 2>/dev/null; wait "${LOGTEE_PID}" 2>/dev/null' EXIT
fi

# ======================================================================
#   [4] BANNER
#       The product title, printed immediately so a run never looks hung.
# ======================================================================
# Product title out immediately — before any target mount/scan delay, so a
# run never looks hung. Skipped only for -t (the output is a bare number).
# (For -c this lands after the logging setup above, so it is the first
# transcript line in pi_clean.log; -h prints its own first-line title.)
if (( ! TOTAL )); then
    printf 'pi_clean %s\n' "$PI_CLEAN_VER"
fi

# ======================================================================
#   [5] TARGET SETUP
#       When a target argument is given, work on that root instead of this
#       machine:
#       classify it as DIR / device / image, extract a compressed image if
#       it is one, and mount the rootfs partition. On success $BASE holds
#       the mounted root that every section below will scan.
# ======================================================================

if [[ -n $BASE ]]; then
    if [[ $BASE == /dev/* ]]; then
        # block-device mode: scan the disk's partitions for the rootfs
        [[ -b $BASE ]] || { printf 'pi_clean: target: not a block device: %s\n' "$BASE" >&2; exit 2; }
        BASE_DISK=$BASE
        DEV=$BASE
    elif [[ -f $BASE ]]; then
        # image-file mode: an .xz-compressed image is extracted first (temp
        # file, deleted on exit); then the raw image is attached to a loop
        # device (with partition scan) and scanned like a disk; losetup -d
        # again on exit
        # compressed image: detect the format (extension, then magic bytes)
        # and stream-extract to a temp file (deleted on exit); then attach
        imgf=$BASE
        comp=""
        case $BASE in
            *.xz)         comp=xz ;;
            *.zst|*.zstd) comp=zstd ;;
            *.zip)        comp=zip ;;
        esac
        if [[ -z $comp ]]; then
            magic=$(od -An -tx1 -N6 -- "$BASE" 2>/dev/null | tr -d ' \n')
            case ${magic:-} in
                fd377a585a00) comp=xz ;;
                28b52ffd*)    comp=zstd ;;
                504b0304*)   comp=zip ;;
            esac
        fi
        if [[ -n $comp ]]; then
            case $comp in
                xz)   dcmd=( xz -dc -- "$BASE" );    cmdname=xz ;;
                zstd) dcmd=( zstd -dc -- "$BASE" );  cmdname=zstd ;;
                zip)  dcmd=(); cmdname=unzip ;;
            esac
            command -v "$cmdname" >/dev/null 2>&1 || {
                printf 'pi_clean: %s looks like a %s-compressed image but %s is not installed\n' \
                       "$BASE" "$comp" "$cmdname" >&2
                exit 2; }
            if [[ $comp == zip ]]; then
                # a zip is <= 22 bytes iff it has no entries at all (EOCD
                # only) — the smallest zip containing one file is 98 bytes
                [[ $(wc -c < "$BASE") -le 22 ]] || member=$(unzip -Z1 "$BASE" 2>/dev/null | head -n1)
                [[ -n ${member:-} ]] || {
                    printf 'pi_clean: %s: no entry found in the zip\n' "$BASE" >&2
                    exit 2; }
                dcmd=( unzip -p "$BASE" "$member" )
            fi
            # decompressed size (best effort, bytes) — it only gates the RAM
            # disk choice: unknown size means the RAM disk is never used, so
            # a too-big extract can never fill the Pi's RAM
            usize=0
            if [[ $comp == zip ]]; then
                usize=$(unzip -l -- "$BASE" 2>/dev/null | awk 'END {print $1}')
                [[ $usize =~ ^[0-9]+$ ]] || usize=0
            else
                read -r u v <<<"$("$comp" -l -- "$BASE" 2>/dev/null | awk 'NF>=5 {u=$6; v=$5} END {print u, v}')"
                case $u in
                    B)   ub=1 ;;                 KB)  ub=1000 ;;
                    MB)  ub=1000000 ;;           GB)  ub=1000000000 ;;
                    TB)  ub=1000000000000 ;;
                    KiB) ub=1024 ;;              MiB) ub=1048576 ;;
                    GiB) ub=1073741824 ;;        TiB) ub=1099511627776 ;;
                    *)   ub=0 ;;
                esac
                if [[ $ub -gt 0 && ${v//,/} =~ ^[0-9.]+$ ]]; then
                    usize=$(awk -v v="${v//,}" -v ub="$ub" 'BEGIN {printf "%d", v * ub}')
                fi
            fi
            fsize=$(wc -c < "$BASE")
            # ratio upper bound (zstd on repetitive data reaches ~8000:1 real;
            # the bound just catches parse garbage — 10 MB from a 1 MB file, etc.)
            (( usize > 0 && usize < fsize * 100000 )) || usize=0

            # where to extract: a RAM disk (tmpfs) first, when the size
            # fits — it's faster and keeps the SD card out of it.  Otherwise
            # the usual temp locations (the image's own dir first)
            exdir=""
            if (( usize > 0 )); then
                need=$(( usize + usize / 10 ))     # sizes can be rounded
                best=0; bestmp=""
                while read -r _ rmp fstype _; do
                    [[ $fstype == tmpfs ]] || continue
                    [[ -d $rmp && -w $rmp ]] || continue
                    fkb=$(df -Pk "$rmp" 2>/dev/null | awk 'NR==2 {print $4}')
                    [[ $fkb =~ ^[0-9]+$ ]] || continue
                    fkb=$(( fkb * 1024 ))
                    (( fkb >= need && fkb > best )) && { best=$fkb; bestmp=$rmp; }
                done < /proc/mounts
                if [[ -n $bestmp ]]; then
                    exdir=$bestmp
                    printf 'pi_clean: extracting to RAM: %s (needs about %s)\n' \
                        "$exdir" "$(numfmt --to=iec --suffix=B -- "$usize" 2>/dev/null || printf '%s B' "$usize")" >&2
                fi
            fi
            if [[ -z $exdir ]]; then
                for c in "$(dirname -- "$BASE")" "${TMPDIR:-}" /var/tmp /tmp; do
                    [[ -n ${c:-} && -d ${c:-} && -w ${c:-} ]] && { exdir=$c; break; }
                done
            fi
            if [[ -z $exdir ]]; then
                printf 'pi_clean: no writable directory found to extract %s into\n' "$BASE" >&2
                exit 2
            fi
            BASE_EXTRACT=$(mktemp "$exdir/pi_clean.XXXXXX") || {
                printf 'pi_clean: cannot create a temp file in %s\n' "$exdir" >&2
                exit 2; }
            # extraction is the one long silent step (and it happens before
            # any of the scan output a user can wait for): say it, and say
            # it's done. stderr, so it can never pollute -t's bare number
            # or the transcript/compact stdout.
            if (( usize > 0 )); then
                printf 'pi_clean: decompressing %s (about %s raw) — this can take a while ...\n' \
                    "$BASE" "$(numfmt --to=iec --suffix=B -- "$usize" 2>/dev/null || printf '%s B' "$usize")" >&2
            else
                printf 'pi_clean: decompressing %s — this can take a while ...\n' "$BASE" >&2
            fi
            if ! "${dcmd[@]}" > "$BASE_EXTRACT" 2>/dev/null; then
                printf 'pi_clean: extracting %s failed (damaged %s archive, or not enough disk space)\n' \
                       "$BASE" "$comp" >&2
                exit 2
            fi
            printf 'pi_clean: extracted to %s\n' "$BASE_EXTRACT" >&2
            imgf=$BASE_EXTRACT
        fi
        if ! BASE_LOOP=$(losetup -fP --show "$imgf" 2>/dev/null); then
            printf 'pi_clean: cannot attach %s as a loop device\n' "$BASE" >&2
            (( EUID == 0 )) || printf 'pi_clean: (not root — try sudo)\n' >&2
            exit 2
        fi
        BASE_SRC=$BASE
        DEV=$BASE_LOOP
    elif [[ $BASE == /* ]]; then
        [[ -d $BASE ]] || { printf 'pi_clean: target: no such directory: %s\n' "$BASE" >&2; exit 2; }
        [[ -f $BASE/etc/os-release ]] || {
            printf 'pi_clean: %s does not look like a system root (no etc/os-release)\n' "$BASE" >&2
            exit 2; }
    else
        printf 'pi_clean: target needs a directory, /dev device, or an image file\n' >&2
        exit 2
    fi

    # device / image-file mode: mount $DEV's partitions one by one until the
    # rootfs (the one with /etc/os-release) is found; keep it mounted
    if [[ -n ${DEV:-} ]]; then
        # candidate partitions: real /dev nodes only (sda1, sda2 / loop0p1 /
        # nvme0n1p1) — globbing the nodes never breaks on lsblk column or
        # tree-format drift (nullglob is set)
        b=${DEV##*/}
        if [[ -n $BASE_LOOP ]]; then
            # shellcheck disable=SC2206   # want the glob: nullglob (line 30) empties non-matches
            candl=( /dev/${b}p[0-9]* "$DEV" )   # only THIS loop's partitions
        elif [[ $b == *p[0-9]* ]]; then
            # shellcheck disable=SC2206
            candl=( /dev/${b%%p[0-9]*}[0-9]* /dev/${b%%p[0-9]*}p[0-9]* )
        else
            # shellcheck disable=SC2206
            candl=( /dev/${b%%[0-9]*}[0-9]* /dev/${b}p[0-9]* )
        fi
        (( ${#candl[@]} )) || candl=( "$DEV" )
        for cand in "${candl[@]}"; do
            [[ -b $cand ]] || continue
            mp=$(mktemp -d /run/pi_clean.XXXXXX 2>/dev/null) || mp=$(mktemp -d)
            if mount -o rw "$cand" "$mp" 2>/dev/null && [[ -f $mp/etc/os-release ]]; then
                BASE=$mp; BASE_DEV=$cand; BASE_MP=$mp
                break
            fi
            umount "$mp" 2>/dev/null
            rmdir "$mp" 2>/dev/null
        done
        if [[ -z $BASE_DEV ]]; then
            printf 'pi_clean: no /etc/os-release found in %s or its partitions: %s\n' \
                   "$BASE" "${candl[*]}" >&2
            (( EUID == 0 )) || printf 'pi_clean: (not root — the mounts were probably refused; try sudo)\n' >&2
            exit 2
        fi
    fi
fi

# ======================================================================
#   [6] SESSION
#       The per-run state every section depends on: reporting mode
#       (quiet/total), whether we are root, which homes to scan, and the
#       running tally (counts and bytes) the summary reports at the end.
# ======================================================================
#
# Reporting modes (bare, -t): always a dry run, and the per-section chatter
# goes to /dev/null (fd 3 keeps the real stdout for the summary).
if (( QUIET || TOTAL )); then
    QUIET=1
    DRY=1
    exec 3>&1
    exec > /dev/null 2>&1
fi

IS_ROOT=0
(( EUID == 0 )) && IS_ROOT=1

# Who is "the user" and who is "root"? Works under plain sudo too.
USER_NAME=${SUDO_USER:-$(id -un)}
USER_HOME=$HOME
if [[ -n ${SUDO_USER:-} ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
fi
if [[ -z ${USER_HOME:-} || ! -d ${USER_HOME:-/nonexistent} ]]; then
    USER_HOME=$HOME
fi
USER_NAME=${USER_NAME:-pi}
ROOT_HOME=/root

# HOMES: the home dirs to clean, as "path|label" pairs.
#  TARGET DIR : every home inside the image (DIR/home/* plus DIR/root)
#  otherwise  : this machine's user home, plus root's when root
HOMES=()
if [[ -n $BASE ]]; then
    for d in "$BASE"/home/*/ "$BASE"/root; do
        [[ -d $d ]] || continue
        d=${d%/}
        HOMES+=( "$d|${d##*/}" )
    done
else
    HOMES+=( "$USER_HOME|$USER_NAME" )
    if (( IS_ROOT )) && [[ $ROOT_HOME != "$USER_HOME" && -d $ROOT_HOME ]]; then
        HOMES+=( "$ROOT_HOME|root" )
    fi
fi

CLEAN_COUNT=0
CLEAN_BYTES=0
DECLINE_COUNT=0
DECLINE_BYTES=0
DECLINED=()
DRY_COUNT=0
DRY_BYTES=0
DRY_LIST=()
ROOT_SKIPPED=()

# ======================================================================
#   [7] CORE HELPERS
#       The small, dependency-free primitives every section is built from:
#       human(bytes), size_of(paths...), the maybe_root guard, the confirm
#       y/N gate, and is_browser_cache(name). Think of this as the shared
#       library the collection modules below call.
# ======================================================================

human() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"
}

# size_of PATH... -> total bytes of the paths that exist (0 if none)
size_of() {
    if (( $# == 0 )); then
        echo 0
        return
    fi
    du -sb -- "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}'
}

# maybe_root TITLE -> returns 1 (and logs the skip) when not root
maybe_root() {
    if (( IS_ROOT )); then
        return 0
    fi
    printf '\n[%s] skipped — needs root (run with sudo)\n' "$1"
    ROOT_SKIPPED+=( "$1" )
    return 1
}

# confirm TITLE SIZE DESCRIPTION-LINES...
# Prints the offering and asks y/N.
# Returns: 0 = approved for deletion (never in dry-run);
#          1 = nothing to offer, dry-run, or user declined
#          (a decline is recorded as "skipped").
confirm() {
    local title="$1" size="$2" ans
    shift 2

    if (( size <= 0 )); then
        printf '\n[%s] nothing to clean\n' "$title"
        return 1
    fi

    printf '\n== %s\n' "$title"
    printf '%s\n' "$@"
    printf '   size on disk : %s\n' "$(human "$size")"

    if (( DRY )); then
        printf '   (dry run — nothing deleted)\n'
        DRY_COUNT=$(( DRY_COUNT + 1 ))
        DRY_BYTES=$(( DRY_BYTES + size ))
        DRY_LIST+=( "$title ($(human "$size"))" )
        return 1
    fi

    if (( YES )); then
        printf '   (auto-approved: -y)\n'
        ans=y
    else
        read -r -p '   delete? [y/N] ' ans
    fi
    if [[ ${ans} =~ ^[Yy]$ ]]; then
        CLEAN_COUNT=$(( CLEAN_COUNT + 1 ))
        CLEAN_BYTES=$(( CLEAN_BYTES + size ))
        return 0
    fi

    printf '   skipped.\n'
    DECLINE_COUNT=$(( DECLINE_COUNT + 1 ))
    DECLINE_BYTES=$(( DECLINE_BYTES + size ))
    DECLINED+=( "$title ($(human "$size"))" )
    return 1
}

# ======================================================================
#   [8] COLLECTIONS · per home
#       One section for each home directory (this box's user, or every home
#       in the image): thumbnail / pip / npm caches, browser caches (plain
#       and profile), other app caches, downloaded .debs, the trash — and
#       the duplicate-file scan. Each sec_* takes `$1 home, $2 label` and
#       offers or skips one collection through the confirm() gate.
# ======================================================================

is_browser_cache() {
    case $1 in
        *chrom*|*firefox*|*epiphany*|*midori*|*seamonkey*|*vivaldi*|*opera*|*librewolf*) return 0 ;;
        *) return 1 ;;
    esac
}

sec_thumbnails() { # $1 home  $2 label
    local h="$1" l="$2"
    local size; size=$(size_of "$h/.cache/thumbnails")
    if confirm "${l} image thumbnail cache" "$size" \
        "   Cached image thumbnails in ${h}/.cache/thumbnails." \
        "   Rebuilt automatically by the file manager on next browse."; then
        rm -rf -- "$h/.cache/thumbnails"
    fi
}

sec_pip() { # $1 home  $2 label
    local h="$1" l="$2"
    local size; size=$(size_of "$h/.cache/pip")
    if confirm "${l} pip download cache" "$size" \
        "   Package/wheel cache in ${h}/.cache/pip." \
        "   pip re-downloads at install time; nothing is lost."; then
        rm -rf -- "$h/.cache/pip"
    fi
}

sec_npm() { # $1 home  $2 label
    local h="$1" l="$2"
    local size; size=$(size_of "$h/.npm")
    if confirm "${l} npm cache" "$size" \
        "   npm package cache in ${h}/.npm." \
        "   npm re-verifies/re-downloads packages when needed."; then
        rm -rf -- "$h/.npm"
    fi
}

sec_browsers() { # $1 home  $2 label
    local h="$1" l="$2" b
    local -a dirs=()
    for d in "$h"/.cache/*/; do
        [[ -d $d ]] || continue
        b=${d%/}; b=${b##*/}
        if is_browser_cache "$b"; then
            dirs+=( "$h/.cache/$b" )
        fi
    done
    local moz=0
    [[ -d "$h/.mozilla" ]] && moz=1
    local -a mozdirs=()
    (( moz )) && mozdirs=( "$h"/.mozilla/*/cache2 )

    local targets=( "${dirs[@]}" "${mozdirs[@]}" )
    local size; size=$(size_of "${targets[@]}")

    local -a desc=(
        "   ${l} browser caches found:"
    )
    for d in "$h"/.cache/*/; do
        [[ -d $d ]] || continue
        b=${d%/}; b=${b##*/}
        is_browser_cache "$b" && desc+=( "     - ${h}/.cache/${b}" )
    done
    if (( moz )); then
        desc+=( "     - ${h}/.mozilla profiles (cache2 sub-dirs only —" \
                "       saved logins, history and settings are KEPT)" )
    fi
    desc+=( "   Browsers rebuild these automatically; downloads re-fetch." )

    if confirm "${l} browser caches" "$size" "${desc[@]}"; then
        rm -rf -- "${dirs[@]}"
        rm -rf -- "${mozdirs[@]}"
    fi
}

# cache/model dirs inside browser profile folders that rebuild or
# re-download themselves — safe to wipe
BROWSER_BASES=( google-chrome chromium brave-browser microsoft-edge librewolf
    waterfox floorp zen-browser vivaldi opera-gx operabrowser epiphany
    seamonkey midori qutebrowser )
SAFE_PROF_NAMES=( "Cache" "Code Cache" "GPUCache" "GPUPersistentCache"
    "ShaderCache" "GrShaderCache" "DawnCache" "DawnGraphiteCache"
    "GraphiteDawnCache" "Service Worker" "component_crx_cache"
    "WasmTtsEngine" "OnDeviceHeadSuggestModel" "optimization_guide_model_store"
    "ActorSafetyLists" "Safe Browsing" "OptimizationHints"
    "Subresource Filter" "PKIMetadata" "CertificateRevocation" "ZxcvbnData"
    "hyphen-data" "Dictionaries" "first_party_sets" "OriginTrials"
    "BrowserMetrics" "Crashpad" )

sec_browser_profiles() { # $1 home  $2 label
    local h="$1" l="$2" b base d s name sn
    local -A safe=()
    for s in "${SAFE_PROF_NAMES[@]}"; do safe[$s]=1; done

    local -a targets=()
    local -a bases=()
    local -A baseseen=()
    for b in "${BROWSER_BASES[@]}"; do
        base="$h/.config/$b"
        [[ -d $base ]] || continue
        local found=0
        for d in "$base"/*/; do
            [[ -d $d ]] || continue
            d=${d%/}
            name=${d##*/}
            if [[ -n ${safe[$name]:-} ]]; then
                targets+=( "$d" ); found=1; continue
            fi
            # second level: per-profile dirs like Default/ and Profile 1/
            for s in "$d"/*/; do
                [[ -d $s ]] || continue
                s=${s%/}
                sn=${s##*/}
                if [[ -n ${safe[$sn]:-} ]]; then
                    targets+=( "$s" ); found=1
                fi
            done
        done
        (( found )) && [[ -z ${baseseen[$base]:-} ]] && { baseseen[$base]=1; bases+=( "$b" ); }
    done

    (( ${#targets[@]} )) || { printf '\n[%s browser profile caches] nothing to clean\n' "$l"; return 1; }

    local size; size=$(size_of "${targets[@]}")
    local joined; joined=$(IFS=', '; echo "${bases[*]}")
    if confirm "${l} browser profile caches" "$size" \
        "   Auto-rebuildable caches inside ${l}'s browser profile folders" \
        "   (found in: $joined): component caches, shader caches, update" \
        "   models, blocklists, crash dumps. ${#targets[@]} directories." \
        "   History, logins, bookmarks and settings are KEPT."; then
        rm -rf -- "${targets[@]}"
    fi
}

sec_other_caches() { # $1 home  $2 label
    local h="$1" l="$2" b
    local -a names=()
    for d in "$h"/.cache/*/; do
        [[ -d $d ]] || continue
        b=${d%/}; b=${b##*/}
        case $b in
            thumbnails|pip|npm) continue ;;
        esac
        is_browser_cache "$b" && continue
        names+=( "$b" )
    done
    (( ${#names[@]} )) || { printf '\n[%s other app caches] nothing to clean\n' "$l"; return 1; }

    local -a dirlist=()
    local size=0
    for b in "${names[@]}"; do
        dirlist+=( "$h/.cache/$b" )
        local s; s=$(size_of "$h/.cache/$b"); size=$(( size + s ))
    done

    local joined; joined=$(IFS=', '; echo "${names[*]}")
    if confirm "${l} other app caches (~/.cache)" "$size" \
        "   App caches in ${h}/.cache (browsers handled separately): $joined." \
        "   Recreated as needed; worst case content is re-downloaded."; then
        rm -rf -- "${dirlist[@]}"
    fi
}

sec_trash() { # $1 home  $2 label
    local h="$1" l="$2"
    local size
    size=$(( $(size_of "$h/.local/share/Trash/files")
            + $(size_of "$h/.local/share/Trash/info") ))
    if confirm "${l} trash can" "$size" \
        "   Files in the ${l} file-manager trash: ${h}/.local/share/Trash/files" \
        "   (and its .trashinfo metadata in .../info)." \
        "   Emptying this is permanent."; then
        find "$h/.local/share/Trash/files" -mindepth 1 -delete 2>/dev/null
        find "$h/.local/share/Trash/info"  -mindepth 1 -delete 2>/dev/null
    fi
}

sec_debs() { # $1 home  $2 label
    local h="$1" l="$2" f
    local -a debs=()
    mapfile -d '' -t debs < <(find "$h" -xdev -type f -name '*.deb' -print0 2>/dev/null)
    (( ${#debs[@]} )) || { printf '\n[%s downloaded .deb installers] nothing to clean\n' "$l"; return 1; }
    local size; size=$(size_of "${debs[@]}")
    local -a names=()
    for f in "${debs[@]}"; do names+=( "${f##*/}" ); done
    local joined; joined=$(IFS=', '; echo "${names[*]}")
    if confirm "${l} downloaded .deb installers" "$size" \
        "   Installer packages left in ${l}'s home: $joined." \
        "   Safe once the software is installed — apt can re-download" \
        "   from the repo at any time."; then
        rm -f -- "${debs[@]}"
    fi
}

# ------------------------------------------------------- duplicate files
# Finds groups of identical files (>1MB, by sha256) outside caches and
# Trash. Each set is offered and approved individually: one copy kept,
# the rest deleted — one y/N prompt per set.

run_duplicates() { # $1 home  $2 label
    local h="$1" l="$2"
    local tmpd; tmpd=$(mktemp -d)
    local entry size path hsh

    printf '\n[scanning %s home for duplicate files >1MB … this can take a little while]\n' "$l"

    declare -A sizegrp=()
    local seen=0 capped=0
    while IFS= read -r -d '' entry; do
        size=${entry%%$'\t'*}
        path=${entry#*$'\t'}
        sizegrp["$size"]+=$'\n'"$path"
        seen=$(( seen + 1 ))
        (( seen >= 30000 )) && { capped=1; break; }
    done < <(find "$h" -xdev \
                \( -path "$h/.cache" -o -path "$h/.npm" \
                   -o -path "$h/.mozilla" -o -path "$h/.local/share/Trash" \) -prune \
                -o -type f -size +1M -printf '%s\t%p\0' 2>/dev/null \
         | sort -z -t "$(printf '\t')" -k1,1rn)

    # hash the size-collision groups
    declare -A hashgrp=()
    local f
    for size in "${!sizegrp[@]}"; do
        local -a members=()
        mapfile -t members <<< "${sizegrp[$size]}"
        local m=0
        for f in "${members[@]}"; do [[ -n ${f:-} ]] && m=$(( m + 1 )); done
        (( m > 1 )) || continue
        for f in "${members[@]}"; do
            [[ -n ${f:-} && -r $f ]] || continue
            hsh=$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')
            [[ ${#hsh} -eq 64 ]] || continue
            hashgrp["$hsh:$size"]+=$'\n'"$f"
        done
    done

    # write out the sets: one NUL-separated file per duplicate set
    local idx="$tmpd/index"
    : > "$idx"
    local s=0 total_waste=0 setn=0
    for key in "${!hashgrp[@]}"; do
        local -a ms=()
        mapfile -t ms <<< "${hashgrp[$key]}"
        local n=0
        for f in "${ms[@]}"; do [[ -n ${f:-} ]] && n=$(( n + 1 )); done
        (( n > 1 )) || continue
        size=${key##*:}
        local sf="$tmpd/set.$s"
        local c=0
        : > "$sf"
        for f in "${ms[@]}"; do
            [[ -n ${f:-} ]] || continue
            c=$(( c + 1 ))
            printf '%s\0' "$f" >> "$sf"
        done
        (( c > 1 )) || continue
        local w=$(( (n - 1) * size ))
        total_waste=$(( total_waste + w ))
        printf '%s\t%s\t%s\n' "$w" "$n" "$sf" >> "$idx"
        setn=$(( setn + 1 ))
        s=$(( s + 1 ))
    done

    if (( total_waste <= 0 )); then
        printf '[%s duplicate files] none found (%s candidate files scanned%s)\n' \
            "$l" "$seen" "$([ "$capped" -eq 1 ] && echo ', scan capped at 30000 files')"
        rm -rf -- "$tmpd"
        return 1
    fi

    # every set gets its own approval gate: one copy kept, the rest deleted
    local capnote=''
    (( capped )) && capnote=', scan capped at 30000 files'

    printf '\n== %s duplicate files (%d set(s), approved one at a time)\n' "$l" "$setn"
    printf '%s\n' \
        "   ${l}'s home, files >1MB, caches and trash excluded" \
        "   ($seen files scanned$capnote). $(human "$total_waste") wasted in all."

    # read the index before looping: prompts must keep reading the
    # terminal's stdin, not the index stream
    local -a idxlines=()
    mapfile -t idxlines < <(sort -t "$(printf '\t')" -k1,1rn "$idx")

    local i=0 line w sf
    for line in "${idxlines[@]}"; do
        i=$(( i + 1 ))
        IFS=$'\t' read -r w _ sf <<< "$line"

        local -a ps=()
        local p
        while IFS= read -r -d '' p; do ps+=( "$p" ); done < "$sf"
        (( ${#ps[@]} > 1 )) || continue

        local -a desc=( "   Keep    : ${ps[0]}" )
        local d
        for (( d=1; d<${#ps[@]}; d++ )); do
            desc+=( "   Delete  : ${ps[d]}" )
        done

        if confirm "${l} duplicate set ${i}/${setn}" "$w" "${desc[@]}"; then
            rm -f -- "${ps[@]:1}"
        fi
    done

    rm -rf -- "$tmpd"
    return 0
}

# ======================================================================
#   [9] COLLECTIONS · system
#       The system-wide (root) sections: the apt trio (cache, index,
#       autoremove), the systemd journal, flatpak runtimes, old kernels,
#       core dumps, rotated logs, and stale /tmp + /var/tmp files. Every
#       sec_* here is self-contained and opens with a maybe_root guard.
# ======================================================================

sec_temptmp() {            # stale /tmp + /var/tmp — shared, so it leads this block
    maybe_root "stale temp files" || return 0
    local d1="${BASE}/tmp" d2="${BASE}/var/tmp"
    local -a tmpold=()
    mapfile -d '' -t tmpold < <(find "$d1" "$d2" -xdev -type f -mtime +7 -print0 2>/dev/null)
    local size; size=$(size_of "${tmpold[@]}")
    if confirm "stale temp files (user + root, older than 7 days)" "$size" \
        "   Files in $d1 and $d2 — shared by user and root —" \
        "   not modified for 7+ days. Apps normally recreate what they need."; then
        rm -f -- "${tmpold[@]}"
    fi
}

sec_apt_cache() {
    maybe_root "apt package cache" || return 0
    local d="${BASE}/var/cache/apt/archives"
    local size; size=$(size_of "$d"/*.deb)
    if confirm "APT package cache" "$size" \
        "   .deb packages apt downloaded into $d." \
        "   Safe to delete — apt re-downloads on the next install."; then
        rm -f -- "$d"/*.deb
    fi
}

sec_apt_lists() {
    maybe_root "APT package index" || return 0
    local d="${BASE}/var/lib/apt/lists"
    local size; size=$(size_of "$d")
    if confirm "APT package index (lists)" "$size" \
        "   apt's package index cache under $d." \
        "   Safe to delete — rebuilt automatically on the next 'apt update'." \
        "   Useful on tight disks; skip it if you install packages often."; then
        rm -rf -- "${d:?}"/*
    fi
}

# Orphaned dependencies: packages apt installed on our behalf that nothing
# needs any more. The only section that *uninstalls packages* rather than
# deleting files, so both the package list and the size come from apt's own
# --simulate output (apt's accounting, shared files included).
sec_apt_autoremove() {
    maybe_root "apt autoremove" || return 0
    local -a run
    if [[ -n $BASE ]]; then
        if [[ ! -x "$BASE/usr/bin/apt-get" ]]; then
            printf '\n[apt autoremove] not applicable — no /usr/bin/apt-get in %s\n' "$BASE"
            return 0
        fi
        run=( chroot --userspec=root:root "$BASE" /usr/bin/apt-get )
    else
        run=( apt-get )
    fi

    local out pkgn
    out=$(LC_ALL=C "${run[@]}" -s autoremove 2>&1)
    pkgn=$(sed -n 's/.*\([0-9][0-9]*\) to remove.*/\1/p' <<<"$out" | head -n 1)
    if [[ -z ${pkgn:-} ]]; then
        printf '\n[apt autoremove] could not be evaluated: %s\n' \
            "$(printf '%s\n' "$out" | tail -n 1)" >&2
        return 0
    fi

    # size apt says this frees (B/kB/MB/GB line) — apt's own accounting
    local size
    size=$(awk 'BEGIN { c["B"] = 1; c["kB"] = 1024; c["MB"] = 1048576; c["GB"] = 1073741824; c["TB"] = 1099511627776 }
        { for (i = 2; i <= NF; i++) if ($i in c) { v = $(i-1); gsub(/,/, "", v); printf "%.0f", v * c[$i]; exit } }' \
        <<<"$out")
    size=${size:-0}

    # the packages apt would remove
    local -a pkgs=()
    local line inblk=0 name
    while IFS= read -r line; do
        if [[ $line == 'The following packages will be REMOVED:' ]]; then
            inblk=1; continue
        fi
        (( inblk )) || continue
        if [[ -z ${line//[[:space:]]/} ]]; then
            inblk=0; continue
        fi
        [[ $line == ' '* ]] || { inblk=0; continue; }
        read -r name _ <<< "$line"
        pkgs+=( "$name" )
    done <<< "$out"

    local -a desc=(
        "   Packages apt installed as dependencies that nothing needs anymore."
        "   apt (dry run): removes ${pkgn} package(s), this frees $(human "$size")."
        "   Uninstalls properly — dependency-safe, apt decides the exact set."
    )
    local cap=25 p
    for p in "${pkgs[@]:0:cap}"; do
        desc+=( "      - $p" )
    done
    if (( ${#pkgs[@]} > cap )); then
        desc+=( "      ... and $(( ${#pkgs[@]} - cap )) more" )
    fi

    if confirm "APT autoremove (orphaned dependencies)" "$size" "${desc[@]}"; then
        LC_ALL=C DEBIAN_FRONTEND=noninteractive "${run[@]}" -y autoremove
    fi
}

sec_journal() {
    maybe_root "systemd journal logs" || return 0
    local d="${BASE}/var/log/journal"
    # only count segments older than 7 days — vacuum won't touch newer ones
    local -a old=()
    mapfile -t old < <(find "$d" "${BASE}/run/log/journal" -name '*.journal' -type f \
               -mtime +7 2>/dev/null)
    local size; size=$(size_of "${old[@]}")
    if confirm "systemd journal (older than 7 days)" "$size" \
        "   Binary systemd logs under $d (and ${BASE}/run/log/journal)." \
        "   Size shown is the part (segments last modified 7+ days ago)" \
        "   that would actually be freed."; then
        if [[ -n $BASE ]]; then
            rm -f -- "${old[@]}"
        else
            journalctl --vacuum-time=7d
        fi
    fi
}

sec_flatpak() {
    maybe_root "flatpak runtimes" || return 0
    local fp="${BASE}/var/lib/flatpak"
    if [[ -z $BASE ]]; then
        if ! command -v flatpak >/dev/null 2>&1 || [[ ! -d $fp ]]; then
            printf '\n[flatpak runtimes] flatpak is not installed\n'
            return 1
        fi
        local size; size=$(size_of "$fp/runtime" "$fp/sdk")
        if confirm "flatpak unused runtimes / SDKs" "$size" \
            "   Runtimes and SDKs under $fp that no installed" \
            "   flatpak app references (leftovers, e.g. from image builds)." \
            "   'flatpak uninstall --unused' removes only the unused ones; apps" \
            "   and user settings are untouched. Could free up to $(human "$size")."; then
            flatpak uninstall --unused
        fi
        return 0
    fi

    # image mode: file-based 'flatpak uninstall --unused'
    # dependency edges of an app: its runtime= and sdk= refs, plus the
    # extensions their extensions.yaml files declare (flatpak keeps all of
    # these next to the app)
    local -a keep=() extra=() old=()
    local f r e y d kind ref
    # 1) runtimes/SDKs named in installed apps' metadata
    for f in "$fp"/app/*/*/*/*/metadata; do
        [[ -f $f ]] || continue
        while IFS= read -r r; do
            [[ -n $r ]] && keep+=( "$r" )
        done < <(grep -E '^[Rr]untime=|^[Ss]dk=' -- "$f" 2>/dev/null | cut -d= -f2-)
    done
    # 2) extensions those kept refs declare (extensions.yaml top-level keys)
    for r in "${keep[@]}"; do
        [[ -n $r ]] || continue
        for kind in runtime sdk; do
            y="$fp/$kind/$r/extensions.yaml"
            [[ -f $y ]] || continue
            while IFS= read -r e; do
                [[ -n $e ]] && extra+=( "$e" )
            done < <(grep -oE '^[A-Za-z0-9][A-Za-z0-9._-]+' -- "$y" 2>/dev/null)
        done
    done
    local -a kept=("${keep[@]}")
    (( ${#extra[@]} )) && kept+=( "${extra[@]}" )

    kept_ref() { # $1 ref, rest keep-list; 0 when referenced (exact or parent)
        local ref=$1 k
        shift
        for k in "$@"; do
            [[ $ref == "$k" || $ref == "$k"/* ]] && return 0
        done
        return 1
    }

    local totaln=0 oldn=0
    for kind in runtime sdk; do
        for d in "$fp"/$kind/*/*/*/*/; do
            [[ -d $d ]] || continue
            d=${d%/}
            ref=${d#"$fp"/"$kind"/}   # ref path for the keep-set check
            totaln=$(( totaln + 1 ))
            if (( ${#kept[@]} == 0 )) || ! kept_ref "$ref" "${kept[@]}"; then
                old+=( "$d" )          # full path, for sizing and rm
                oldn=$(( oldn + 1 ))
            fi
        done
    done

    local size; size=$(size_of "${old[@]}")
    if confirm "flatpak unused runtimes / SDKs" "$size" \
        "   $oldn of $totaln flatpak runtimes/SDKs under $fp are not" \
        "   referenced by any installed flatpak app (leftovers, e.g. from an" \
        "   image build). Apps and user settings are untouched."; then
        rm -rf -- "${old[@]}"
    fi
}

sec_kernels() {
    maybe_root "old kernel artifacts" || return 0
    local rel ver
    if [[ -n $BASE ]]; then
        # no uname there: keep the version with the NEWEST artifact in /boot
        # (an image keeps what it will boot)
        local newest
        newest=$(find "${BASE}/boot" -maxdepth 1 -type f \
                \( -name 'System.map-*' -o -name 'config-*' -o \
                   -name 'vmlinux-*' -o -name 'initrd.img-*' \) \
                -printf '%T@\t%f\n' 2>/dev/null | LC_ALL=C sort -rn | head -n1 | cut -f2)
        if [[ -z $newest ]]; then
            printf '\n[old kernel artifacts] no versioned kernel artifacts in %s/boot\n' "$BASE"
            return 1
        fi
        case $newest in
            System.map-*) rel=${newest#System.map-} ;;
            config-*)     rel=${newest#config-} ;;
            vmlinux-*)    rel=${newest#vmlinux-} ;;
            initrd.img-*) rel=${newest#initrd.img-} ;;
            *)            return 1 ;;
        esac
    else
        rel=$(uname -r)
    fi
    # version part = before the first "+" (Pi flavors), else before the
    # first "-" (Debian style like 6.12.15-amd64); a bare version
    if [[ $rel == *+* ]]; then ver=${rel%%+*}
    else ver=${rel%%-*}; fi

    # keep anything of that exact version (incl. other-board variants,
    # e.g. 6.18.50+rpt-rpi-v8 and ...2712 for the same version). Strict
    # version equality, so 6.12.15 running must NOT hold back 6.12.150.
    is_current() {
        local v=$1
        [[ $v == *+* ]] && v=${v%%+*} || v=${v%%-*}
        [[ $v == "$ver" ]]
    }

    local -a old=()
    local f art v
    local boot="${BASE}/boot"
    for art in System.map config vmlinux initrd.img; do
        for f in "$boot/$art"-*; do
            [[ -e $f ]] || continue
            v=${f##*/"$art"-}
            is_current "$v" || old+=( "$f" )
        done
    done
    local modbase="${BASE}/lib/modules"
    [[ -d $modbase ]] || modbase="${BASE}/usr/lib/modules"
    for v in "$modbase"/*/; do
        [[ -d $v ]] || continue
        v=${v%/}; v=${v##*/}
        is_current "$v" || old+=( "$modbase/$v" )
    done

    local size; size=$(size_of "${old[@]}")
    local keepnote
    if [[ -n $BASE ]]; then
        keepnote="is the newest version in the image (i.e. the one it will boot) and"
    else
        keepnote="is the running one and"
    fi
    if confirm "old kernel artifacts" "$size" \
        "   Leftovers from kernel updates: $boot System.map / config / vmlinux" \
        "   / initrd.img, plus module trees in $modbase, for versions other" \
        "   than $ver, which $keepnote its board-variant" \
        "   artifacts are all kept." \
        "   Safe once the box happily reboots with that kernel."; then
        rm -rf -- "${old[@]}"
    fi
}

sec_cores() {
    maybe_root "core dumps" || return 0
    local c1="${BASE}/var/lib/systemd/coredump" c2="${BASE}/var/crash"
    local size; size=$(size_of "$c1" "$c2")
    if confirm "crash / core dumps" "$size" \
        "   Stack captures from crashed programs ($c1, $c2)." \
        "   Only useful while actively debugging a crash." \
        "   Deleting them is safe for normal use."; then
        rm -f -- "$c1"/*.journal* "$c2"/*
    fi
}

sec_rotlog() {
    maybe_root "rotated log files" || return 0
    local d="${BASE}/var/log"
    local -a logs=()
    mapfile -d '' -t logs < <(find "$d" -xdev -maxdepth 3 -type f \
        \( -name '*.gz' -o -name '*.1' -o -name '*.old' -o -name '*.old.*' \) \
        -print0 2>/dev/null)
    local size; size=$(size_of "${logs[@]}")
    if confirm "rotated log files" "$size" \
        "   Old copies of log files ($d entries named *.gz, *.1," \
        "   *.old) left behind by log rotation. The active logs stay." \
        "   Safe unless you still need those historical logs."; then
        rm -f -- "${logs[@]}"
    fi
}

# ======================================================================
#   [10] REPORTERS · duplicate apps
# ======================================================================
# Report ONLY (shown at the end of the run): apps that provide the same
# function, installed more than once (e.g. a KDE desktop layered over a
# base image). pi_clean never uninstalls apps — this just tells the user
# what could be pruned by hand.

DUPAPP_CATS=(
"browsers|chromium|google-chrome-stable|firefox|firefox-esr|brave-browser|microsoft-edge-stable|librewolf|vivaldi|waterfox|floorp|zen-browser|epiphany-browser|midori|seamonkey|qutebrowser|flatpak:org.mozilla.firefox|flatpak:org.chromium.Chromium"
"archive managers|ark|file-roller|peazip|7zip|p7zip-full|flatpak:io.github.peazip.PeaZip"
"media players|vlc|totem|celluloid|smplayer|flatpak:org.videolan.VLC"
"pdf viewers|evince|okular"
"image viewers|eog|gpicview|nomacs"
"office suites|libreoffice-core|onlyoffice|calligra-suite"
)

declare -A DPKG_INST=()
DUPDB_LOADED=0
# with a TARGET rootfs: parse the image's dpkg status once -> DPKG_INST[pkg]=Installed-Size(KiB)
load_dup_db() {
    (( DUPDB_LOADED )) && return 0
    DUPDB_LOADED=1
    local st="${BASE}/var/lib/dpkg/status"
    [[ -r $st ]] || return 0
    local pkg kb
    while read -r pkg kb; do
        [[ -n ${pkg:-} ]] && DPKG_INST["$pkg"]=${kb:-0}
    done < <(awk '
        /^Package:/          { p = $2 }
        /install ok installed/                       { inst = 1 }
        /Status:/ && !/install ok installed/         { inst = 0 }
        /^Installed-Size:/   { kb = $2 + 0 }
        /^[[:space:]]*$/     { if (inst && p != "") print p, kb; p = ""; inst = 0; kb = 0 }
        END                  { if (inst && p != "") print p, kb }
    ' "$st" 2>/dev/null)
}

dpkg_installed() { # dpkg package -> 0 when installed
    if [[ -n $BASE ]]; then
        load_dup_db
        [[ -n ${DPKG_INST[$1]:-} ]]
        return
    fi
    dpkg-query -Wf '%{Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

dpkg_size() { # dpkg package -> human size (Installed-Size, KiB) or ?
    if [[ -n $BASE ]]; then
        load_dup_db
        local kb=${DPKG_INST[$1]:-}
        if [[ -n $kb ]]; then human $(( kb * 1024 )); else printf '?'; fi
        return
    fi
    local kb
    kb=$(dpkg-query -Wf '${Installed-Size}' "$1" 2>/dev/null)
    if [[ ${kb:-0} =~ ^[0-9]+$ ]]; then human $(( kb * 1024 )); else printf '?'; fi
}

fp_installed() { # flatpak app id -> 0 when installed
    if [[ -n $BASE ]]; then
        [[ -d "${BASE}/var/lib/flatpak/app/$1" ]]
        return
    fi
    command -v flatpak >/dev/null 2>&1 || return 1
    flatpak list --app --show-columns=application 2>/dev/null | grep -qx -- "$1"
}

fp_size() { # flatpak app id -> human size (best effort) or ?
    local kb c
    local -a cands
    if [[ -n $BASE ]]; then
        cands=( "${BASE}/var/lib/flatpak/app/$1" )
        local h
        for h in "${BASE}"/home/*; do
            cands+=( "$h/.local/share/flatpak/app/$1" )
        done
    else
        cands=( "/var/lib/flatpak/app/$1" "${HOME}/.local/share/flatpak/app/$1" )
    fi
    for c in "${cands[@]}"; do
        kb=$(du -sk -- "$c" 2>/dev/null | awk '{print $1}')
        [[ ${kb:-} =~ ^[0-9]+$ ]] && { human $(( kb * 1024 )); return 0; }
    done
    printf '?'
}

dup_apps_report() {
    printf '\n== duplicate apps (same function installed more than once)\n'
    local cat label entry n id joined any=0
    local -a pkgs shown
    for cat in "${DUPAPP_CATS[@]}"; do
        label=${cat%%|*}
        entry=${cat#*|}
        IFS='|' read -r -a pkgs <<< "$entry"
        shown=()
        for n in "${pkgs[@]}"; do
            case $n in
                flatpak:*)
                    id=${n#flatpak:}
                    if fp_installed "$id"; then shown+=( "$id ($(fp_size "$id"))" ); fi ;;
                *)
                    if dpkg_installed "$n"; then shown+=( "$n ($(dpkg_size "$n"))" ); fi ;;
            esac
        done
        if (( ${#shown[@]} >= 2 )); then
            any=1
            joined=$(IFS=', '; printf '%s, ' "${shown[@]}")
            printf '   %-16s: %s\n' "$label" "${joined%, }"
        fi
    done
    (( any )) || printf '   none found — no category has more than one app installed\n'
    printf '   (report only — pi_clean does not uninstall apps)\n'
}

# ======================================================================
#   [11] MAIN — the runbook
#       The one pass that actually runs: print the banner and what is being
#       inspected, take the interactive gate (skipped in report mode or with
#       -y), then run every collection in its offered order.
# ======================================================================

printf 'pi_clean — scanning for reclaimable files\n'
if [[ -n $BASE ]]; then
    if [[ -n $BASE_SRC ]]; then
        printf 'image root : %s  (rootfs %s of %s — image %s)\n' \
            "$BASE" "${BASE_DEV##*/}" "${BASE_LOOP##*/}" "$BASE_SRC"
    elif [[ -n $BASE_DEV ]]; then
        printf 'image root : %s  (rootfs %s of %s)\n' "$BASE" "${BASE_DEV##*/}" "$BASE_DISK"
    else
        printf 'image root : %s\n' "$BASE"
    fi
    if (( ${#HOMES[@]} )); then
        homsl=$(for it in "${HOMES[@]}"; do printf '%s ' "${it##*|}"; done)
        printf 'homes      : %s\n' "${homsl% }"
    else
        printf 'homes      : (none found in the image)\n'
    fi
else
    printf 'user home: %s   root home: %s (root sections %s)\n' \
        "$USER_HOME" "$ROOT_HOME" "$([ "$IS_ROOT" -eq 1 ] && echo 'included' || echo 'need sudo')"
fi
printf '==================================================================\n'
printf '%s\n' \
    'What this does: walks the known junk spots (caches, downloaded installers,' \
    '   old kernels, journal, duplicate files) one group at a time. Each group is' \
    '   offered with its size and why it is safe to delete; y removes it, N/Enter' \
    '   keeps it. Nothing is touched unless you answer y, and data, history,' \
    '   logins and settings are never offered.'
if (( DRY )); then
    printf '(dry run — nothing will be deleted'
    (( CLEAN )) || printf '; add -c to the command to enable the deletion pass'
    printf ')\n'
fi

# Destructive-pass warning: the last full stop before any y. Printed to stdout so
# it is captured in the -c transcript. Only the real deletion set gets it (report
# mode, -n, and -t are deliberately left free of it).
if (( CLEAN )) && (( ! DRY )); then
    printf '%s\n' \
        '==================================================================' \
        'WARNING — this pass is DESTRUCTIVE' \
        '' \
        '  * pi_clean DELETES files and uninstalls packages the moment you answer y.' \
        '    Some of it is irreversible: emptied trash, deleted duplicate files,' \
        '    and apt autoremove removes whole packages (not just files).' \
        '  * Make a backup / image FIRST (e.g. PiSafe or Raspberry Pi Imager).' \
        '    Anything not backed up may not come back.' \
        '  * pi_clean is provided as-is, without warranty of any kind. The authors' \
        '    are NOT responsible for data loss or damage; you are responsible for' \
        '    everything you delete.' \
        '=================================================================='
fi

if (( QUIET || DRY )); then
    :   # reporting mode or dry run: skip the interactive gate
elif (( YES )); then
    printf '\n(continuing: -y answers yes to this and every collection)\n'
else
    printf '\ncontinue? [y/N] '
    read -r ans || ans=n
    if ! [[ ${ans:-} =~ ^[Yy]$ ]]; then
        printf '\naborted — nothing was touched\n'
        exit 0
    fi
fi

# system sections (user+root shared)
sec_temptmp
sec_rotlog
sec_kernels
sec_cores
sec_apt_lists
sec_apt_cache
sec_apt_autoremove
sec_journal
sec_flatpak

# per-home sections (this machine's homes, or every home in the image)
for item in "${HOMES[@]}"; do
    h=${item%|*}
    l=${item##*|}
    sec_thumbnails        "$h" "$l"
    sec_pip               "$h" "$l"
    sec_npm               "$h" "$l"
    sec_browsers          "$h" "$l"
    sec_browser_profiles  "$h" "$l"
    sec_other_caches      "$h" "$l"
    sec_debs              "$h" "$l"
    sec_trash             "$h" "$l"
    run_duplicates        "$h" "$l"
done

# ======================================================================
#   [12] SUMMARY & EXIT
#       The final tally. In compact reporting (or -t) print the machine
#       output to the preserved fd and exit; otherwise the full
#       cleaned/skipped breakdown, the root-only reminder, and the
#       report-only duplicate-apps list.
# ======================================================================

if (( QUIET )); then
    # machine output on the preserved fd (stdout was redirected at the top)
    if (( TOTAL )); then
        printf '%s\n' "$DRY_BYTES" >&3
    else
        # what we are acting on, so the summary never floats unmoored
        if [[ -n $BASE ]]; then
            if [[ -n $BASE_SRC ]]; then
                printf 'image root : %s  (rootfs %s of %s — image %s)\n' \
                    "$BASE" "${BASE_DEV##*/}" "${BASE_LOOP##*/}" "$BASE_SRC" >&3
            elif [[ -n $BASE_DEV ]]; then
                printf 'image root : %s  (rootfs %s of %s)\n' \
                    "$BASE" "${BASE_DEV##*/}" "$BASE_DISK" >&3
            else
                printf 'image root : %s\n' "$BASE" >&3
            fi
        else
            printf 'machine    : this box (root sections %s)\n' \
                "$([[ $IS_ROOT -eq 1 ]] && echo included || echo 'need sudo')" >&3
        fi
        if (( ${#HOMES[@]} )); then
            homsl=$(for it in "${HOMES[@]}"; do printf '%s ' "${it##*|}"; done)
            printf 'homes      : %s\n' "${homsl% }" >&3
        fi
        if (( DRY )); then
            printf 'report only — nothing will be deleted (add -c for the deletion pass)\n' >&3
        else
            printf 'cleaning — each collection asks y/N before it is removed\n' >&3
        fi
        printf 'could free %s across %d collection(s)\n' \
            "$(human "$DRY_BYTES")" "$DRY_COUNT" >&3
        if (( DRY_COUNT )); then
            printf '   - %s\n' "${DRY_LIST[@]}" >&3
        fi
        if (( ${#ROOT_SKIPPED[@]} )); then
            printf 'root-only (run with sudo to offer these):\n' >&3
            printf '   - %s\n' "${ROOT_SKIPPED[@]}" >&3
        fi
    fi
    exit 0
fi

printf '\n==================================================================\n'
if (( DRY )); then
    printf '(dry run — nothing was deleted)\n'
    printf 'collections offered : %d\n' "$DRY_COUNT"
    printf 'approx. could free  : %s\n' "$(human "$DRY_BYTES")"
    if (( DRY_COUNT )); then
        printf '   - %s\n' "${DRY_LIST[@]}"
    fi
    printf '(same as answering n to everything: all of it stays, and that is what you could have saved)\n'
else
    printf 'CLEANED:    %d collection(s), approx. %s\n' "$CLEAN_COUNT" "$(human "$CLEAN_BYTES")"
    if (( DECLINE_COUNT )); then
        printf 'SKIPPED:    %d collection(s), approx. %s of possible cleanup\n' \
            "$DECLINE_COUNT" "$(human "$DECLINE_BYTES")"
        printf '   - %s\n' "${DECLINED[@]}"
        printf 'potential total: cleaned + skipped = %s across %d collection(s)\n' \
            "$(human $(( CLEAN_BYTES + DECLINE_BYTES )))" \
            "$(( CLEAN_COUNT + DECLINE_COUNT ))"
    else
        printf 'SKIPPED:    none\n'
    fi
fi
if (( ${#ROOT_SKIPPED[@]} )); then
    printf 'ROOT-ONLY (run with sudo to offer these):\n'
    printf '   - %s\n' "${ROOT_SKIPPED[@]}"
fi

# report-only: duplicate apps (same function installed more than once)
dup_apps_report
exit 0
