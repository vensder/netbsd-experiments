# SDDM + LXQt on NetBSD 11 (pkgsrc) - setup steps

All commands as root. Keep sshd=YES so you can get back in if the screen
locks up. Lines marked UNSURE are guesses; the check next to them tells you
what is true on your box.

## 0. Checks (done, results on netbsd-shift)

```sh
pkg_info -L sddm | grep -E 'examples|rc.d|dbus'
ls -l /usr/pkg/sbin/daemonize
ls -l /usr/X11R7/bin/X /usr/pkg/bin/X 2>/dev/null
grep sddm /etc/passwd /etc/group
cat /usr/pkg/share/xsessions/lxqt.desktop
```

Findings:

- Example files are in:
  - `/usr/pkg/share/examples/rc.d/sddm`
  - `/usr/pkg/share/examples/pam.d/sddm`, `sddm-autologin`, `sddm-greeter`
  - `/usr/pkg/share/examples/sddm/org.freedesktop.DisplayManager.conf`
- `/usr/pkg/sbin/daemonize` is installed (needed by the rc.d script).
- X is base X: `/usr/X11R7/bin/X -> Xorg`. The default `ServerPath` is
  correct, no change needed.
- The `sddm` user and group exist, home `/var/lib/sddm`, shell nologin.
- `lxqt.desktop` has `Exec=startlxqt`, `TryExec=lxqt-session`.

## 1. Copy the example files into place

pkgsrc does not install these automatically.

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
  (/etc/pam.d/login), so the files work unchanged.
- The D-Bus policy lets only root own org.freedesktop.DisplayManager. The
  system bus only reads policies at start, hence the dbus restart.

## 2. rc.conf

Your rc.conf already has `dbus=YES` and `wscons=YES`, good. Leave
`sddm=NO` for now; switch to YES only after the manual test in step 5
works. That way a broken X setup cannot trap you at boot.

## 3. Make sure there is a getty to wait for

The rc.d script waits up to 60 s for `/usr/libexec/getty` before starting
sddm. Default /etc/ttys has gettys on ttyE0-ttyE3, so this is normally fine.
X will take a free VT. If X fails with a VT error, check that /etc/ttys has
at least one wscons screen *without* a getty (e.g. ttyE4 `off`) and that
/etc/wscons.conf creates it (`screen 4 - vt100`). UNSURE: only needed if
you see a VT error in the logs.

## 4. Fix sddm.conf

Easiest: replace /usr/pkg/etc/sddm.conf with only the settings you change
(everything else falls back to built-in defaults, which are what
--example-config printed). Back up the old one first:

```sh
cp /usr/pkg/etc/sddm.conf /usr/pkg/etc/sddm.conf.orig
vim /usr/pkg/etc/sddm.conf
```

Contents:

```ini
[Autologin]
# Leave both empty for a normal login screen.
# For autologin: User=<your user> and Session=lxqt.desktop
User=
Session=

[General]
DisplayServer=x11
# Was qtvirtualkeyboard: that is an on-screen keyboard for tablets and
# breaks the greeter if the Qt module is not installed.
InputMethod=

[Users]
# pkgsrc creates its system users (sddm, dbus, polkitd, ...) with
# uid >= 1000, so MinimumUid does not filter them. Hide them by shell.
HideShells=/sbin/nologin,/usr/sbin/nologin
```

Keep `DisplayServer=x11`. The sddm daemon always runs as root (it does
PAM logins); `x11-user` only runs the greeter's X server as the sddm user,
which needs extra setup (Xorg.wrap, device permissions) and is not
needed for a normal desktop.

Notes on the generated file (`sddm --example-config`):

- `[Autologin] Session=` is empty by default, which is right. If you turn
  on autologin later, it takes the .desktop file name, i.e.
  `lxqt.desktop` (not `lxqt-session`).
- `InputMethod=qtvirtualkeyboard` is SDDM's built-in default, so you must
  set `InputMethod=` explicitly to turn it off. It is an on-screen
  keyboard for tablets; on a laptop/desktop it is useless at best, and
  can cause greeter warnings or a stray keyboard button.
- `HideShells=` is empty by default; see the `[Users]` block above.

To see only what your own sddm.conf sets (without the comments):

```sh
grep -v '^#' /usr/pkg/etc/sddm.conf | grep .
```

## 5. Test by hand before enabling at boot

Do this from the text console (not over ssh, not from inside X), with no X
server running:

```sh
/etc/rc.d/dbus status || /etc/rc.d/dbus start
mkdir -p /var/lib/sddm && chown sddm:sddm /var/lib/sddm
/usr/pkg/bin/sddm > /var/log/sddm.log 2>&1 &
```

