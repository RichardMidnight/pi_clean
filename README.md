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

## Layout

| Path | Purpose |
|---|---|
| `pi_clean.sh` | The entire product (~1,470 lines). 12 numbered module banners — jump: `grep -nE '#   \[[0-9]+\]' pi_clean.sh` |
| `testing/` | 10 suites, `shim_apt/` (fake chroot/apt-get), `make_base_fix.sh` (fixture builder) |
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
**0.9.0**). It's a single-file script with no build step.

## Testing (agent-safe)

```
cd testing && for s in test_imgcomp.sh test_imgxz.sh test_loopmode.sh \
    test_devmode.sh test_base_sections.sh test_kernels.sh test_dupapps.sh \
    live_regression.sh test_apt_autoremove.sh test_cli_flags.sh; do bash "$s"; done
```

* Scratch lives in `/tmp/pi_clean_test`; the shared rootfs fixture
  (`base_fix/`) is **auto-built** by `make_base_fix.sh` when missing.
* Suites are location-independent: `pi_clean.sh` is resolved relative to
  the suite's own directory; the apt suites need passwordless `sudo`.
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

### Decisions locked (as of 2026-10-29)

* **Name is `pi_clean` for now** (`linux_clean` was considered and set
  aside); nothing Pi-specific is required of the box.
* `-v` = verbose, `-V`/`--version` = version (`pi_clean 0.9.0`).
* `--base` was **removed** 2026-10-29 in favor of the positional target.
  A one-time **migration hint** still recognizes `--base` (prints the new
  form, exits 2) — drop it in a later release if it has served its cycle.
* Report mode prints the title line **first**, before any mount/scan delay;
  extraction of compressed images announces start + done **on stderr only**.
* Honest sizes; everything deletable sits behind a `y/N` gate.

### Open / user's calls

* `pi_clean_log.txt` (beside this file) — a captured real run from an
  earlier version, moved into the folder by an outside client; on disk,
  gitignored, **awaiting a delete-or-keep call**.
* Real-box verification still owed by the user: `sudo -c` on a real rootfs,
  `-c -y`, a real `apt autoremove` run, and an unwritable-log refusal.
* Optional, declined twice so far: split `[5] TARGET SETUP` into named
  helpers — ask before doing it.
* **No remote is configured and nothing has been pushed; local `main` is
  the only branch.** Pushing/tagging a remote is a separate explicit call.

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
