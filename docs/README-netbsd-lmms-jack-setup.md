# LMMS + JACK on NetBSD (ThinkPad T440s) — Setup Notes

Tested on: NetBSD 10.1 (amd64), pkgsrc `2026Q2` binary packages.
Should also apply to NetBSD 11.0 with the same pkgsrc tag, but audio
group/device naming should be reconfirmed per-system.

## 1. Prerequisites

```sh
sudo pkgin install jack qjackctl jack-keyboard
```

Confirm the JACK "sun" backend module is present:

```sh
find /usr/pkg -iname "*jack_sun*"
# expect: /usr/pkg/lib/jack/jack_sun.so
```

Confirm your audio device and that it plays back correctly outside JACK
first (sanity check before touching JACK at all):

```sh
audiocfg list
# confirms which /dev/audioN is the active default (e.g. audio1 = Realtek codec)
```

## 2. Realtime scheduling (`login.conf`)

By default `/etc/login.conf` on a fresh NetBSD install may have the
`default:` class entirely commented out, meaning no `rtprio` (realtime
priority) capability is granted to normal users at all. This causes:

- `jackd -R` (realtime mode) to fail with `Cannot use real-time
  scheduling (RR/10) (1: Operation not permitted)`
- LMMS to print `Notice: could not set realtime priority.` on every
  launch

**Fix:** uncomment/add the `default:` class in `/etc/login.conf` with a
bounded `rtprio`:

```
default:\
        :path=/usr/bin /bin /usr/sbin /sbin /usr/X11R7/bin /usr/pkg/bin /usr/pkg/sbin /usr/local/bin:\
        :umask=022:\
        :datasize-max=512M:\
        :datasize-cur=512M:\
        :maxproc-max=1024:\
        :maxproc-cur=512:\
        :openfiles-cur=128:\
        :stacksize-cur=4M:\
        :rtprio=95:\
        :copyright=/dev/null:
```

Notes:
- Use a bounded value like `95`, not `inf` — an unbounded realtime
  ceiling let a stuck JACK thread starve X11/window-manager rendering
  during troubleshooting (symptom: LMMS splash screen and qjackctl
  window froze/rendered as a black rectangle).
- `maxproc-cur` was also bumped from the stock `160` to `512` — a full
  LXQt + JACK + LMMS session can exceed the low stock default.

Apply and re-login (new login session required, not just a new shell):

```sh
sudo cap_mkdb /etc/login.conf
# log out of the X session fully, log back in
```

**In practice, `jackd -R` (true realtime mode) was never gotten fully
stable on this system** even after the `rtprio` fix — it's possible a
further NetBSD `kauth` privilege is also required beyond the
`login.conf` rlimit. **Non-realtime mode (`-r`) with a modest period
size has proven stable and is the documented/supported NetBSD
approach** (see `MESSAGE.NetBSD` from the `audio/jack` pkgsrc package).
Realtime mode is not required for normal LMMS use at the latencies
tested here.

## 3. Working JACK invocation

```sh
jackd -v -Sr -d sun -p 512 -r 44100 -w 32
```

or, confirmed clean/error-free with `jack-example-tools` installed
(§6) and default word length:

```sh
jackd -v -Sr -d sun -p 1024 -r 48000
```