You should get the login screen. Pick "LXQt Desktop" in the session menu
(bottom of the default theme) and log in.

If it fails, look at (from ssh or another console, Ctrl+Alt+F1):

```sh
less /var/log/sddm.log                          # daemon + greeter messages
less /var/log/Xorg.0.log                        # X server (may be Xorg.1.log)
less ~USER/.local/share/sddm/xorg-session.log   # your LXQt session output
```

To stop it: `kill <pid of /usr/pkg/bin/sddm>` (`pkill -x sddm` may not match
on NetBSD; `pkill -f /usr/pkg/bin/sddm` does).

Better: test through the rc.d script, which works while rc.conf still has
sddm=NO (or no sddm line at all) and writes a pidfile so stop works:

```sh
/etc/rc.d/sddm onestart
/etc/rc.d/sddm onestop
```

Plain `stop`/`start` are refused while sddm=NO, and neither form can stop
an sddm you started by hand (no pidfile).

`sddm --test-mode` is less useful than it sounds: it is meant to run the
greeter inside an existing X session (via Xephyr) to preview themes, so it
does not test the real login path. The manual run above does.

## 6. Enable at boot

```sh
vim /etc/rc.conf       # change sddm=NO to sddm=YES
reboot
```

Note: the rc.d script starts sddm through daemonize, which throws away
stderr, so at boot /var/log/sddm.log stays empty. If boot-time start fails
but the manual run works, the difference is almost always PATH or timing;
debug with the manual run.

Recovery if the screen is stuck: ssh in (or Ctrl+Alt+F1), then
`/etc/rc.d/sddm stop` or `pkill -x sddm`, and set sddm=NO.

## 7. LXQt-specific notes

- The session starts through /usr/pkg/share/sddm/scripts/Xsession, which
  sources /etc/profile and ~/.profile, then runs `startlxqt` (the Exec=
  line of lxqt.desktop). PATH comes from `[Users] DefaultPath`, which
  already includes /usr/pkg/bin.
- UNSURE: without systemd there is no per-user D-Bus session bus started
  for you. If LXQt starts but the panel, notifications or power buttons
  complain about D-Bus, add a session that starts one. Use a separate file
  so pkgin upgrades do not overwrite it:

```sh
cp /usr/pkg/share/xsessions/lxqt.desktop \
   /usr/pkg/share/xsessions/lxqt-dbus.desktop
vim /usr/pkg/share/xsessions/lxqt-dbus.desktop
```

  Change these two lines:

```ini
Name=LXQt Desktop (dbus)
Exec=dbus-launch --exit-with-session startlxqt
```

  Then pick "LXQt Desktop (dbus)" in the greeter.
- Shutdown/reboot from the greeter uses /sbin/shutdown as root; that works
  as configured.

## 8. Optional: LXQt Wayland session (LXQt + labwc) from SDDM

This builds on your earlier notes (README-netbsd-lxqt-x11-wayland.md),
where `startlxqtwayland` from ttyE1 worked. The X11 setup above stays the
default; this only adds a second session you can pick in the greeter.

The greeter itself keeps running on X11 (`DisplayServer=x11`). SDDM can
start a Wayland session from an X11 greeter; running the greeter on
Wayland (weston kiosk) is experimental and not needed.

