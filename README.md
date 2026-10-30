# pi_clean — reclaim space on a Raspberry Pi (and any Linux box)

A single-file bash junk-cleaning tool for Raspberry Pi / general-Linux boxes.
*pi_clean* scans a box for reclaimable files and removes them **one collection
at a time**, each shown with a description and its size, with an explicit `y/N`
prompt before anything is deleted.

- 🍓 Made for the Raspberry Pi, works on most Linux distros
- 🐧 Plain Bash, no dependencies to install
- 🔒 **Report-only by default** — it deletes nothing unless you pass `-c` and
  answer `y`; even a `-c` run still asks per collection
- 🧾 A `-c` run is recorded in `pi_clean.log` next to the script (refuses a
  destructive run with no log unless `--no-log` is given)
- 📦 Works on **this machine, a mounted root, or an image / SD card** without booting it

## ⚠️ Read this before you run — it is destructive

pi_clean, when run with `-c`, **deletes files and uninstalls packages**. Every
collection still asks `y/N`, but the moment you answer `y` the deletion happens — and
some of it is **irreversible**:

- **emptying the trash** is permanent;
- **deleting duplicate files** removes the extra copies for good;
- **`apt autoremove`** removes whole packages, not just files;
- **old kernel artifacts, flatpak runtimes, core dumps** are gone once approved.

**Do this before the `-c` pass:**

1. The default (no flags) is a **read-only report** — it deletes nothing. `-c` is what
   turns deletion on; `-c -y` then answers yes to everything at once.
2. **Back up the card first** (e.g. **PiSafe** or **Raspberry Pi Imager**, or any
   image/snapshot tool you trust). Anything you have not backed up may not come back.

### Disclaimer

pi_clean is provided **"as is", without warranty of any kind**, express or implied.
Use it at your own risk. **The authors and maintainers are not responsible for data
loss or damage** of any kind. You are responsible for the files, packages, and systems
you point it at, and for every deletion you approve.

## Layout

| Path | Purpose |
|---|---|
| `pi_clean.sh` | The entire product (~1,565 lines). 12 numbered module banners — jump: `grep -nE '#   \[[0-9]+\]' pi_clean.sh` |
| `testing/` | 11 suites, `shim_apt/` (fake chroot/apt-get), `make_base_fix.sh` (fixture builder) |
| `LICENSE` | GNU GPL v3 |

## How it behaves

pi_clean walks the well-known junk spots and offers each group with its size and why
it is safe to remove. Nothing is deleted unless you answer `y`.

- **Default (no flags):** a compact read-only report — what could be cleaned and how
  much it would free. Deletes nothing.
- **`-v` / `--verbose`:** the full report with per-collection descriptions and sizes.
- **`-c` / `--clean`:** enables the deletion pass. Every collection **still asks
  `y/N`** before it is removed, and the run is appended to `pi_clean.log`.
- **`-y` / `--yes`:** answer `y` to the gate and to every collection (used with `-c`).
- **`-n` / `--dry-run`:** alias for the compact read-only report (nothing deleted).
- **`--no-log`:** run `-c` without writing `pi_clean.log`.
- **`-m` / `--maxramdrive`:** allow pi_clean to mount its **own** RAM disk
  when extracting a compressed image and no existing RAM disk is big enough:
  pi_clean sizes it to what the image needs plus a small buffer, and only
  when the system has that much RAM to spare (`MemAvailable`) — otherwise it
  says so and uses the disk. The mount lives for this run only and is gone on
  exit. Needs root. The old size-argument form (`-m 9G`) is refused with a
  migration hint.
- **`-t` / `--total`:** print only the reclaimable bytes — one bare number.
- **`-V` / `--version`, `-h` / `--help`:** show the version / this help.

Run with `sudo` to include the root-only (system) sections; without it, those are
reported as *skipped — needs root* rather than erroring.

## What it cleans

**Per home directory** (the running user, plus `/root` when run as root):

| Collection | Notes |
|---|---|
| Thumbnail cache | `~/.cache/thumbnails` — rebuilt by the file manager |
| `pip` download cache | `~/.cache/pip` — re-downloaded at install |
| `npm` cache | `~/.npm` — re-verified / re-downloaded when needed |
| Browser caches | plain and per-profile cache dirs; history, logins, bookmarks and settings are **kept** |
| Other app caches | the rest of `~/.cache` |
| Trash can | the file-manager trash (permanent) |
| Downloaded `.deb` installers | apt can re-download from the repo |
| Duplicate files | identical files `>1MB` (by SHA-256), caches/trash excluded — one copy kept, offered set-by-set |

**System-wide (root):**

