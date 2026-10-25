# SDDM and LXQt on NetBSD

Set up the SDDM display manager from pkgsrc to start an LXQt X11 session
on NetBSD, and start an LXQt Wayland session (labwc) by hand from a
virtual terminal.

Tested on NetBSD 11.0 amd64 (X11 and Wayland) and NetBSD 10.1 amd64
(X11 only) with binary packages from the official pkgsrc repository
(sddm 0.21.0, lxqt 2.4, labwc 0.20).

All commands run as root unless noted. Keep `sshd=YES` in /etc/rc.conf
while experimenting, so the machine stays reachable if the screen hangs.

## Contents

1. Requirements
2. Install the example files
3. rc.conf
4. Virtual terminals
5. sddm.conf
6. Test without enabling at boot
7. Enable at boot
8. Notes on the X11 session
9. Wayland session
10. Troubleshooting
11. Known limitations

A script that performs steps 2 and 5 and checks the result is available
as `sddm-setup.sh` (see the end of this document).

## 1. Requirements

- X11 sets installed (`xbase xcomp xetc xfont xserver`); X server at
  `/usr/X11R7/bin/X`.
- Packages:

```sh
pkgin install sddm lxqt openbox daemonize
```

- D-Bus rc.d script present in /etc/rc.d (copy it from
  /usr/pkg/share/examples/rc.d/dbus if missing).

Checks:

```sh
pkg_info -L sddm | grep -E 'examples|rc.d|dbus'
ls -l /usr/pkg/sbin/daemonize
ls -l /usr/X11R7/bin/X /usr/pkg/bin/X 2>/dev/null
grep sddm /etc/passwd /etc/group
cat /usr/pkg/share/xsessions/lxqt.desktop
```

Expected:

- Example files under /usr/pkg/share/examples:
  - `rc.d/sddm`
  - `pam.d/sddm`, `pam.d/sddm-autologin`, `pam.d/sddm-greeter`
  - `sddm/org.freedesktop.DisplayManager.conf`
- `/usr/pkg/sbin/daemonize` exists. The rc.d script depends on it and
  fails silently without it.
- `/usr/X11R7/bin/X` exists (base X). If only `/usr/pkg/bin/X` exists
  (modular Xorg from pkgsrc), set `ServerPath=/usr/pkg/bin/X` in the
  `[X11]` section of sddm.conf.
- User and group `sddm` exist, home `/var/lib/sddm`, shell
  `/sbin/nologin`. The package normally creates them; otherwise:
  `useradd -d /var/lib/sddm -s /sbin/nologin sddm`.
- `lxqt.desktop` contains `Exec=startlxqt`.

## 2. Install the example files

pkgsrc does not install rc.d scripts, PAM files or D-Bus policies
automatically (unless `PKG_RCD_SCRIPTS=YES` was set at install time, and
that covers only rc.d scripts).

```sh
cp /usr/pkg/share/examples/rc.d/sddm /etc/rc.d/sddm
chmod 555 /etc/rc.d/sddm

cp /usr/pkg/share/examples/pam.d/sddm           /etc/pam.d/
cp /usr/pkg/share/examples/pam.d/sddm-autologin /etc/pam.d/
cp /usr/pkg/share/examples/pam.d/sddm-greeter   /etc/pam.d/

cp /usr/pkg/share/examples/sddm/org.freedesktop.DisplayManager.conf \
   /usr/pkg/etc/dbus-1/system.d/

/etc/rc.d/dbus restart
```

Notes:

- pam.d/sddm includes `login`, which exists in base NetBSD
  (/etc/pam.d/login), so the PAM files work unchanged.
- The D-Bus policy allows only root to own
  org.freedesktop.DisplayManager. The system bus reads policies only at
  start, hence the restart.

## 3. rc.conf

Required:

```
dbus=YES
wscons=YES
```

Keep `sddm=NO` (or no sddm line at all) until the test in step 6
succeeds. A broken X setup then cannot block the console at boot.

