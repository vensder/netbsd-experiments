# Running KDE Plasma 6 on NetBSD 11 via pkgsrc

This document records a working, reproducible procedure for getting a
Plasma 6 desktop session running on NetBSD 11 using pkgsrc. As of this
writing, Plasma 6's core desktop shell ( `plasma-desktop` ) is **not**
available as a prebuilt binary package and requires building several
components from source, including one package pulled from the main
pkgsrc tree that is marked broken upstream.

Tested on: NetBSD 11.0 (GENERIC), amd64, pkgsrc-2026Q2, X11 session only
(Wayland is not viable on NetBSD at present — see "Why X11, not
Wayland" below).

**Related document:**
[README-ibus-netbsd-build.md](./README-ibus-netbsd-build.md) — `ibus`

(a common transitive dependency of GTK3/Qt desktop packages, including
this one) fails to build from source on NetBSD with two confirmed
upstream bugs; that document has the root-cause diagnosis and fix.
Referenced again at the relevant step below.

---

## 0. Before you start

* **Do this on a machine/VM you can afford to be down for a while.**
  Several steps involve building large C++/Qt packages from source and
  can take hours depending on hardware.
* **Never run the desktop session as root.** Use a normal user account
  for all testing ( `su - <user>` , not `su -` to root) — running Plasma
  as root causes session/seat management errors and is a real security
  problem, not just bad practice.
* **Keep root's login shell as `/bin/sh`, never a pkgsrc-installed
  shell like bash.** If a bulk build or `pkg_delete` operation ever
  wipes `/usr/pkg` , a bash-based root shell becomes unusable and you
  are locked out of root entirely except via single-user boot. Set
  this immediately after any fresh install:
  

```sh
  chsh -s /bin/sh root
  ```

---

## 1. pkgsrc bootstrap

Pick **one** `PKG_DBDIR` location and set it identically everywhere.
The modern default is `/usr/pkg/pkgdb` ; avoid the legacy
`/var/db/pkg` unless you have a specific reason to keep it.

```sh
mkdir -p /usr/src        # mksandbox/bootstrap expect this to exist
cd /usr/pkgsrc/bootstrap
./bootstrap --prefix=/usr/pkg --pkgdbdir=/usr/pkg/pkgdb --make-jobs=<N>
```

Set the DB path consistently in all three places pkg tools read it:

```sh
echo 'PKG_DBDIR=/usr/pkg/pkgdb' > /etc/pkg_install.conf
echo 'PKG_DBDIR=/usr/pkg/pkgdb' > /usr/pkg/etc/pkg_install.conf
```

## 2. `/etc/mk.conf`

Keep this minimal and stable — it affects **every** package build on
the system, so avoid stuffing build-specific or debugging flags in
here (see the pbulk section of your own notes for why this matters).

```
PKG_DBDIR=      /usr/pkg/pkgdb

MAKE_JOBS=      <N>            # conservative; raise only after testing stability

DEPENDS_TARGET= bin-install
UPDATE_TARGET=  bin-install
BINPKG_SITES=   https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/11.0
```

> **Do not** append a trailing `/All` to `BINPKG_SITES` — pkgsrc adds
> that itself, and doubling it up causes a `.../All/All` 404 during
> dependency fetches.

## 3. Clone `pkgsrc-wip`

Two of the required packages live in pkgsrc-wip, not the main tree:

```sh
cd /usr/pkgsrc
git clone https://github.com/NetBSD/pkgsrc-wip.git wip
```

## 4. Locale for Qt/CMake builds

Qt6/CMake tooling expects a UTF-8 locale and will emit repeated
(harmless but noisy) fallback warnings without one during builds. Set
this for your build shell:

```sh
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

Confirm it's actually installed first:

```sh
locale -a | grep -i utf | grep -i us
```

> Note: pkgsrc's own `bmake` build environment force-overrides
> `LANG=C LC_ALL=C ...` for every package build regardless of your
> shell — this is intentional (build reproducibility) and cannot be
> worked around from the shell. The locale warnings during package
> **builds** are cosmetic; this UTF-8 setting matters for the
> **running session** later (step 10+), not for build success.

## 5. Increase resource limits

Two limits commonly trip up KDE builds/sessions on NetBSD's
conservative defaults:

**Stack size** (needed for Perl's `mktables` /Unicode table generation
during dependency builds, and generally worth having headroom):

```sh
# /etc/login.conf, in the relevant class (e.g. "default"):
:stacksize-cur=256M:\
:stacksize-max=256M:\
```

**Open file descriptors** (KDE's D-Bus-heavy startup burst can exceed
default limits):

```sh
# /etc/login.conf:
:openfiles-cur=4096:\
:openfiles-max=4096:\
```

After editing, rebuild the capability DB and **fully log out/reconnect**
(login-class limits apply at login time, not mid-session):

```sh
cap_mkdb /etc/login.conf
```

> If `ulimit -n` / `-s` values look fine in `ulimit -Ha` (hard limits)
> but a `ulimit -n <value>` command still fails with "Operation not
> permitted", you're hitting the hard ceiling — check `ulimit -Ha`

> before assuming login.conf needs editing; NetBSD's default hard
> ceiling (e.g. `nofiles ~3400` ) may already be sufficient without any
> login.conf change.

## 6. Install available binary packages

Most of KDE Frameworks 6 ( `kf6-*` ), Qt6 ( `qt6-*` ), and most
`plasma6-*` components **are** available as prebuilt binaries. Install
a handful of top-level targets and let `pkgin` resolve the dependency
tree:

```sh
pkgin install plasma6-systemsettings plasma6-kwin-x11 plasma6-breeze \
    plasma6-kde-cli-tools plasma6-kscreen plasma6-kglobalacceld \
    plasma6-polkit-kde-agent plasma6-xdg-desktop-portal-kde
```

As of this writing, the following are **not** available as binaries
and must be built from source (next section):
* `plasma6-kwin` (native/Wayland-capable KWin — `plasma6-kwin-x11` IS
  available as a binary and provides the X11-only compositor, but the
  full package with `kwindowprop` etc. needs building)
* `plasma6-plasma-workspace` (marked broken upstream, needs override)
* `plasma6-plasma-desktop` (provides the actual `org.kde.plasma.desktop`
  shell package plasmashell needs — **this is the critical missing
  piece**, not currently packaged as a binary anywhere)

## 7. Build the missing packages from source

Do this on a disposable build machine/VM if at all possible — see
"Why not build directly on your daily driver" below.

```sh
cd /usr/pkgsrc/wip/plasma6-kwin
make bin-install

cd /usr/pkgsrc/x11/plasma6-plasma-workspace
make bin-install PKG_FAIL_REASON=""

cd /usr/pkgsrc/x11/plasma6-plasma-desktop
make bin-install PKG_FAIL_REASON=""
```

### Known build-time issues and fixes

**Missing `python3` symlink** — some CMake/Python codegen steps invoke
a bare `python3` , which doesn't exist if only a versioned
`python3.13` (or similar) is installed:

```sh
ln -s /usr/pkg/bin/python3.13 /usr/pkg/bin/python3
```

** `ibus` build failures** (a dependency of `plasma6-plasma-desktop` , 
and a common transitive dependency of GTK3/Qt-based packages
generally — also hit independently while building `carla` ) — this
package fails to build from source on NetBSD with two confirmed
upstream bugs (a Wayland-platform-detection PLIST mismatch, and a
stale Vala-generated `main.c` that still calls real Wayland functions
even when Wayland is disabled). Both are real, root-cause-diagnosed, 
and documented with the exact fix in a dedicated companion document:
**[README-ibus-netbsd-build.md](./README-ibus-netbsd-build.md)**.
Worth applying before building `ibus` at all, rather than the
quick-and-dirty placeholder-file workaround used the first time
through this process — the companion doc's fix is durable (survives
`make clean` ) and produces a genuinely correct package, including the
Wayland-enabled panel binaries actually working (not just present as
empty stub files).

**Perl/other builds hitting `stack overflow detected; terminated` ** —
see step 5 above; also check `MAKE_JOBS` isn't set higher than your
available RAM comfortably supports (this manifested as intermittent, 
load-dependent memory pressure in testing, not a CPU/hardware fault —
confirm with `vmstat 1` during a heavy build if it recurs).

## 8. Distributing built packages (VM → target machine)

If you built on a separate VM, ship the resulting `.tgz` files over
SSH rather than rebuilding on your target machine:

```sh
# on the target machine
mkdir -p /usr/pkgsrc/packages/All
rsync -av -e ssh <build-host>:/usr/pkgsrc/packages/All/ /usr/pkgsrc/packages/All/

export PKG_PATH="/usr/pkgsrc/packages/All;https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/11.0/All"
pkg_add -I plasma6-kwin-* plasma6-plasma-workspace-* plasma6-plasma-desktop-* ibus-*
```

## 9. Copy "should be created" example configs

pkgsrc deliberately does not overwrite config files under
`/usr/pkg/etc` — many packages ship an "example" and expect you to
copy it manually. **This is the single most common source of subtle
KDE breakage in this whole process** (missing PAM configs, missing
D-Bus system policies, and — critically — the missing plasmashell
autostart entry that was the final blocker in testing). Run this
sweep after every batch of installs:

```sh
for pkg in $(pkg_info -qa); do
    for f in $(pkg_info -qL "$pkg" 2>/dev/null | grep '^/usr/pkg/share/examples'); do
        target=$(echo "$f" | sed 's|/share/examples/|/etc/|')
        if [ ! -f "$target" ]; then
            mkdir -p "$(dirname "$target")"
            cp "$f" "$target"
            echo "Copied: $target"
        fi
    done
done
```

> **The most important single file this catches**:
> `/usr/pkg/share/examples/kde-xdg/autostart/org.kde.plasmashell.desktop`

> must be copied to `/usr/pkg/etc/xdg/autostart/` . Without it, 
> `plasma_session` starts and runs indefinitely but never actually
> launches `plasmashell` — you get a black screen with a working mouse
> cursor and no visible error. This one file was the final blocker in
> testing after everything else was already working.

## 10. Session setup: slim + X11 + `.xinitrc`

### slim.conf

```
login_cmd    exec /bin/sh - ~/.xinitrc %session > ~/.xsession-errors 2>&1
sessions     xfce4,icewm,plasmax11,awesome,twm
session_msg  Session:
```

(Ensure only **one** `login_cmd` line is active/uncommented.)

### `~/.xinitrc`

```sh
#!/bin/sh

export XDG_DATA_DIRS="/usr/pkg/share:/usr/X11R7/share:/usr/share"
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
export XDG_CONFIG_DIRS="/usr/pkg/etc/xdg:/etc/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

DEFAULT_SESSION=twm

case "$1" in
xfce4)
        export XDG_MENU_PREFIX=xfce-
        exec startxfce4
        ;;
