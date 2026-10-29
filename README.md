# pi_clean — reclaim space on a Raspberry Pi (and any Linux box)

*pi_clean* scans a Raspberry Pi — or any Debian/Ubuntu Linux system — for reclaimable
files and removes them **one collection at a time**, each shown with a description,
its size on disk, and an explicit `y/N` prompt before anything is deleted.

- 🍓 Made for the Raspberry Pi, works on most Linux distros
- 🐧 Plain Bash, no dependencies to install
- 🔒 **Report-only by default** — nothing is deleted until you opt in, and even
  then every collection still asks `y/N`
- 🧾 A `-c` run is logged to `pi_clean.log` next to the script, so a destructive
  pass is never unrecorded (refuses to clean with no log unless you ask to skip it)
- 📦 Scans **this machine, a mounted root, or an image/SD card** without booting it

---

## How it behaves

pi_clean walks the well-known junk spots and offers each group with its size and why
it is safe to remove. Nothing is deleted unless you answer `y`.

- **Default (no flags):** a compact read-only report — what could be cleaned and how
  much it would free. Deletes nothing.
- **`-v` / `--verbose`:** the full report with per-collection descriptions and sizes.
- **`-c` / `--clean`:** enables the deletion pass. Every collection **still asks
  `y/N`** before it is removed, and the whole run is appended to `pi_clean.log`
  beside the script (append mode, one `====` header per run).
- **`-y` / `--yes`:** answer `y` to the gate and to every collection (used with `-c`).
- **`-n` / `--dry-run`:** alias for the compact read-only report (nothing deleted).
- **`--no-log`:** run `-c` without writing `pi_clean.log`.
- **`-t` / `--total`:** print only the reclaimable bytes — one bare number.
- **`-V` / `--version`, `-h` / `--help`:** show the version / this help.

Run with `sudo` to include the root-only (system-wide) sections; without it, those are
reported as *skipped — needs root* rather than erroring.

---

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

**Report only (never removes):** at the end it also lists apps that are installed
redundantly (e.g. two browsers, two archive managers) so you can prune them by hand.
pi_clean never uninstalls applications — that report is informational.

---

## Usage

```bash
pi_clean.sh                 # read-only report (nothing deleted)
pi_clean.sh -v              # full per-collection report
pi_clean.sh -c              # enable the deletion pass (still asks y/N per item)
sudo pi_clean.sh -c         # include the root-only (system) sections
pi_clean.sh -c -y           # clean and auto-answer yes to everything
sudo pi_clean.sh -t         # print only reclaimable bytes (one number)
pi_clean.sh -V              # show the version and exit
pi_clean.sh -h              # help
```

### Working on another system (DIR / DEV / IMG)

Pass a single plain argument to scan a different root instead of this machine:

- **`DIR`** — an already-mounted system root (e.g. `/media/pi/rootfs`). Needs root only to delete.
- **`DEV`** — a `/dev/sdX` / `/dev/sdXn` device. The rootfs partition is found, mounted
  read-write, and unmounted again on exit. Needs root.
- **`IMG`** — an image file: plain, `.img.xz`, `.img.zst`/`.zstd`, or a zip of the image
  (compressed ones are extracted first; the extract is cleaned up on exit). Attached as a
  loop device, scanned, and detached on exit. Needs root.

```bash
sudo pi_clean.sh -v /media/pi/rootfs
sudo pi_clean.sh -c /dev/sdb
sudo pi_clean.sh -v raspbian-2026-01-01.img.xz
```

### Install to PATH (optional)

pi_clean is a single self-contained script. To invoke it as `pi_clean`:

```bash
sudo cp pi_clean.sh /usr/local/bin/pi_clean && sudo chmod +x /usr/local/bin/pi_clean
```

---

## Logging

A `-c` run appends a full transcript to `pi_clean.log` in the same directory as the
script (one `==== pi_clean <version> <timestamp> (user ...) args: ...` header per run).
The logging is deliberate: a destructive pass is not allowed to go unrecorded unless
you opt out with `--no-log`. Report-only runs (default, `-t`) never log.

---

## Testing

The test harness lives in `testing/` and builds its own fixtures under
`/tmp/pi_clean_test` (using lightweight shims for `apt-get`, `chroot`, `losetup`,
`zstd`, `unzip`, and a fixture-based base root). Ten suites cover the main areas:

```bash
cd testing
for t in test_*.sh; do  bash "$t"  ; done
# or run a single suite, e.g.:
bash test_kernels.sh
```

Suites: `test_cli_flags`, `test_base_sections`, `test_devmode`, `test_loopmode`,
`test_imgxz`, `test_imgcomp`, `test_kernels`, `test_dupapps`, `test_apt_autoremove`,
plus `live_regression.sh` (end-to-end) and `make_base_fix.sh` (fixture builder).
`bash -n` runs clean on all of them.

---

## Development

The program is a small library plus a `main()` that runs it, organised into numbered
modules — self-contained, documented by signature, easy to jump to:

```bash
grep -nE '#   \[[0-9]+\]' pi_clean.sh
#   [1] OPTIONS & HELP   [2] LIFECYCLE   [3] LOGGING   [4] BANNER
#   [5] TARGET SETUP     [6] SESSION    [7] CORE HELPERS
#   [8] COLLECTIONS·home [9] COLLECTIONS·system [10] REPORTERS
#   [11] MAIN            [12] SUMMARY & EXIT
```

The version string is `PI_CLEAN_VER` near the top of `pi_clean.sh` (currently
**0.9.0**). It's a single-file script with no build step.

---

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