| Collection | Notes |
|---|---|
| `apt` cache / index / autoremove | `.deb` downloads, the lists, and orphaned dependencies (uninstalls properly) |
| systemd journal | segments older than 7 days |
| flatpak unused runtimes / SDKs | `flatpak uninstall --unused` (or file-based in image mode) |
| Old kernel artifacts | `System.map` / `config` / `vmlinux` / `initrd` + module trees for non-current versions |
| Core / crash dumps | `systemd/coredump`, `/var/crash` |
| Rotated log files | `*.gz`, `*.1`, `*.old` in `/var/log` |
| Stale temp files | unmodified 7+ days in `/tmp` and `/var/tmp` |

**Report only (never removes):** at the end it also lists apps installed redundantly
(e.g. two browsers, two archive managers) so you can prune them by hand. pi_clean never
uninstalls applications — that listing is informational.

## Usage

```bash
pi_clean.sh                     compact read-only report (this box)
pi_clean.sh -v                  full report with per-collection detail
pi_clean.sh -c                  deletion pass (per-item y/N still applies)
sudo pi_clean.sh -c             include the root-only (system) sections
pi_clean.sh -c -y               clean, auto-answering yes to everything
sudo pi_clean.sh -t             print one bare number: reclaimable bytes
pi_clean.sh /media/pi/rootfs    a directory target (already mounted)
pi_clean.sh /dev/sda            a block device — rootfs partition found, mounted rw, umounted on exit
pi_clean.sh image.img.xz        an image — plain/.xz/.zstd/zip; compressed extracted first,
                                attached as a loop device, detached on exit
pi_clean.sh -V                  show the version and exit
pi_clean.sh -h                  show the help
```

Target is a plain positional argument — zero or one, order-free with flags.

### Working on another system (DIR / DEV / IMG)

Pass a single plain argument to scan a different root instead of this machine:

- **`DIR`** — an already-mounted system root (e.g. `/media/pi/rootfs`). Needs root only to delete.
- **`DEV`** — a `/dev/sdX` / `/dev/sdXn` device. The rootfs partition is found, mounted
  read-write, and unmounted again on exit. Needs root.
- **`IMG`** — an image file: plain, `.img.xz`, `.img.zst`/`.zstd`, or a zip of the image
  (compressed ones are extracted first; the extract is cleaned up on exit). Attached as a
  loop device, scanned, and detached on exit. Needs root.

### Install to PATH (optional)

pi_clean is a single self-contained script. To invoke it as `pi_clean`:

```bash
sudo cp pi_clean.sh /usr/local/bin/pi_clean && sudo chmod +x /usr/local/bin/pi_clean
```

## Logging

A `-c` run appends a full transcript to `pi_clean.log` in the same directory as the
script (one `==== pi_clean <version> <timestamp> (user ...) args: ...` header per run).
The logging is deliberate: a destructive pass is not allowed to go unrecorded unless
you opt out with `--no-log`. Report-only runs (default, `-t`) never log.

## Development

The program is a small library plus a `main()` that runs it, organised into 12
numbered modules — self-contained, documented by signature, easy to jump to:

```bash
grep -nE '#   \[[0-9]+\]' pi_clean.sh
#   [1] OPTIONS & HELP   [2] LIFECYCLE   [3] LOGGING   [4] BANNER
#   [5] TARGET SETUP     [6] SESSION    [7] CORE HELPERS
#   [8] COLLECTIONS·home [9] COLLECTIONS·system [10] REPORTERS
#   [11] MAIN            [12] SUMMARY & EXIT
```

The version string is `PI_CLEAN_VER` near the top of `pi_clean.sh` (currently
**0.9.1**). It's a single-file script with no build step.

## Testing (agent-safe)

```
cd testing && for s in test_imgcomp.sh test_imgxz.sh test_maxram.sh \
    test_loopmode.sh test_devmode.sh test_base_sections.sh test_kernels.sh \
    test_dupapps.sh live_regression.sh test_apt_autoremove.sh test_cli_flags.sh; \
do bash "$s"; done
```

* Scratch lives in `/tmp/pi_clean_test`; the shared rootfs fixture
  (`base_fix/`) is **auto-built** by `make_base_fix.sh` when missing.
* Suites are location-independent: `pi_clean.sh` is resolved relative to
  the suite's own directory; the apt suites need passwordless `sudo`.
* `test_maxram.sh` also needs passwordless `sudo`: inside `unshare -m`
  each inherited tmpfs is overlaid with a fresh small one (never a remount —
  that would reconfigure the superblock *shared with the host*), so the
  existing disks cannot hold the fixture.  Three phases: `nom` (no `-m` →
  disk, no RAM note at all); `notafford` (`-m` but the image needs more than
  `MemAvailable` can spare → refusal message, then disk); `own` (`-m` and
  affordable → a real own tmpfs mount, whose `size=` option the suite samples
  from `/proc/mounts` mid-run and asserts is ≈ need + 8 MiB).  After each
  phase it asserts the host's tmpfs sizes are exactly as before.  Scratch +
  shim live on real disk (`/var/tmp/pi_clean_test_maxram*`) because `/tmp`
  is one of the points the namespace overlays.