Requirements are the same as for the manual Wayland start:
`/dev/dri/card0` exists, `wscons=YES`, gettys on ttyE1-ttyE3 (you have
these), labwc + lxqt-wayland-session installed. Note: labwc and xwayland
are in the NetBSD 11 binary repo but not in the NetBSD 10.1 one
(`pkgin install labwc` says "not available" there), so this section
needs NetBSD 11. Building from source does not help either: the pkgsrc
wlroots Makefile refuses NetBSD < 11 ("DRM_IOCTL_GET_UNIQUE is not allowed
on render nodes"), and labwc and sway both depend on wlroots. Without labwc the session fails with
`Could not start target: No such file or directory`.

bash users: a login bash reads ~/.bash_profile and then NOT ~/.profile.
If you have ~/.bash_profile, add `. ~/.profile` to it so the
XDG_RUNTIME_DIR lines (8.2) are picked up.

### 8.1 Checks first (please paste the output)

```sh
ls /usr/pkg/share/wayland-sessions/
cat /usr/pkg/share/wayland-sessions/lxqt-wayland.desktop
grep -n seatd "$(which startlxqtwayland)"
ls -l /usr/pkg/bin/seatd /usr/pkg/bin/seatd-launch
ls /usr/pkg/share/examples/rc.d/ | grep -i seat
ls -l /dev/dri
```

Results (netbsd10, 2026-10-24):

- Session file: `lxqt-wayland.desktop`, `Exec=startlxqtwayland`.
- `startlxqtwayland` runs the compositor via `seatd-launch`.
- `/usr/pkg/bin/seatd-launch` is setuid root (`-r-s--x--x root`), so it
  can start its own seatd as a normal user. No rc.d script for seatd
  exists in pkgsrc, and none is needed.
- `/dev/dri/card0` exists (root:wheel 0660; seatd opens it as root).

### 8.2 XDG_RUNTIME_DIR

SDDM only sets XDG_RUNTIME_DIR when logind exists, so on NetBSD it is
unset. The wayland-session script sources ~/.profile for sh/ksh users,
so the lines from your README are enough. In the desktop user's
~/.profile:

```sh
export XDG_RUNTIME_DIR=/tmp/$(id -u)-runtime
mkdir -p -m 700 $XDG_RUNTIME_DIR
```

If your login shell is csh/tcsh, put the equivalent in ~/.login instead
(the script sources that for csh).

### 8.3 seatd

Nothing to set up: `startlxqtwayland` calls the setuid `seatd-launch`,
which starts a private seatd for the session, the same way as in your
manual test.

RESULT (NetBSD 11, 2026-10-24): does NOT work from SDDM. The greeter's
X server runs on /dev/ttyE4 (Xorg.0.log: "Using wscons driver on
/dev/ttyE4"). SDDM then starts the Wayland session on that same VT 5,
seatd cannot open /dev/ttyE4 ("Could not open terminal for VT 5: Device
not configured"), and labwc gives up after 10 s with "Failed to start a
DRM session". SDDM on NetBSD has no way to give the session a fresh VT,
and there is no sddm.conf setting for it.

Working setup: SDDM for X11 (LXQt Desktop). For Wayland, log in on
ttyE1 (Ctrl+Alt+F2) and run `startlxqtwayland`, as in your README.
To hide the broken menu entry, in /usr/pkg/etc/sddm.conf:

```ini
[Wayland]
SessionDir=/nonexistent
```

### 8.4 sddm.conf

Nothing to change. The default `[Wayland] SessionDir` already includes
/usr/pkg/share/wayland-sessions, which is why "LXQt (Wayland)" and labwc
show up in the menu. For autologin into Wayland you would set:

```ini
[Autologin]
User=<your user>
Session=lxqt-wayland.desktop
```

### 8.5 Compositor choice

On first start LXQt asks for the compositor; enter `labwc` as in your
README. To preset it (UNSURE about the key name, the dialog is the safe
way):

```sh
mkdir -p ~/.config/lxqt
printf '[General]\ncompositor=labwc\n' >> ~/.config/lxqt/session.conf
```

### 8.6 Test

```sh
/etc/rc.d/sddm onestart
```

Pick "LXQt (Wayland)", log in. If you get thrown back to the greeter:

```sh
less ~/.local/share/sddm/wayland-session.log   # session + labwc output
less /var/log/sddm.log                         # only for manual runs
```

Typical errors and causes (same as in your README):

- `XDG_RUNTIME_DIR` errors: 8.2 not picked up (wrong shell file).
- `Failed to start a DRM session` / `Could not open terminal for VT`:
  seatd could not get the VT from SDDM (see 8.3 UNSURE note).

### 8.7 Manual Wayland start: issues seen on NetBSD 11 (2026-10-24)

- `socket file found at socket path /var/run/seatd.sock, refusing to
  start`: stale socket from a failed attempt. If `pgrep -lf seatd` shows
  nothing, `sudo rm /var/run/seatd.sock` (a reboot also clears it).
- `Failed to get DRM device: Permission denied` then `renderD0` /
  `Could not initialize renderer`: /dev/dri/card0 was 0640. Fix:
  `sudo chmod 660 /dev/dri/card0` (user must be in wheel).
- Log the session: `startlxqtwayland > $HOME/wayland.log 2>&1`.

Harmless messages once it runs: `/dev/wskbd1..9` and `/dev/wsmouse1..9`
"Device not configured" / "No such file" (wlroots probes all, only the
existing ones are used), tray plugin "X11 only", xkbcomp keysym warnings,
portal not found.

Known limits without logind/ConsoleKit sessions: the polkit agent cannot
register (GUI admin prompts do not work), and the LXQt power, suspend
and hibernate buttons do nothing (no org.freedesktop.login1). Shut down
with `sudo shutdown -p now` from a terminal.