icewm)
        exec icewm-session
        ;;
plasmax11)
        export XDG_MENU_PREFIX=plasma-
        /usr/pkg/libexec/kactivitymanagerd &
        exec dbus-run-session -- startplasma-x11
        ;;
*)
        exec "$DEFAULT_SESSION"
        ;;
esac
```

> ** `XDG_MENU_PREFIX=plasma-` is required.** NetBSD's pkgsrc installs
> all desktop environments' menu files into one shared
> `/usr/pkg/etc/xdg/menus/` directory, each with its own DE-specific
> prefix ( `plasma-applications.menu` , `xfce-applications.menu` , 
> `lxqt-applications.menu` , etc.) rather than a single generic
> `applications.menu` . Without setting the prefix, KDE's menu/cache
> tools look for a file that doesn't exist and the application
> launcher stays empty.

### Enable services

```sh
echo 'dbus=YES' >> /etc/rc.conf
echo 'slim=YES' >> /etc/rc.conf
/etc/rc.d/dbus start
/etc/rc.d/slim start
```

## 11. Per-user setup (run once, as the normal user — NOT root)

**Screen locker** — disable auto-lock until you've confirmed the
lockscreen QML renders correctly (known to fall back to a broken
minimal theme in current testing; harmless once bypassed but jarring
on first login):

```sh
mkdir -p ~/.config
cat > ~/.config/kscreenlockerrc << 'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
```

**Compositor backend** — if `kwin_x11` crashes with `XCB error 152
(BadDamage)` under OpenGL compositing (observed on Intel HD 4400 in
testing), switch to XRender:

```sh
cat > ~/.config/kwinrc << 'EOF'
[Compositing]
Enabled=true
Backend=XRender
EOF
```

> Do **not** fully disable compositing ( `Enabled=false` ) — this stops
> `startplasma-x11` 's startup sequence from ever launching
> `plasmashell` at all (it appears to wait on a compositing-active
> signal before proceeding). XRender keeps compositing "on" from
> `startplasma-x11` 's point of view while avoiding the OpenGL crash.

**Desktop icon permissions** — files under `~/Desktop/` are sometimes
created without correct ownership/executable bit, causing red
exclamation-mark icons:

```sh
chown $(whoami):users ~/Desktop/*.desktop 2>/dev/null
chmod 755 ~/Desktop/*.desktop 2>/dev/null
```

## 12. First login

Log in via slim, select the `plasmax11` session. Give it a solid
30–60 seconds on first login (icon cache, config parsing).

Verify the shell actually launched:

```sh
ps aux | grep plasmashell | grep -v grep
```

## 13. Rounding out the desktop

Install common applications (file manager, terminal, editor) via the
main pkgsrc KDE application meta-package and individual binaries:

```sh
pkgin install dolphin dolphin-plugins konsole kate
pkgin install kde        # broader app meta-package: kate, konsole,
                          # ark, okteta, and many KDE utilities/games
```

Rebuild the application cache after installing new apps so the menu
picks them up:

```sh
kbuildsycoca6 --noincremental
```

---

## Why X11, not Wayland

`kwin_wayland` is present as a binary (built alongside `plasma6-kwin` ), 
but a real Wayland session is not currently viable on NetBSD: `libinput`

— required by essentially every modern Wayland compositor including
KWin — has never been ported to NetBSD's `wscons` input API (unlike
FreeBSD/OpenBSD, which did this porting work years ago). NetBSD's own
developers who investigated this concluded it's a large, unresolved
undertaking. Stick with the X11 session ( `startplasma-x11` ) until this
changes upstream.

## Why not build directly on your daily-driver machine

pbulk-style bulk builds and even ordinary `bmake package` runs for
these packages install/deinstall real files in `LOCALBASE`

( `/usr/pkg` ) as part of normal operation. Build on a disposable VM, 
then ship finished `.tgz` binaries to your real machine via
`rsync` / `pkg_add` . This also keeps your daily-driver's `/etc/mk.conf`

free of build-debugging cruft that has no business being there
permanently.

## Known remaining issues (as of this writing)

* `kglobalaccel`,  `org.freedesktop.portal.Desktop`, and `ConsoleKit`
  D-Bus service warnings persist even in a working session. Session
  boots and runs, but global keyboard shortcuts and some
  portal-dependent features may not fully work. Root cause not yet
  identified — the `.service` files exist on disk but registration/
  activation still fails; worth revisiting.
* `org.kde.plasma.private.volume` QML module missing — the audio
  volume applet won't load. Likely needs a separate small package not
  yet identified.
* `discover` (software center) and `kontact` (PIM suite) are not
  installed/built in this procedure — install separately if wanted, 
  check binary availability first via `pkgin search` .
* A `pkg_admin check` run during testing found unrelated file
  corruption in an installed `gcc12` package (checksum mismatch, files
  missing from `+CONTENTS` ). Not connected to the KDE build process, 
  but worth running `pkg_admin check` on any system before relying on
  it, and reinstalling any package it flags.

## Quick troubleshooting reference

| Symptom | Likely cause | Fix |
|---|---|---|
| Black screen, cursor moves, nothing else | `plasmashell` autostart `.desktop` never copied from examples | Step 9 |
| `starting invalid corona "org.kde.plasma.desktop"` then exits | `plasma6-plasma-desktop` not built/installed | Step 7 |
| Session shows old slim wallpaper, no KDE background | Compositing fully disabled | Step 11 (use XRender, not `Enabled=false` ) |
| Repeated blink-then-black (crash loop) | `kwin_x11` crashing on `XCB error 152 (BadDamage)` under OpenGL | Step 11 (XRender backend) |
| Empty/broken application menu, "Entry is not valid" for every app | `XDG_MENU_PREFIX` not set to `plasma-` | Step 10 |
| Red exclamation icons on desktop | `~/Desktop/*.desktop` ownership/exec bit wrong | Step 11 |
| `kactivitymanagerd: not found` in `.xsession-errors` | Called by bare name in `.xinitrc` , but lives in `/usr/pkg/libexec` , not on `PATH` | Use full path in `.xinitrc` |
| `env: python3: No such file or directory` during a build | No bare `python3` symlink | Step 7 |
| pkgsrc build hangs/crashes intermittently under load, `stack overflow detected` on console | Insufficient VM RAM for `MAKE_JOBS` level, not a hardware fault | Lower `MAKE_JOBS` and/or increase VM RAM; see step 5 for stack/file-descriptor limits too |
| `ibus` build fails: PLIST/pkg_create error re: `Panel.Wayland.Gtk3.desktop` , or `wayland-client.h: No such file or directory` | Confirmed upstream `ibus` bugs (Wayland platform detection; stale Vala-generated `main.c` ) | See [README-ibus-netbsd-build.md](./README-ibus-netbsd-build.md) |

---

## Appendix: Dual-booting NetBSD 10 + NetBSD 11 on real hardware (UEFI/GPT)

This section covers a separate but related setup: NetBSD 10.1 and
NetBSD 11.0 installed side by side on a single physical disk, booting
via UEFI, on a Lenovo ThinkPad T440s. Recorded here because several
of the issues (and their fixes) are non-obvious and expensive to
rediscover.

### Firmware prerequisites (ThinkPad T440s, and likely similar-era Lenovo hardware)

Getting UEFI USB boot working at all required several BIOS changes, 
not just "switch to UEFI mode":

* `Startup → UEFI/Legacy Boot`: **UEFI Only**
* `Startup → CSM Support`: **No**
* `Security → Secure Boot`: **Disabled**
* `Config → USB → USB UEFI BIOS Support`: **Enabled** — a
  ThinkPad-specific setting, separate from the general UEFI/Legacy
  toggle; without it, USB media is invisible to UEFI boot regardless
  of every other setting being correct.
* `Config → USB → USB 3.0 Mode`: **Disabled** — on this generation of
  firmware (BIOS `GJET79WW 2.29` , 2014), leaving this on `Auto` caused
  the xHCI controller to not be ready early enough in POST for UEFI to
  recognize a USB stick as bootable, even though the same stick worked
  fine for ordinary (non-boot) USB access. This one setting fixed USB
  boot detection entirely.

**Also verify your install media is actually UEFI-capable before
troubleshooting firmware further.** NetBSD provides two separate amd64
image variants — `NetBSD-11.0-amd64-install.img.gz` (hybrid, 
UEFI **and** BIOS bootable) and
`NetBSD-11.0-amd64-bios-install.img.gz` (BIOS/legacy only, **no** EFI
System Partition at all). Verify with `gdisk -l <device>` on the
written USB stick: a valid hybrid image shows a real GPT with an
`EF00` -type EFI System partition. A corrupt or legacy-only write shows
"GPT not found" or a corrupted/mismatched GPT — re-download and
re-write in that case rather than continuing to debug firmware
settings.

### Disk layout (GPT)

```
gpt add -a 2m -l "EFI system" -t efi  -s 512m wd0
gpt add -a 2m -l "NetBSD10"   -t ffs  -s 114g wd0
gpt add -a 2m -l "NetBSD11"   -t ffs  -s 114g wd0
gpt add -a 2m -l "swap"       -t swap -s 10g  wd0
```

Each GPT partition gets its own kernel wedge device ( `dk0` .. `dk3` ).
**Wedge numbers are not guaranteed stable across boot contexts** — the
number the bootloader itself sees at the pre-kernel stage can differ
from what a running OS reports via `dkctl wd0 listwedges` . For
anything that must be correct at the *bootloader* level (i.e.
`boot.cfg` device targets), verify interactively from the boot prompt
(see below) rather than trusting a running OS's wedge numbering.

For `/etc/fstab` on each installed OS, prefer GPT-GUID-based
`NAME=<guid>` entries over `/dev/wd0X` -style device names — GUIDs are
tied to the specific partition and survive future repartitioning more
reliably than positional device names:

```sh
dkctl wd0 listwedges          # shows each wedge's GUID
```

```
NAME=<root-partition-guid>   /      ffs   rw          1 1
NAME=<swap-partition-guid>   none   swap  sw,dp       0 0
```

### The `bootme` GPT attribute controls the default OS

The UEFI-mode bootloader ( `EFI/boot/bootx64.efi` on the ESP, shared by
both installs) determines its default boot target via a GPT partition
attribute, not by which install ran last, and not via any file on the
ESP itself — there is no `boot.cfg` on the ESP in this setup, only the
loader binary. Per `gpt(8)` : *"The `bootme` flag is used to indicate
which partition should be booted by the NetBSD UEFI boot code. If not
set on any partition, the first (in terms of partition index) FFS
partition located will be used."*

Check current state:

```sh
gpt show -a wd0
```

Look for `Attributes: biosboot, bootme` on the partition that installs
sysinst last flagged. Each OS installer sets this automatically for
its own partition at install time — installing a second OS afterward
moves the flag to the new partition.

To change which OS boots by default without reinstalling anything:

```sh
gpt unset -i <old-default-index> -a bootme wd0
gpt set   -i <new-default-index> -a bootme wd0
```

### Per-OS `boot.cfg` , with cross-boot menu entries

Each OS's root partition has its own `/boot.cfg` (there is no shared
one). Whichever partition currently has `bootme` is the one whose
`boot.cfg` you land on by default. To be able to boot **either** OS
from that default menu, give **both OSes' `boot.cfg` the same full set
of entries**, using `hd0<letter>:netbsd` device syntax — determined by
the **bootloader's own** partition lettering, found interactively (see
below), which does not necessarily match disklabel/wedge letters used
elsewhere:

```
menu=Boot NetBSD 10 normally:rndseed /var/db/entropy-file;boot hd0b:netbsd
menu=Boot default normally:rndseed /var/db/entropy-file;boot
menu=Boot single user:rndseed /var/db/entropy-file;boot -s
menu=Boot NetBSD 10 single user:rndseed /var/db/entropy-file;boot -s hd0b:netbsd
menu=Boot NetBSD 11 normally:rndseed /var/db/entropy-file;boot hd0c:netbsd
menu=Boot NetBSD 11 single user:rndseed /var/db/entropy-file;boot -s hd0c:netbsd
menu=Drop to boot prompt:prompt
default=1
timeout=5
clear=1
```

**Finding the correct `hd0<letter>` mapping**: don't guess — from the
boot prompt ( `menu=Drop to boot prompt` ), use `ls` against candidate
letters to find which one holds real files before trusting any `boot`

command:

```
> ls hd0a:/
> ls hd0b:/
> ls hd0c:/
```

The one that lists a real filesystem (files like `.profile` , 
`boot.cfg` , `bin` , etc.) is a genuine root partition; an empty/failed
listing (e.g. the EFI System partition, which isn't FFS) rules that
letter out.

### Known issue: NetBSD 10.1's `i915drmkms` driver is intermittently unstable on this hardware (Intel HD Graphics 4400 / Haswell)

Symptom: boot hangs partway through, console shows repeating
`coretemp0` / `coretemp1` / `acpibat0` / `acpibat1` / `thinkpad0` / `acpitz0`

**"workqueue busy: updates stopped"** messages, fans spin to maximum, 
keyboard LEDs (Caps/Num Lock) still toggle but the boot never
progresses. This is **intermittent, not deterministic** — the same
NetBSD 10.1 install boots cleanly with `i915drmkms` enabled most of
the time, but has failed this way on multiple separate occasions.
NetBSD 11.0's `i915drmkms` has never exhibited this on the same
hardware.

Corroborating evidence even on successful NetBSD 10 boots: recurring
kernel warnings of the form

```
warning: .../drm/i915/intel_uncore.c:1197: Unclaimed write to register 0x44008
```

appearing sporadically during otherwise-normal sessions — consistent
with a real, narrow driver bug rather than a one-off fluke.

**Because it's intermittent, do not permanently disable `i915drmkms`

in `boot.cfg` ** — that trades away native `1600x900` resolution and
correct display proportions on *every* boot (the fallback `genfb`

driver runs at a fixed `1024x768` , visibly stretched/squished on this
panel) to guard against a failure that doesn't always happen.

**Manual recovery procedure, only when a boot actually hangs:**
1. Power-cycle.
2. At the boot menu, select **"Drop to boot prompt"**.
3. 

```
   > userconf disable i915drmkms*
   > boot hd0b:netbsd
   ```

4. This boots into a stable but visually-fallback (`genfb`,
`1024x768` , stretched) session — usable to finish whatever you were
   doing, until you're ready to try a normal boot again.

Verify which driver actually attached, if in doubt:

```sh
dmesg | grep -iE 'i915|genfb|wsdisplay0'
```

`intelfb0 at i915drmkms0` = full native driver active.
`genfb0 ... ; drm at genfb0 not configured` = fallback active
(i915 successfully disabled).

### Audio (NetBSD 10, LXQt)

PulseAudio (already pulled in as an LXQt dependency) is the correct
choice — the standard, best-supported audio path on NetBSD for
Qt/GTK desktop applications. No group membership changes needed; 
`/dev/audio*` devices are world-accessible by default on NetBSD (no
`audio` group exists).

This hardware has two audio devices; only one is the real
speakers/headphone jack:

```sh
audiocfg list
```

```
0: [ ] audio0 @ hdafg0: Intel HDMI/DP        (playback only — external display audio)
1: [*] audio1 @ hdafg1: Realtek ALC292       (real speakers + mic — set this default)
```

```sh
audiocfg default 1
pulseaudio --kill && pulseaudio --start
```

`audiocfg` 's selection does **not** persist across reboots on its own
(no backing config file — confirmed via `man audiocfg` , no relevant
`sysctl` node). Make it persistent via `/etc/rc.local` :

```sh
cat > /etc/rc.local << 'EOF'
#!/bin/sh
audiocfg default 1
EOF
chmod +x /etc/rc.local
echo 'rc_local=YES' >> /etc/rc.conf
```

### Quick troubleshooting reference (dual-boot/UEFI specific)

| Symptom | Likely cause | Fix |
|---|---|---|
| USB stick invisible/unselectable in UEFI boot menu | Wrong image variant ( `bios-install` ), bad/corrupted write, or ThinkPad `USB UEFI BIOS Support` disabled | Verify with `gdisk -l` ; check that BIOS setting |
| UEFI USB boot menu entry exists but selecting it just returns to the menu | `USB 3.0 Mode` set to `Auto` on older ThinkPad firmware | Set to `Disabled` in `Config → USB` |
| `boot <device>:netbsd` fails "device not configured" from `boot.cfg` , but works interactively at the `>` prompt with a different device string | Wedge ( `dkN` ) numbering differs between the bootloader's own view and the running OS's view; `boot.cfg` was written with the OS-level device name instead of the loader's `hd0<letter>` name | Verify the correct letter interactively ( `ls hd0a:/` , `ls hd0b:/` , ...) before writing `boot.cfg` |
| Wrong OS boots by default after installing a second OS | Second installer's sysinst automatically moved the `bootme` GPT attribute to its own partition | `gpt set -i <index> -a bootme wd0` on the partition you actually want default |
| NetBSD 10 boot hangs with ACPI "workqueue busy" messages and max fan speed | Intermittent NetBSD 10.1 `i915drmkms` driver bug on this Intel HD 4400 hardware | `userconf disable i915drmkms*` at the boot prompt, once, for that boot only — see recovery procedure above |
| Console/X session font tiny and/or display stretched oddly | `i915drmkms` disabled (intentionally or from a prior recovery boot), console running on fallback `genfb` at `1024x768` on a `1600x900` panel | Reboot normally without disabling i915, if the freeze doesn't recur |