Flags:
| Flag | Meaning |
|------|---------|
| `-v` | verbose output |
| `-S` | synchronous mode (**required** on the `sun` backend — omitting it fails with `Cannot run in asynchronous mode`) |
| `-r` | **no-realtime** (note: at the top level `-r` = non-realtime; this is the opposite of the `sun` backend's own `-r`/`--rate`, which only applies *after* `-d sun`) |
| `-d sun` | use the native NetBSD `sun` audio driver backend |
| `-p 512` | period size, frames per process() call (must be power of 2) |
| `-r 44100` | (sun-backend flag) sample rate |
| `-w 32` | (sun-backend flag) word length / sample bit depth |

This configuration ran with **low CPU usage** on the T440s with LMMS,
`jack-keyboard`, and `amsynth` all connected simultaneously.

Lower period sizes (`-p 256`, `-p 128`) can be tried for lower latency;
back off one step as soon as xruns appear in `jackd`'s own terminal
output. `-p 512 -r 44100` was the confirmed-stable baseline.

If you see this once per new client connecting — it's benign, observed
consistently across working sessions, does not indicate failure:
```
Cannot read socket fd = N err = Undefined error: 0
```

## 4. Startup order

Start each piece **one at a time**, confirming it's stable before
starting the next — this avoids the cascade failures seen when
multiple clients register against a not-yet-settled server.

```sh
# 1. Start the JACK server, alone. Let it sit ~10s with no errors.
jackd -v -Sr -d sun -p 512 -r 44100 -w 32

# 2. (separate terminal) MIDI clients
jack-keyboard &

# 3. Synth/instrument clients
amsynth &          # example — near-zero latency observed here

# 4. LMMS last
lmms &
```

Then, in LMMS: **Edit → Settings → Audio → JACK**, restart LMMS if
prompted.

Connect MIDI: in `jack-keyboard`'s own connection UI (or via LMMS's
vkeyboard interface), connect to `lmms:MIDI in`.

**Do not start playback/transport until all clients show as connected**
in the graph — starting transport mid-registration is what triggered
`ProcessGraphSync`/`SuspendRefNum` cascades during testing.

## 5. Known issue: LMMS latency vs. amsynth

With identical JACK server settings, `amsynth` showed **near-zero**
input-to-sound delay, while **LMMS showed a noticeable delay**. This
points to LMMS's own internal audio buffer, not the JACK server
period, as the source of the extra latency.

**To reduce:** in LMMS, **Edit → Settings → Audio → "Frames per audio
buffer"** — lower this to match (or be a small multiple of) the JACK
period size (e.g. `256` or `512`), rather than the LMMS default of
`1024`. Keep LMMS's project sample rate matched to JACK's `-r` value
(`44100` here) to avoid resampling overhead.

## 6. Known issue: qjackctl

`qjackctl` was observed to hang on startup with a black/unresponsive
window, with `gdb` confirming its main thread stuck inside
`jack_client_open()` waiting on a `read()` from the JACK server socket
— the same stall pattern LMMS hit once, independently, earlier in
troubleshooting. It has since started and worked in some sessions but
is **not reliable** — treat as suspect, not a required tool.

**Note:** the `jack-1.9.22` pkgsrc package on this system ships
**server-only** — `pkg_info -qL jack | grep bin/` returns only
`/usr/pkg/bin/jackd`. The client tools (`jack_lsp`, `jack_connect`,
`jack_disconnect`, etc.) were split upstream into a separate
`jack-example-tools` repository and are packaged in pkgsrc as a
**`wip` (work-in-progress) package**, not yet in the main tree:

```sh
cd /usr/pkgsrc/wip/jack-example-tools
sudo make install clean
```

**Known packaging bug (as of this `wip` snapshot):** the package's
`PLIST` lists three internal JACK client libraries with a macOS
`.dylib` extension instead of the correct NetBSD/ELF `.so` extension,
causing the install to complain about missing files. This also
explains `jack_get_descriptor returns null for 'jack_inprocess.so'`
(and `jack_internal_metro.so`, `jack_intime.so`) messages seen in
`jackd -v` output before this is fixed — JACK looks for the correct
`.so` name at runtime while the actually-installed file was still
named `.dylib`.

**Fix — edit `PLIST` before building:**

```sh
cd /usr/pkgsrc/wip/jack-example-tools
sed -i '' -e 's/\.dylib$/.so/' PLIST   # or edit manually
```
(the three affected lines: `lib/jack/jack_inprocess.so`,
`lib/jack/jack_internal_metro.so`, `lib/jack/jack_intime.so` — replace
their `.dylib` counterparts in `PLIST`)

