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

What was wrong in the generated file:

- `Session=lxqt-session` - must be the .desktop file name, i.e.
  `lxqt.desktop`, or empty. (Harmless while `User=` is empty, since
  autologin is then off, but wrong as soon as you set a user.)
- `InputMethod=qtvirtualkeyboard` - should be empty on a laptop/desktop.

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
