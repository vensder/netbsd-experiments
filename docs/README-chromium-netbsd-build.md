# Building Chromium from `pkgsrc-wip` on NetBSD

Status as of this writing: **confirmed working on NetBSD 10.1 (VM)**.
Build completed successfully after roughly one overnight run on a PC
VM; a parallel build on a ThinkPad T440s laptop (the same hardware
used throughout this project) was still running after more than a day
of wall-clock time — see "Why this takes so long" below.

```sh
pkg_info | grep chromium
chromium-151.0.7922.108 Open source web browser
```

This document records the setup and the fixes applied, plus general
guidance for anyone rebuilding this on another machine, since
Chromium is one of the largest and most fragile packages in the
entire pkgsrc-wip tree.

Tested starting point: NetBSD 10.1, amd64, pkgsrc-2026Q2,
`/usr/pkgsrc/wip/chromium`.

---

## Why this takes so long

Chromium's own build system is genuinely enormous — tens of thousands
of source files across V8, Blink, networking, media codecs, sandboxing,
and more, plus a large dependency graph (this project alone needed
`nodejs24`, which itself needed a `net/c-ares` bump — see below). On a
well-supported platform with a mature, cached, highly-parallel build
setup, a from-scratch build still routinely takes hours on capable
hardware. On NetBSD via an unofficial WIP recipe — without the
years of platform-specific compiler/linker tuning and distributed
build caching that Chromium's own CI has for Linux/Windows/macOS —
expect it to run meaningfully slower and more serially than that.
"Like a separate OS" is a fair description: modern Chromium bundles
its own copies of dozens of libraries that would once have been
separate projects entirely (a full JS engine, a full layout/rendering
engine, its own font shaping, its own codec stack), and NetBSD is
building all of that from source, largely without pre-built
intermediate caching. A multi-day build on a laptop-class CPU (versus
an overnight run on a more capable PC) is consistent with that
difference in raw compute, not a sign anything is wrong.

If the laptop build is still progressing (CPU active, disk I/O
happening, no repeated identical error in the log), it's likely just
genuinely still working through the dependency/compile graph — worth
letting it continue unless you see it actually stalled/erroring.

---

## Before you start: is this actually worth it?

Chromium is a very large, notoriously fragile build even on
first-class-supported platforms (Linux). On NetBSD via an unofficial
WIP recipe, expect the same pattern seen throughout this whole
project with `ibus` and `carla`: one dependency's API/version skew
after another, each needing individual diagnosis. Budget real time
(this is realistically an overnight-or-longer build even once
everything compiles cleanly), and consider whether **Firefox**
(`www/firefox`, in the main tree, available as a binary package) meets
your actual need before committing to this path — see the main
Plasma6 README's "browser comparison" discussion for context. This
document assumes you've decided the comparison/experimentation is
worth it regardless.

## Prerequisites

Same base setup as everything else in this project — run
`prepare-wip-build.sh` first if you haven't (bootstraps pkgsrc, sets
up binary-first `mk.conf`, clones `pkgsrc-wip`, creates the
`python3`/`pyrcc5`/`pyuic5` symlinks, etc.).

```sh
cd /usr/pkgsrc/wip/chromium
make bin-install
```

Expect this to fail partway through — Chromium pulls in `nodejs24`
and dozens of other large dependencies, several of which are likely to
hit version-skew issues of their own on NetBSD. Diagnose each failure
the same way this whole project has approached every other build
error: read the actual compiler/linker error, don't assume it's
unfixable, check whether it's a known upstream issue before patching
blindly.

---

## Confirmed fix: `net/c-ares` too old for `nodejs24`

### Symptom
```
../src/cares_wrap.cc:1730:21: error: no matches converting function 'Callback' to type
'ares_host_callback' {aka 'void (*)(void*, int, int, const struct hostent*)'}
```
during the `nodejs24` build (a dependency of `chromium`).

### Cause
Node.js 24's vendored networking code (`cares_wrap.cc`) expects a
`c-ares` API surface newer than pkgsrc's packaged `net/c-ares`
(`1.34.7` at the time this was hit) provides. This is an ordinary
"dependency needs a newer version than what's in this pkgsrc snapshot"
situation — not a NetBSD-specific bug, and not something to patch
around in `nodejs24` itself. The correct fix is bumping the
`net/c-ares` package.

### Fix — the pkgsrc version-bump workflow

This is standard pkgsrc developer procedure, useful well beyond this
one package. Requires `pkgtools/pkgdiff` (provides `pkgvi`,
`mkpatches`, `patchdiff`) — install it first if not already present:
```sh
pkgin search pkgdiff
pkgin install pkgdiff
```

