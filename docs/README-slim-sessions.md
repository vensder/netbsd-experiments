# SLiM with several sessions on NetBSD 11

SLiM (pkgsrc slim-1.4.0) offers several X11 sessions from one list in
slim.conf. Press F1 on the login screen to cycle through them; the
current name is shown briefly. Tested on NetBSD 11.0 with LXQt 2.4.

Files in this folder:

- slim-sessions.md: this guide
- xinitrc: ~/.xinitrc that starts the chosen session
- rc.conf.d-slim: /etc/rc.conf.d/slim, re-attaches the keyboard

## Contents

1. Wayland and SLiM
2. Virtual terminals
3. slim.conf
4. ~/.xinitrc
5. Test
6. Enable at boot
7. Troubleshooting

## 1. Wayland and SLiM

A native Wayland session cannot be started from SLiM. SLiM starts the
X server first, the user logs in on that X server, and the session
runs as an X client on the same VT while X keeps running:

- X holds /dev/dri/card0 as DRM master, so labwc cannot take it over.
- SLiM never allocates a VT for a session, so it does not avoid the
  seatd VT off-by-one (SDDM guide, section 9.1).
- labwc nested in an X window (wlroots X11 backend) would work, but it
  is Wayland inside X with no benefit over the X11 session.

Start LXQt Wayland by hand from ttyE1 with ~/wayland.sh (SDDM guide,
sections 9.2 to 9.4), with SLiM stopped.

### 1.1 Keyboard after a Wayland session

The Wayland session (labwc/libinput via seatd) opens the keyboard
directly, which detaches wskbd0 from the keyboard mux (wsmux 1,
/dev/wskbd), and it is not re-attached when the session ends. The next
X server then gets garbage keyboard input (keys repeat as "]]]]"), VT
switching hangs ("usl_detachtimeout: not detaching" in dmesg), and a
key press can drop into the kernel debugger (db>, see below).
Restarting SLiM or X does not clear it.

Check, as root:

```sh
wsmuxctl -f 1 -l              # healthy: prints wskbd0; broken: empty
wsconsctl -k type encoding    # healthy: pc-xt / us; broken: unknown_0
```

Fix, as root, before starting X:

```sh
wsmuxctl -f 1 -a wskbd0
```

("Device busy" means it is already attached.) To do this
automatically whenever SLiM starts, install the hook from this folder:

```sh
cp rc.conf.d-slim /etc/rc.conf.d/slim
```

/etc/rc.d/slim reads /etc/rc.conf.d/slim and runs `slim_fixkbd` before
starting SLiM (also for `onestart`). Do not do the same for SDDM: its
rc.d script already uses start_precmd.

The db> prompt is not a crash. The backtrace is breakpoint() called
from wskbd_translate(): that is the kernel debugger hotkey
(Ctrl+Alt+Esc), triggered because the keyboard state is stuck. At db>
type `c` to continue. To disable the hotkey (recommended on a desktop),
add to /etc/sysctl.conf and run it once:

```sh
sysctl -w ddb.fromconsole=0
```

```
ddb.fromconsole=0
```

## 2. Virtual terminals

SLiM's X server runs on vt05 = /dev/ttyE4, the same free screen SDDM
uses. /etc/wscons.conf must create screens 1 to 4 only:

```sh
grep '^screen' /etc/wscons.conf
```

```
screen  1       -       vt100
screen  2       -       vt100
screen  3       -       vt100
screen  4       -       -
```

/etc/ttys: gettys on constty and ttyE1 to ttyE3 only; ttyE4 has no
getty line (or it is "off").

WARNING: do not keep the extra screens 5 and 6 from the SDDM Wayland
experiment (SDDM guide, section 9.5). With them, the SLiM greeter
appeared, random letters were typed into the login box by themselves,
then the machine froze hard (no VT switching, only a reset helped).
This is the same keyboard (wskbd) problem seen with SDDM Wayland. Check after boot:

```sh
dmesg | grep 'screen . added'   # must stop at screen 4
```

After removing the lines from /etc/wscons.conf, reboot.

## 3. slim.conf

/usr/pkg/etc/slim.conf. Back up first:

```sh
cp -p /usr/pkg/etc/slim.conf /usr/pkg/etc/slim.conf.orig
vim /usr/pkg/etc/slim.conf
```

Lines that differ from the shipped example
(/usr/pkg/share/examples/slim/slim.conf):

