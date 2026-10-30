# pi_clean — reclaim space on a Raspberry Pi (and any Linux box)

One file, no dependencies: a report-first junk cleaner for **this machine, a
mounted root, a block device, or a rootfs image** (plain / `.xz` / `.zst` /
`.zip` — no booting needed). It walks the well-known junk spots and offers
each collection with its name, its size, and why it is safe to remove — and
deletes **only what you approve**, one `y/N` per collection.

- 🍓 Made for the Raspberry Pi, works on most Linux distros
- 🐧 Plain Bash — nothing to install
- 🔒 **Report-only by default** — deletes nothing unless you pass `-c` and
  answer `y`; even a `-c` run still asks per collection
- 📦 Works on a running box, a mounted root, `/dev/…`, or an image file
- 🧾 A `-c` run is recorded in `pi_clean.log` (a destructive pass without a
  log is refused unless `--no-log`)
- 📐 Compressed-image runs print sizes at a glance (image / what it needs /
  best system RAM disk / what `-m` would mount / the max an own mount can
  ever be), and `-m` can run the extract in an own RAM disk capped by the
  RAM the system can spare

## ⚠️ Read this before you run — it is destructive

pi_clean, when run with `-c`, **deletes files and uninstalls packages**.
Every collection still asks `y/N`, but the moment you answer `y` the
deletion happens — and some of it is **irreversible**:

- **emptying the trash** is permanent;
- **deleting duplicate files** removes the extra copies for good;
- **`apt autoremove`** removes whole packages, not just files;
- **old kernel artifacts, flatpak runtimes, core dumps** are gone once approved.

**Do this before the `-c` pass:**

1. The default (no flags) is a **read-only report** — it deletes nothing.
2. **Back up the card first** (e.g. **PiSafe** or **Raspberry Pi Imager**,
   or any image/snapshot tool you trust). Anything you have not backed up
   may not come back.

### Disclaimer

pi_clean is provided **"as is", without warranty of any kind**, express or
implied. Use it at your own risk. **The authors and maintainers are not
responsible for data loss or damage** of any kind. You are responsible for
the files, packages, and systems you point it at, and for every deletion you
approve.

## Install

pi_clean is a **single self-contained script — nothing to build, no packages
to install**. Grab it straight from this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/RichardMidnight/pi_clean/main/pi_clean.sh -o pi_clean.sh
```

(no `curl`? open
[pi_clean.sh](https://github.com/RichardMidnight/pi_clean/blob/main/pi_clean.sh)
in a browser and download it instead.)

Then either run it in place:

```bash
bash pi_clean.sh            # from that folder
```

— or install it on the `PATH` as `pi_clean`:

```bash
sudo cp pi_clean.sh /usr/local/bin/pi_clean && sudo chmod +x /usr/local/bin/pi_clean
pi_clean -h                 # sanity check
```

Needs: `bash` and standard coreutils (present on any Pi image), and `curl`
for the download. Compressed images additionally use `xz` / `zstd` /
`unzip`, whichever of your archive's formats is installed; `sudo` (or root)
for the system sections and for `DEV`/`IMG` targets.

## Quick start

```bash
pi_clean.sh                 compact read-only report of this box — deletes nothing
pi_clean.sh -v              full report: per-collection descriptions and sizes
sudo pi_clean.sh -c         deletion pass (per-item y/N still applies; logged)
pi_clean.sh -t              one bare number: reclaimable bytes

pi_clean.sh /media/pi/rootfs      DIR — an already-mounted system root
pi_clean.sh /dev/sda              DEV — rootfs partition found, mounted rw, umounted on exit (sudo)
pi_clean.sh image.img.xz          IMG — compressed rootfs image (see below; sudo)

sudo pi_clean.sh -m image.img.xz  extract in an own RAM disk when nothing existing fits
```

Run with `sudo` to include the root-only (system) sections; without it,
those are reported as *skipped — needs root* rather than erroring.

## What it cleans

**Per home directory** (the running user, plus `/root` when run as root):
thumbnail / `pip` / `npm` / browser caches, the rest of `~/.cache`, the
trash can (permanent), downloaded `.deb` installers, and duplicate files
> 1 MB (by SHA-256 — one copy kept). History, logins, bookmarks and
settings are **kept**.

**System-wide (`sudo`):** `apt` cache / package index / `autoremove`,
`systemd` journal older than 7 days, unused flatpak runtimes / SDKs, old
kernel artifacts, core / crash dumps, rotated log files, stale temp files.

**Report only (never removes):** a final listing of apps installed
redundantly (e.g. two browsers) so you can prune them by hand — pi_clean
never uninstalls applications.

## Compressed images are report-only

`-c` is refused for `.xz` / `.zst` / `.zip` images: a clean pass would only
reach pi_clean's throwaway extract, and the archive would stay
byte-identical. Run it **without** `-c` instead — the report tells you what
could be freed inside, so you can decide whether your own decompress →
clean → (shrink) → recompress round (image backed up first) is worth it.
pi_clean does not rewrite images.

## Documentation & code

| Path | What |
|---|---|
| `pi_clean.sh` | The entire product (~1,565 lines) in 12 numbered modules — jump to them with `grep -nE '#   \[[0-9]+\]' pi_clean.sh` |
| [`USAGE.md`](USAGE.md) | Full flag reference, logging rules, how the suites work, and maintainer notes |
| `testing/` | 11 agent-safe suites: shimmed `apt`/`losetup`/`mount`, auto-built fixture |
| `LICENSE` | GNU GPL v3 |

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