**1. Edit the version in the package's `Makefile`.** `pkgvi` is a
thin wrapper around your `$EDITOR` that tracks whether the file
changed:
```sh
cd /usr/pkgsrc/net/c-ares
pkgvi Makefile
```
Change `DISTNAME=` (or the relevant version variable) from `1.34.7` to
`1.34.8`, save and quit.

**2. Regenerate the checksums for the new version's distfile:**
```sh
make mdi
```
(`mdi` = `makedistinfo` — fetches the new distfile if not already
cached, and rewrites `distinfo` with the new file's checksums/size.
Without this step, `make` will refuse to build, complaining the
distfile doesn't match `distinfo`.)

**3. Remove the old installed version** (a straight in-place version
bump, not a parallel install):
```sh
pkg_delete libcares-1.34.7
```

**4. Build and install the new version:**
```sh
make bin-install
```

**5. Check whether the installed file list changed** — this matters
because `c-ares` ships a versioned shared library
(`libcares.so.X.Y`), and a minor version bump can change that
filename, which the package's `PLIST` needs to reflect:
```sh
make print-PLIST
```
Compare the output against the existing `PLIST` file:
```sh
diff PLIST <(make print-PLIST)
```
If the `.so` version string changed (e.g. `libcares.so.2.16` →
`libcares.so.2.17`), update `PLIST` to match — this is the "added
specific libcares.so.x.y file into PLIST" step. Edit `PLIST` directly
with the corrected filename, matching the format of the existing
entries.

**6. Rebuild `nodejs24` (and anything else depending on the old
c-ares) against the new library:**
```sh
cd /usr/pkgsrc/lang/nodejs24
make clean
make bin-install
```

### Result
The `ares_gethostbyaddr` signature mismatch is resolved; `nodejs24`
proceeds past this point. (Continue monitoring the Chromium build for
further dependency issues — this was one fix among what may be
several.)

---

## General troubleshooting approach for the rest of the build

Apply the same diagnostic pattern used successfully for `ibus` and
`carla` elsewhere in this project:

1. **Read the actual error**, not just the final `*** Error code N`
   summary — scroll back (or `script -c "make bin-install" logfile`
   and `grep`/review the log) to the real compiler/linker message.
2. **Check if it's a version-skew issue** (a dependency too old/new
   for what the consuming package expects) — the `c-ares` fix above is
   the template: bump the dependency via `pkgvi` + `make mdi`, rather
   than patching the consumer.
3. **Check if it's a NetBSD-specific detection gap** (a build system
   assuming a tool/feature exists under a different name or path than
   NetBSD provides it — the `pyrcc5`/`HAVE_PYQT` pattern from `carla`,
   or the Wayland-platform-detection pattern from `ibus`).
4. **Check for an existing upstream issue** before writing a local
   patch — searching `<project> NetBSD build` or the specific error
   text often surfaces a known, already-diagnosed problem.
5. **Never edit files under `work/`** as a permanent fix — anything
   there gets discarded on `make clean`/re-extraction. Fix the
   package's own `Makefile` (in `/usr/pkgsrc/...`, not `work/...`),
   or better, fix the root cause (missing symlink, wrong variable,
   outdated dependency) so the unmodified upstream build just works.

## Once a build succeeds

Same distribution approach as everything else in this project — the
resulting `.tgz` lands in `/usr/pkgsrc/packages/All` and is reusable
via `rsync`/`pkg_add` on other NetBSD machines of the same
release/architecture, without repeating the build.

---

## Chromium vs. Firefox comparison (ThinkPad T440s, NetBSD 10.1)

Informal but repeatable comparison: same YouTube video, forced to
720p in both browsers (to rule out YouTube auto-adjusting resolution
differently per browser), each run for the first ~1 minute of
playback.

### Methodology

Per-process CPU/memory totals, summed across every process belonging
to the browser (both spawn several — main, GPU, per-tab renderer):

```sh
ps aux | grep -i <browsername> | grep -v grep \
    | awk '{cpu+=$3; mem+=$6} END {print "CPU%:", cpu, "  RSS(MB):", mem/1024}'
```

Sampled 5 times, 5 seconds apart, across three separate ~1-minute
playback runs per browser (`chrome.sh` / `firefox.sh` wrapping the
command above in a loop). Ignore `top`'s `VIRT` column for
Chrome-family browsers specifically — the very large `VIRT` numbers
(e.g. `1420G`) are virtual address-space reservations from Chrome's
per-process sandboxing/ASLR, not real memory usage; `RES`/RSS is the
number that matters, and is what the command above sums.