## 4. Virtual terminals

The rc.d script waits up to 60 seconds for `/usr/libexec/getty` to run
before it starts sddm, and the Wayland session needs a real wscons
screen (ttyE1..ttyE3). The default configuration covers both.

/etc/ttys (relevant lines; the type must be `wsvt25`):

```
console "/usr/libexec/getty Pc"         wsvt25  off secure
constty "/usr/libexec/getty Pc"         wsvt25  on secure
ttyE0   "/usr/libexec/getty Pc"         wsvt25  off secure
ttyE1   "/usr/libexec/getty Pc"         wsvt25  on secure
ttyE2   "/usr/libexec/getty Pc"         wsvt25  on secure
ttyE3   "/usr/libexec/getty Pc"         wsvt25  on secure
```

ttyE0 stays off while constty is on; they are the same screen. After
editing /etc/ttys, `kill -HUP 1` makes init re-read it.

/etc/wscons.conf should create screens 1 to 3, and a free screen for X:

```sh
grep '^screen' /etc/wscons.conf
```

```
screen  1       -       vt100
screen  2       -       vt100
screen  3       -       vt100
screen  4       -       -
```

The SDDM X server runs on the free screen (/dev/ttyE4, VT 5).

## 5. sddm.conf

`sddm --example-config` prints the built-in defaults; it does not read
the existing configuration. A minimal /usr/pkg/etc/sddm.conf that only
overrides what is needed:

```sh
cp /usr/pkg/etc/sddm.conf /usr/pkg/etc/sddm.conf.orig   # if it exists
vim /usr/pkg/etc/sddm.conf
```

```ini
[Autologin]
# Both empty: normal login screen.
# Autologin: User=<login name> and Session=lxqt.desktop
User=
Session=

[General]
DisplayServer=x11
InputMethod=

[Users]
HideShells=/sbin/nologin,/usr/sbin/nologin

[Wayland]
# Hide Wayland sessions from the menu; they do not work from SDDM on
# NetBSD (see section 9).
SessionDir=/nonexistent
```

Why these settings:

- `[Autologin] Session=` takes the name of a .desktop file, e.g.
  `lxqt.desktop`, not a program name. Empty means "last used session".
- `InputMethod` defaults to `qtvirtualkeyboard`, an on-screen keyboard
  for tablets. It must be set to empty explicitly to turn it off.
- pkgsrc creates its system users (sddm, dbus, polkitd, ...) with uid
  1000 or above, so `MinimumUid=1000` does not hide them from the user
  list. They all use the nologin shell, so `HideShells` hides them.
- `DisplayServer=x11` runs the greeter's X server as root. The sddm
  daemon always runs as root, since it authenticates users through PAM.
  `x11-user` only moves the greeter's X server to the sddm user and
  needs extra setup (Xorg.wrap, device permissions); it brings no
  benefit here.

To list only the settings actually present in the file:

```sh
grep -v '^#' /usr/pkg/etc/sddm.conf | grep .
```

## 6. Test without enabling at boot

The `one*` commands of the rc.d script work while rc.conf has
`sddm=NO` or no sddm line. Run from the text console, with no X server
running:

```sh
/etc/rc.d/sddm onestart
```

Choose "LXQt Desktop" in the session menu and log in. SDDM remembers
the last session, so the choice is needed only once.

To stop it:

```sh
/etc/rc.d/sddm onestop
```

Plain `start` and `stop` are refused while `sddm=NO`. An sddm started
by hand (`/usr/pkg/bin/sddm &`) writes no pidfile, so the rc.d script
cannot stop it; use `pkill -f /usr/pkg/bin/sddm` in that case
(`pkill -x sddm` may not match on NetBSD).

To see sddm's own messages, run it by hand once:

```sh
/usr/pkg/bin/sddm > /var/log/sddm.log 2>&1 &
```