```
login_cmd           exec /bin/sh - ~/.xinitrc %session > ~/.xsession-errors 2>&1
sessions            lxqt,xfce4,lxde,icewm,wmaker,blackbox,awesome,openbox,ctwm,twm
session_msg         Session:
```

The default login_cmd (/etc/X11/xdm/Xsession) ignores the session
choice, so it must be commented out. The first entry in `sessions` is
the default. Keep these shipped values:

```
default_xserver     /usr/X11R7/bin/X
xserver_arguments   vt05 -noretro -nolisten tcp
lockfile            /var/run/slim.pid
logfile             /var/log/slim.log
```

## 4. ~/.xinitrc

SLiM passes the chosen session name as $1. Every name in `sessions`
needs a matching `case` entry; unknown names start DEFAULT_SESSION.
Check which session commands are installed:

```sh
for c in startlxqt startxfce4 startlxde startplasma-x11 icewm-session \
         wmaker blackbox awesome openbox ctwm twm; do
	printf '%-16s ' $c; command -v $c || echo MISSING
done
```

Remove MISSING ones from both `sessions` and the `case` block
(e.g. plasmax11: only plasma6 wallpapers were installed, no
startplasma-x11). Install as the desktop user:

```sh
cp xinitrc ~/.xinitrc
chmod 755 ~/.xinitrc
```

```sh
#!/bin/sh
#
# ~/.xinitrc for SLiM (login_cmd passes the chosen session as $1).
# Matching line in /usr/pkg/etc/slim.conf:
# sessions lxqt,xfce4,lxde,icewm,wmaker,blackbox,awesome,openbox,ctwm,twm

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

export XDG_DATA_DIRS="/usr/pkg/share:/usr/X11R7/share:/usr/share"
export XDG_CONFIG_DIRS="/usr/pkg/etc/xdg:/etc/xdg"
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

DEFAULT_SESSION=twm

case "$1" in
lxqt)
	exec dbus-run-session -- startlxqt
	;;
xfce4)
	exec startxfce4
	;;
lxde)
	exec dbus-run-session -- startlxde
	;;
icewm)
	exec icewm-session
	;;
wmaker)
	exec wmaker
	;;
blackbox)
	exec blackbox
	;;
awesome)
	exec awesome
	;;
openbox)
	exec openbox-session
	;;
ctwm)
	exec ctwm
	;;
*)
	exec "$DEFAULT_SESSION"
	;;
esac
```

Notes:

- LXQt and LXDE run under dbus-run-session so their applets get a
  session bus; startxfce4 starts its own.
- XDG_RUNTIME_DIR here (/tmp/runtime-UID) is separate from the one in
  ~/wayland.sh; that is fine.
- Errors from the session go to ~/.xsession-errors.

## 5. Test

Only one display manager may run on ttyE4. As root, from ttyE1
(Ctrl+Alt+F2) or the console:

```sh
/etc/rc.d/sddm onestop       # if SDDM was started by hand
pgrep -lx X                  # must print nothing
/etc/rc.d/slim onestart
```

On the login screen press F1 to pick a session, then log in.
Stop it again with `/etc/rc.d/slim onestop`.

## 6. Enable at boot

The package installs /etc/rc.d/slim. It runs `slim -d` and uses
/var/run/slim.pid, which matches `lockfile` in slim.conf. It
requires `dbus` in rcorder.

/etc/rc.conf (only one display manager):

```
sddm=NO
slim=YES
dbus=YES
```

## 7. Troubleshooting

- Greeter appears, letters type by themselves ("jjnm]]]]"), VT
  switching does not work, later a db> prompt:
  wskbd0 was detached from the keyboard mux by a Wayland session
  (section 1.1), or extra wscons screens 5/6 are configured
  (section 2).
- Back to the greeter right after login: the session command failed or
  is not installed. Look in ~/.xsession-errors.
- Wrong desktop starts: the name is missing from the `case` block in
  ~/.xinitrc, so DEFAULT_SESSION ran.
- "Server is already active for display 0": SDDM or a stale X is still
  running; see section 5.
- Logs: /var/log/slim.log, /var/log/Xorg.0.log. After a hard reset
  Xorg.0.log may be empty; if X hangs, wait about 10 seconds before
  resetting.
- "slim: unexpected signal 15" in slim.log is a normal stop.