### Hardware video decode status — checked first, since it changes
how to read the CPU numbers

- **Chromium** (`chrome://gpu`): *Video Decode: Software only,
  hardware acceleration disabled* — blocklisted by Chrome itself for
  this Mesa/Intel-Haswell driver combination, not a NetBSD-specific
  absence of the codepath.
- **Firefox** (`about:support`): no `HW_DECODE` entry present at all
  (searched the full page). WebGL/3D acceleration is confirmed
  working (Mesa DRI Intel Haswell driver, GPU listed active), but that
  is a separate subsystem from video decode — its absence from the
  page suggests Firefox's NetBSD build either doesn't expose hardware
  video decode as a reportable feature on this platform, or doesn't
  have it available here at all.

**Conclusion: both browsers are doing pure software video decode on
this system.** The CPU comparison below is software-decoder-vs-
software-decoder, not a hardware-acceleration comparison — worth
keeping in mind so the numbers aren't misread later.

### Results

| | Chrome | Firefox |
|---|---|---|
| CPU%, run 1 (5 samples, 5s apart) | 64.7, 80.7, 40.9, 52.3, 43.5 | 69.7, 50.9, 43.7, 30, 21.1 |
| CPU%, run 2 | 25.6, 18.1, 13, 9.5, 6 | 11.5, 7.9, 5.9, 29.9, 21.9 |
| CPU%, run 3 (steady-state) | 6.2, 4.4, 3.4, 2.4, 1.6 | 17.4, 27.3, 14.3, 13.5, 39.2 |
| Total RSS, single snapshot | ~1,959 MB across 13 processes | ~1,339 MB across 10 processes |

**Pattern**: Chrome starts high (initial buffering) then decays
cleanly and monotonically to a low, stable CPU floor (~1.6% by the
third run). Firefox starts similarly high but **oscillates** —
repeatedly climbing back up mid-playback (e.g. 5.9% → 29.9%, 13.5% →
39.2%) rather than settling to a comparable steady low floor.

**Memory**: Firefox's RSS was lower in this snapshot (~1.3 GB vs.
~2.0 GB for Chrome) — a real difference, though a single snapshot
rather than an averaged measurement.

### Read on the result

- **CPU, sustained playback**: Chrome's clean settle-to-low-floor
  pattern is the more favorable result for this specific workload on
  this specific (old, single-digit-year-old integrated GPU) hardware
  — matters for battery life/fan noise on a laptop doing long video
  playback. Firefox's repeated oscillation, even if its peaks aren't
  dramatically higher, means it never reaches the same idle-efficient
  state.
- **Memory**: point in Firefox's favor in this snapshot; not
  confirmed as a consistent pattern across multiple snapshots.
- **Caveat**: this is one measurement session, informally sampled, on
  software decode only. Worth re-running (same methodology) if either
  browser gets updated, or if hardware video decode is ever
  successfully enabled for one or both (see below) — that would
  likely change the picture substantially, especially for Chrome
  given how much of its current CPU cost is presumably the software
  decode path it's currently forced into.

### If you want to test forcing hardware decode on Chrome

Chrome's blocklist is a conservative, proactive refusal based on
known driver-combination issues, not a hard technical unavailability
— it can be overridden for testing:
```sh
chromium --ignore-gpu-blocklist --enable-features=VaapiVideoDecoder
```
Re-check `chrome://gpu` afterward. Treat this as an experiment, not a
daily-driver default — Chrome blocklisted this combination for a
reason (likely rendering bugs/instability on this exact Mesa driver
version), similar in spirit to the i915 KMS driver instability found
independently elsewhere in this project on NetBSD 10.1.

---

## Open items / to fill in

- [x] Confirm final build success — **done, NetBSD 10.1 VM**,
      `chromium-151.0.7922.108`, roughly one overnight run.
- [ ] Confirm laptop build completion and note actual total wall-clock
      time for a slower-CPU comparison point.
- [ ] Note whether any further dependency version bumps or WIP-Makefile
      fixes were needed beyond `c-ares` (only that one was needed for
      the VM build; confirm same holds for the laptop).
- [ ] Record whether the resulting Chromium binary actually launches
      and renders correctly (given the DRM/GL permission issue found
      earlier in this project — confirm hardware acceleration works,
      not just software fallback).
- [x] Browser comparison notes (Chromium vs. Firefox) — see section
      above. Software-decode-only comparison; revisit if hardware
      video decode ever becomes viable for either browser.