`sddm --test-mode` only previews the greeter inside an existing X
session (via Xephyr); it does not test a real login.

## 7. Enable at boot

```sh
vim /etc/rc.conf       # set sddm=YES
reboot
```

The rc.d script starts sddm through daemonize, which discards stderr.
If the boot-time start fails while `onestart` works, debug with the
manual run from step 6.

Recovery when the screen hangs: log in over ssh or switch to a text
console (Ctrl+Alt+F2), run `/etc/rc.d/sddm stop`, and set `sddm=NO`.

## 8. Notes on the X11 session

- SDDM starts the session through /usr/pkg/share/sddm/scripts/Xsession,
  which starts the user's login shell as a login shell and then runs
  the `Exec=` line of the .desktop file (`startlxqt`). PATH comes from
  `[Users] DefaultPath`, which includes /usr/pkg/bin.
- Environment variables belong in the login shell's startup file. For
  bash: a login bash reads only the first of ~/.bash_profile,
  ~/.bash_login, ~/.profile. When ~/.bash_profile exists, add
  `. ~/.profile` to it, otherwise ~/.profile is ignored.
- Window manager: LXQt asks on first start; choose `openbox`. Or preset
  it as the desktop user:

```sh
mkdir -p ~/.config/lxqt
printf '[General]\nwindow_manager=openbox\n' >> ~/.config/lxqt/session.conf
```

- Session log: `~/.local/share/sddm/xorg-session.log`.
- If LXQt applets complain about a missing D-Bus session bus, create a
  second session entry that starts one:

```sh
cp /usr/pkg/share/xsessions/lxqt.desktop \
   /usr/pkg/share/xsessions/lxqt-dbus.desktop
vim /usr/pkg/share/xsessions/lxqt-dbus.desktop
```

```ini
Name=LXQt Desktop (dbus)
Exec=dbus-launch --exit-with-session startlxqt
```

## 9. Wayland session

### 9.1 Not from SDDM

Starting "LXQt (Wayland)" from SDDM does not work on NetBSD. The
greeter's X server holds /dev/ttyE4 (VT 5), SDDM starts the Wayland
session on the same VT, and seatd cannot open it:

```
Could not open terminal for VT 5: Device not configured
Timeout waiting session to become active
Failed to start a DRM session
```

On Linux, logind gives each session a fresh VT; SDDM has no equivalent
on NetBSD, and no sddm.conf setting changes this. Hide the entry with
`[Wayland] SessionDir=/nonexistent` (section 5) and start Wayland by
hand as described below.

Details (NetBSD 11.0, sddm 0.21.0, seatd 0.9.3):

- With screens 0 to 4 in use, SDDM finds no free VT for the Wayland
  session ("Failed to open new VT: Device not configured", "VT -1").
- With an extra screen 5 in /etc/wscons.conf, SDDM picks VT 6
  (/dev/ttyE5) and switches to it, but seatd still fails: on NetBSD,
  seatd maps VT N to /dev/ttyEN instead of /dev/ttyE(N-1)
  (`get_tty_path()` in seatd common/terminal.c), so it opens
  /dev/ttyE6.
- Adding screen 6 as well lets the session start, but the kernel then
  panicked ("fatal breakpoint trap in supervisor mode") when a browser
  was started (backtrace: breakpoint, wskbd_translate, wskbd_input,
  i.e. while handling a key press). The wscons configuration itself is valid (wsconscfg(8):
  up to 8 screens, 0 to 7), so this is most likely a kernel bug
  triggered by the VT mismatch. The exact configuration is in 9.5;
  do not use it for daily work.

### 9.2 Requirements