* **Extract-then-source harnesses** key their `awk` anchors on the
  `[11] MAIN` banner (and `DUPAPP_CATS=(` for dupapps) — re-anchor there if
  module structure ever changes, not on dividers.
* Assertions on exact totals: apt fixture `-t` = **5774336** bytes;
  xz/zst fixtures = **2097162**; live box `-t` = whatever this box holds
  (~475 MB class on the reference Pi).

## Project state (for maintainers — do not "improve" these)

### Steady state

* **shellcheck** = only 3 documented-correct families: SC2317 (trap callee
  `base_release`), SC1083 (`{LOGTEE[1]}` in the trap), SC2231 (flatpak glob).
* The `-c` log path is a coproc `tee -a`; the EXIT-trap close sequence is
  order-fragile on bash 5.2 — **do not reorder or "clean up" it**.
* `is_browser_cache()`: the `*chrom*` case subsumes chrome/chromium —
  don't re-add a `*chrome*` pattern.
* `bash -n` before and after any edit; `/tmp` leak delta must stay 0
  (8G tmpfs, a filled scratch dir = false failures).
* **Never remount an inherited tmpfs inside a test namespace**: a remount
  reconfigures the *superblock*, which is shared with the host, so the size
  change leaks out of `unshare -m` (this actually shipped in a draft and
  shrank the box's `/tmp` and `/dev/shm`).  Overlay a fresh small tmpfs over
  the same point instead, and assert the host's sizes after the phase
  (`hostok` in `test_maxram.sh` is that guard).

### Decisions locked (as of 2026-10-30)

* **Name is `pi_clean` for now** (`linux_clean` was considered and set
  aside); nothing Pi-specific is required of the box.
* `-v` = verbose, `-V`/`--version` = version (`pi_clean 0.9.1`).
* `--base` was **removed** 2026-10-29 in favor of the positional target.
  A one-time **migration hint** still recognizes `--base` (prints the new
  form, exits 2) — drop it in a later release if it has served its cycle.
* Report mode prints the title line **first**, before any mount/scan delay;
  extraction of compressed images announces start + done **on stderr only**.
* Honest sizes; everything deletable sits behind a `y/N` gate.
* **`-m` / `--maxramdrive` (0.9.1) is an opt-in flag — it takes no size
  argument**: the default stays locked — existing RAM disks first (set at
  boot, typically 50% of RAM), then the disk.  The flag only *permits*
  pi_clean to mount its own private tmpfs for a compressed-image extract when
  none of the existing ones fit; pi_clean sizes it itself (what the image
  needs + a small buffer) and only acts when `MemAvailable` can spare that
  much — otherwise it says so and uses the disk.  The mount is gone on exit.
  The old sized form (`-m 9G`) is refused with a one-time migration hint (the
  `--base` precedent).
* **Destructive / back-up / not-responsible warnings** (added before the first push):
  full "Read this before you run" + Disclaimer section in this README; a `WARNING`
  block in the `-h` help; a destructive banner in the `-c` runbook's pre-gate banner;
  and a note in the `pi_clean.sh` header. `bash -n` clean; shellcheck steady-state kept.

### Open / user's calls

* `pi_clean_log.txt` (beside this file) — a captured real run from an
  earlier version, moved into the folder by an outside client; on disk,
  gitignored. **Resolved 2026-10-29: deleted** (user chose "Delete").
* Real-box verification still owed by the user: `sudo -c` on a real rootfs,
  `-c -y`, a real `apt autoremove` run, and an unwritable-log refusal.
* Live `-m` check on the real 7.9 GB Armbian image — **done 2026-10-30**
  (new flag API):
  `sudo bash pi_clean.sh -m /home/pi/Downloads/Armbian_26.8.1_Rpi4b_resolute_current_6.18.42_kde-plasma_desktop.img.xz`
  announced "extracting to RAM (own mount, sized to ~8.7GB): …
  (needs about 7.9GB; system had ~13GB to spare)"; a 2 s sampler showed
  MemAvailable dip from ~12.8 GiB to ~6.0 GiB at peak (the ~7.9 GiB extract
  in RAM) and back after exit. Full clean report, no residue
  (no mounts, no temp files, no loop devices), box left as found.
* Optional, declined twice so far: split `[5] TARGET SETUP` into named
  helpers — ask before doing it.
* **No remote is configured and nothing has been pushed; local `main` is
  the only branch.** Pushing/tagging a remote is a separate explicit call.

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