Then build/install as above.

After installing this, JACK sessions became noticeably more stable —
a full `jackd -v -Sr -d sun -p 1024 -r 48000` session with `amsynth`,
`jack-keyboard`, and `lmms` all connected produced a clean verbose log
with **zero errors**, versus the intermittent `ProcessGraphSync`/
`SuspendRefNum`/socket-read errors seen earlier in this document. It's
not confirmed whether installing the real client tools fixed an
underlying issue, or whether earlier instability was coincidental —
but this is now the recommended baseline setup regardless, since it
also unlocks proper `jack_lsp`/`jack_connect` port management instead
of routing through GStreamer's `port-pattern` workaround (§10).

If debugging a qjackctl hang again:

```sh
qjackctl &
sleep 3
gdb -p $(pgrep qjackctl)
(gdb) info threads
# find the thread whose LWP == qjackctl's own PID (ps aux | grep qjackctl)
(gdb) thread <N>
(gdb) bt
```

## 7. Unrelated but critical fix: LMMS segfault on startup (Qt5/KF5 conflict)

Not JACK-related, but required before any of the above worked at all.

**Symptom:** LMMS segfaults immediately on launch, backtrace shows
crash inside `QCoreApplicationPrivate::sendThroughApplicationEventFilters`
→ `QWidget::setParent` → `MainWindow::MainWindow()`.

**Cause:** a stray Qt5-linked KDE Frameworks 5 (`KF5`) package chain
was installed alongside the Qt6 `kf6-*` stack actually used by a
Qt6-based LXQt session. LMMS (Qt5) ends up dynamically loading the
broken/ABI-mismatched Qt5 `KF5WidgetsAddons` at runtime (confirmed via
`QT_DEBUG_PLUGINS=1 lmms`), corrupting a Qt application-level event
filter object and crashing on first widget creation.

**Fix:**

```sh
pkg_info -R kwidgetsaddons-5.116.0nb8   # walk the dependency chain first
sudo pkgin remove kwidgetsaddons kconfigwidgets kiconthemes qqc2-desktop-style
```

**How to detect this on a fresh system:** if your LXQt/desktop is
Qt6-based (`ldd $(which lxqt-session) | grep -i qt` shows only `Qt6*`),
any installed Qt5 `kwidgetsaddons-5.*`/`kconfigwidgets-5.*`/etc.
package is very likely an orphaned leftover (e.g. pulled in by trying
a KDE-style theme via the LXQt appearance configurator) and should be
removed:

```sh
pkg_info -a | grep -iE "^kf5|^k[a-z]+-5\.[0-9]"
```

## 8. LMMS build options

```sh
cd /usr/pkgsrc/audio/lmms
make show-options
```

Recommended for NetBSD minimal setups:

```
PKG_OPTIONS.lmms=jack
```

- `jack` — pro-audio routing, recommended, used throughout this guide.
- OSS support is compiled in **unconditionally** (not gated by a
  package option) — always available as a fallback via LMMS's own
  Settings → Audio → OSS, device `/dev/audio`. Confirmed stable.
- **Not recommended:** `alsa`, `portaudio`, `pulseaudio`, `sdl` — none
  are native NetBSD audio APIs; they're portability/compat shims that
  add package weight and dependency-chain risk for no real benefit
  over JACK or native OSS.

## 10. Recording JACK audio to a WAV file

`audiorecord`/`mixerctl` **do not work for this** — they operate at
the OSS/hardware level (`/dev/audio`), which only sees physical
capture input. A JACK client's output (e.g. `amsynth`) never touches
that path, so recordings come out silent.

Tools checked and **not usable** on this system:
- `jack_capture` — not in pkgsrc at all.
- `sox` / `sox_ng` / `audacity` — installed, but none are linked
  against `libjack` (confirmed via `ldd $(which <tool>) | grep -i
  jack` returning nothing), so none can open a JACK input regardless
  of in-app preferences settings.
