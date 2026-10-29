# pi_clean

A single-file bash junk-cleaning tool for Raspberry Pi / general-Linux boxes.
It walks the known junk spots (browser/app caches, downloaded installers,
trash, duplicate files; plus root sections: apt cache/lists/autoremove,
journal, old kernels, flatpak runtimes, core dumps, rotated logs, stale /tmp)
and offers each group with its size and why it is safe. **Report-only by
default — it deletes nothing unless you pass `-c` and answer `y`.**

```
pi_clean.sh                     compact read-only report (this box)
pi_clean.sh /media/pi/rootfs    a directory target (already mounted)
pi_clean.sh /dev/sda            a block device — rootfs partition found, mounted rw, umounted on exit
pi_clean.sh image.img.xz        an image — plain/.xz/.zstd/zip; compressed extracted first,
                                attached as a loop device, detached on exit
pi_clean.sh -v                  full report with per-collection detail
pi_clean.sh -c [-y]             deletion pass (per-item y/N unless -y); logged to pi_clean.log beside the script
pi_clean.sh -t                  print one bare number: reclaimable bytes
pi_clean.sh -h | -V             help | version (pi_clean 0.9.0); -h's title line comes first
```
Target is a plain positional argument — zero or one, order-free with flags.
`-c` runs append to `pi_clean.log` next to the script (`--no-log` skips).

## Layout

| Path | Purpose |
|---|---|
| `pi_clean.sh` | The entire product (~1,470 lines). 12 numbered module banners — jump: `grep -nE '#   \[[0-9]+\]' pi_clean.sh` |
| `testing/` | 10 suites, `shim_apt/` (fake chroot/apt-get), `make_base_fix.sh` (fixture builder) |

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

## Steady state (do not "improve" these)

* **shellcheck** = only 3 documented-correct families: SC2317 (trap callee
  `base_release`), SC1083 (`{LOGTEE[1]}` in the trap), SC2231 (flatpak glob).
* The `-c` log path is a coproc `tee -a`; the EXIT-trap close sequence is
  order-fragile on bash 5.2 — **do not reorder or "clean up" it**.
* `is_browser_cache()`: the `*chrom*` case subsumes chrome/chromium —
  don't re-add a `*chrome*` pattern.
* `bash -n` before and after any edit; `/tmp` leak delta must stay 0
  (8G tmpfs, a filled scratch dir = false failures).

## Decisions locked (as of 2026-10-29)

* **Name is `pi_clean` for now** (`linux_clean` was considered and set
  aside); nothing Pi-specific is required of the box.
* `-v` = verbose, `-V`/`--version` = version (`pi_clean 0.9.0`).
* `--base` was **removed** 2026-10-29 in favor of the positional target.
  A one-time **migration hint** still recognizes `--base` (prints the new
  form, exits 2) — drop it in a later release if it has served its cycle.
* Report mode prints the title line **first**, before any mount/scan delay;
  extraction of compressed images announces start + done **on stderr only**.
* Honest sizes; everything deletable sits behind a `y/N` gate.

## Open / user's calls

* `pi_clean_log.txt` (beside this file) — a captured real run from an
  earlier version, moved into the folder by an outside client; on disk,
  gitignored, awaiting a delete-or-keep call.
* Real-box verification still owed by the user: `sudo -c` on a real rootfs,
  `-c -y`, a real `apt autoremove` run, and an unwritable-log refusal.
* Optional, declined twice so far: split `[5] TARGET SETUP` into named
  helpers — ask before doing it.
* **No remote is configured and nothing has been pushed; local `main` is
  the only branch.** Pushing/tagging a remote is a separate explicit call.