- NetBSD 11. wlroots (needed by labwc and sway) refuses to build on
  older releases (pkgsrc wayland/wlroots: "DRM_IOCTL_GET_UNIQUE is not
  allowed on render nodes"), and the NetBSD 10.1 binary repository has
  no labwc, sway or xwayland.
- A GPU with a DRM/KMS driver: `/dev/dri/card0` must exist.
- Packages:

```sh
pkgin install lxqt-wayland-session labwc xwayland
```

- The desktop user is in group `wheel`, and the DRM nodes are
  read-write for the group:

```sh
id                       # must list 0(wheel)
ls -l /dev/dri           # card0 and renderD* must be crw-rw----
chmod 660 /dev/dri/card0 # if card0 shows crw-r-----
```

  With a read-only card0 labwc fails with `Failed to get DRM device:
  Permission denied`.
- seatd needs no setup. `startlxqtwayland` runs the compositor through
  `/usr/pkg/bin/seatd-launch`, which is setuid root and starts a
  private seatd for the session. pkgsrc ships no seatd rc.d script.

### 9.3 Start script

NetBSD has no logind, so XDG_RUNTIME_DIR must be created by the user.
As the desktop user, create ~/wayland.sh:

```sh
#!/bin/sh

tty                              # must be /dev/ttyE1..ttyE3
export XDG_RUNTIME_DIR=/tmp/$(id -u)-runtime
mkdir -p -m 700 $XDG_RUNTIME_DIR
startlxqtwayland > $HOME/wayland.log 2>&1
```

```sh
chmod 755 ~/wayland.sh
```

Switch to a virtual terminal (Ctrl+Alt+F2 for ttyE1), log in as the
desktop user and run `~/wayland.sh`. Do not start it from constty, from
inside X, or over ssh.

On first start, `startlxqtwayland` finds no compositor in
~/.config/lxqt/session.conf, starts labwc and opens the session
settings; set the compositor to `labwc` there. The choice is saved, and
the X11 window manager setting is not affected.

### 9.4 How seatd is started

seatd has no configuration file and needs no rc.d service for this
session.

- `/usr/pkg/bin/startlxqtwayland` is a shell script. It reads the
  compositor from `compositor=` in ~/.config/lxqt/session.conf and
  starts it through seatd-launch; for labwc:
  `exec seatd-launch $COMPOSITOR -C $XDG_CONFIG_HOME/labwc -S lxqt-session`.
  Without a configured compositor it falls back to labwc and opens the
  session settings.
- `/usr/pkg/bin/seatd-launch` is setuid root. It starts a private
  `seatd` as root with the socket /var/run/seatd.sock, runs the
  compositor as the calling user, and stops seatd when the compositor
  exits.
- The only settings are environment variables, set before
  `startlxqtwayland` (e.g. in wayland.sh):

```sh
export SEATD_LOGLEVEL=debug      # more detail in the log (default: info)
export LIBSEAT_BACKEND=seatd     # libseat backend used by the compositor
```

- The VT that seatd opens is not configurable; see the off-by-one in
  section 9.1.

See seatd(1), seatd-launch(1) and labwc(1).

### 9.5 Experimental: Wayland session from SDDM

WARNING: this setup lets SDDM start "LXQt (Wayland)", but the kernel
panicked with it on NetBSD 11.0 when typing in a browser (section 9.1).
Use it only for testing, and keep the manual start (9.3) for daily use.

/etc/wscons.conf creates two extra screens:

```
screen  1       -       vt100
screen  2       -       vt100
screen  3       -       vt100
screen  4       -       -
screen  5       -       vt100
screen  6       -       vt100
```

/etc/ttys keeps gettys only on ttyE1 to ttyE3; ttyE4, ttyE5 and ttyE6
must stay without a getty:

```
constty "/usr/libexec/getty Pc"         wsvt25  on secure
ttyE0   "/usr/libexec/getty Pc"         wsvt25  off secure
ttyE1   "/usr/libexec/getty Pc"         wsvt25  on secure
ttyE2   "/usr/libexec/getty Pc"         wsvt25  on secure
ttyE3   "/usr/libexec/getty Pc"         wsvt25  on secure
```

Role of each screen:

| Device | VT | Used by |
|--------|----|---------|
| ttyE0 | 1 | console (constty) |
| ttyE1..ttyE3 | 2..4 | getty logins |
| ttyE4 | 5 | X server of the SDDM greeter |
| ttyE5 | 6 | free VT that SDDM switches to for the Wayland session |
| ttyE6 | 7 | needed only because seatd opens /dev/ttyE6 for VT 6 |

In sddm.conf, remove `SessionDir=/nonexistent` from `[Wayland]` so the
Wayland sessions appear in the menu again.

The screens can be added without a reboot:

```sh
wsconscfg 5
wsconscfg 6
```

`wsconscfg N` reports "screen N is already configured" if it exists.
To return to the stable setup, delete the `screen 5` and `screen 6`
lines from /etc/wscons.conf and reboot.

## 10. Troubleshooting

Logs:

| Log | Content |
|-----|---------|
| /var/log/sddm.log | sddm daemon and greeter (manual run only) |
| /var/log/Xorg.0.log | X server of the greeter / X11 session |
| ~/.local/share/sddm/xorg-session.log | LXQt X11 session |
| ~/.local/share/sddm/wayland-session.log | Wayland session started from SDDM |
| ~/wayland.log | Wayland session started with wayland.sh |

| Symptom | Cause / fix |
|---------|-------------|
| Greeter lists system users | Set `HideShells` (section 5) |
| `/etc/rc.d/sddm stop` does nothing | Use `onestop` while `sddm=NO`; a hand-started sddm has no pidfile |
| Session ends at once, grid and X cursor left on screen | Session program not found; check the session log |
| `Could not start target: No such file or directory` | Compositor (labwc) not installed |
| `Could not open terminal for VT N: Device not configured` | Wayland started from SDDM or constty; use ttyE1..ttyE3 (section 9) |
| `socket file found at socket path /var/run/seatd.sock, refusing to start` | Stale socket from a failed run. If `pgrep -lf seatd` shows nothing: `rm /var/run/seatd.sock` (a reboot also clears it) |
| `Failed to get DRM device: Permission denied`, `Could not initialize renderer` | DRM node permissions (section 9.2) |
| `XDG_RUNTIME_DIR` errors | Variable unset or directory not mode 700 (section 9.3) |
| `grep: /usr/share/X11/xkb/rules/base.lst: No such file or directory` | Harmless; to silence: `ln -s /usr/X11R7/lib/X11 /usr/share/X11` |
| TERM is `dumb` or `unknown` on the console | Terminal type in /etc/ttys must be `wsvt25` |

Harmless messages in a working Wayland session: `/dev/wskbd1..9` and
`/dev/wsmouse1..9` "Device not configured" or "No such file" (wlroots
probes all of them and uses the ones that exist), "tray plugin supports
X11 only", xkbcomp keysym warnings, `org.freedesktop.portal.Desktop`
not provided.

## 11. Known limitations

These come from the lack of logind on NetBSD:

- The polkit authentication agent cannot register ("Cannot register
  authentication agent"), because ConsoleKit has no record of the
  session. GUI prompts for administrator actions do not appear.
  Untested idea: start the session with `ck-launch-session` (from
  ConsoleKit2), e.g. `ck-launch-session startlxqtwayland`, and check
  with `ck-list-sessions`.
- The LXQt power, suspend and hibernate buttons do nothing
  (`org.freedesktop.login1` missing). Shut down from a terminal with
  `shutdown -p now` (as root or via sudo).
- Wayland sessions cannot be started from SDDM (section 9.1).

## Setup script

`sddm-setup.sh` performs steps 2 and 5 and checks the result. It never
overwrites an existing file and never edits /etc/rc.conf. Run as root:

```sh
sh sddm-setup.sh
```

It checks the requirements (stops without changes if one is missing),
installs the example files that are not yet present, creates a minimal
sddm.conf if none exists, restarts dbus if it installed the policy, and
finally prints the relevant settings from rc.conf and sddm.conf with OK
or WARN.