- `ecasound` — not checked/available in this session; worth trying if
  GStreamer ever becomes unavailable.

**Working method: GStreamer + `gst-plugins1-jack`.**

```sh
sudo pkgin install gstreamer1 gst-plugins1-jack
```

(`gst-launch-1.0` and `gst-inspect-1.0` ship inside the core
`gstreamer1` package itself on this pkgsrc tree, not a separate
`-tools` package.)

Verify the JACK plugin registered:

```sh
gst-inspect-1.0 jackaudiosrc
```

**Record**, with `jackd` and the source client (e.g. `amsynth`)
already running and connected to the server:

```sh
gst-launch-1.0 jackaudiosrc connect=auto-forced port-pattern=amsynth \
  ! audioconvert ! wavenc ! filesink location=/home/vensder/Music/rec.wav
```

- `connect=auto-forced` + `port-pattern=<name>` auto-connects to any
  JACK output port whose name matches `<name>` — this is the
  workaround for not having `jack_connect` available. Substitute the
  pattern for whatever client you're recording from.
- `connect=explicit` requires the `port-names` property with **exact**
  port names (e.g. `amsynth:out_1,amsynth:out_2`) — fails with `User
  must provide valid port names` if you pass a plain pattern instead;
  use `auto-forced` unless you already know the exact port names.
- Play/trigger the source, then **`Ctrl+C` once** to stop — this
  sends the pipeline through a clean `PLAYING → NULL` shutdown so
  `wavenc` finalizes the WAV header correctly. Confirmed working: a
  14-second capture produced a valid, non-silent file.
- **Do not follow `Ctrl+C` with `Ctrl+Z`** — that only suspends
  (backgrounds) an already-exited process's shell job entry; if the
  pipeline is still shown as a stopped job afterward, clean it up with
  `kill -9 %<job-number>`.

Check the result:

```sh
ls -la /home/vensder/Music/rec.wav
```

**Playback / verification:**

- `cplay <file>.wav` — confirmed reliable, no extra packages needed.
  Simplest way to verify a recording.
- `gst123 <file>.wav` — needs `gst-plugins1-oss` installed
  (`sudo pkgin install gst-plugins1-oss`) or it silently plays with
  **no sound and no error message** — it still shows a progress timer
  and "Playing..." status even with a nonfunctional/fallback sink, so
  a silent `gst123` playback does not by itself mean the file is bad.
  Verify with `cplay` first before assuming a recording failed.
  Once the plugin is installed, plain `gst123 -a oss <file>.wav`
  works; the `-a oss=/dev/audio1` device-suffix form was not needed
  in testing.

## 11. General debugging notes for this hardware/OS combo

- Prefer `pkgin` over raw `pkg_add`/`pkg_delete` for dependency-aware
  installs/removals; `pkgin -f update` resyncs its local DB if it
  drifts from `pkg_info`'s view.
- `QT_DEBUG_PLUGINS=1 <app>` is the fastest way to see what shared
  libraries a Qt app loads at runtime — more useful than `gdb` when
  binaries are stripped (no debug symbols), which pkgsrc binary
  packages are by default.
- For a hung (not crashed) GUI process: `gdb -p $(pgrep <name>)`, then
  `info threads` to find the main thread (its LWP == the process's own
  PID from `ps aux`), `thread <N>`, `bt`.
- Diff against a known-working reference install (e.g. a different
  NetBSD version/partition on the same hardware) was the single most
  effective troubleshooting technique used in this session — package
  list diffs surfaced the root cause of the Qt5/KF5 crash directly.
- `osabi-NetBSD-X.Y` dummy packages enforce an exact `uname -r` match
  for kernel-ABI-sensitive packages; a transient CDN package-version
  mismatch can cause a spurious install failure — usually resolves
  itself on the next `pkgin update`.
