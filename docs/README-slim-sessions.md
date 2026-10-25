# SLiM with several sessions on NetBSD 11

SLiM can offer several X11 sessions from one list in slim.conf. Press F1 on the login screen to cycle through them; the
current name is shown briefly.

## 0. Wayland and SLiM: not viable

SLiM is an X11 display manager. It starts the X server first, the user
logs in on that X server, and the session runs as an X client on the
same VT while X keeps running. Consequences:

- X holds the DRM device (/dev/dri/card0) as DRM master, so labwc
  cannot take it over. A native LXQt Wayland session cannot start
  from SLiM.
- SLiM never allocates a new VT for a session, so it does not avoid
  the seatd VT off-by-one (SDDM guide, section 9.1). The VT is simply
  never handed to seatd at all.
- The only thing possible is labwc nested in an X window (wlroots X11
  backend): Wayland inside X, slower, no DRM, no benefit over the X11
  session. Not included here.

Keep LXQt Wayland as the manual start from ttyE1 with ~/wayland.sh
(SDDM guide, sections 9.2 to 9.4). It works the same whether SDDM,
SLiM or nothing runs on ttyE4.

## 1. How sessions work (slim 1.4.0, pkgsrc)

slim.conf uses the old-style list; the first entry is the default:

```
sessions            lxqt,xfce4,plasmax11,icewm,wmaker,blackbox,ctwm,twm
login_cmd           exec /bin/sh - ~/.xinitrc %session > ~/.xsession-errors 2>&1
xserver_arguments   vt05 -noretro -nolisten tcp
```

SLiM passes the chosen name to ~/.xinitrc as $1, and the `case` block
in ~/.xinitrc starts it. Every name in `sessions` needs a matching
case entry (unknown names fall through to DEFAULT_SESSION).
Keep only installed sessions in the list; check with:

```sh
for c in startlxqt startxfce4 startlxde startplasma-x11 icewm-session \
         wmaker blackbox awesome ctwm twm; do
	printf '%-16s ' $c; command -v $c || echo MISSING
done
```

`vt05` is /dev/ttyE4, the free screen from the SDDM guide, section 4.
Session errors go to ~/.xsession-errors.

## 4. Test

Only one display manager may run on ttyE4. Stop SDDM first:

```sh
/etc/rc.d/sddm onestop
pgrep -lx X                  # must print nothing
```

Run SLiM once in the foreground to see errors:

```sh
/usr/pkg/bin/slim -nodaemon
```

Log in, press F1 before entering the password to pick a session.
Log file: /var/log/slim.log (path set by `logfile` in slim.conf).

## 5. Enable at boot

The package installs /etc/rc.d/slim. It runs `slim -d` (daemon) and
uses /var/run/slim.pid, which matches `lockfile` in slim.conf.

Test it while it is still disabled:

```sh
/etc/rc.d/slim onestart
/etc/rc.d/slim onestop
```

Then in /etc/rc.conf (only one display manager):

```
sddm=NO
slim=YES
```

The script requires `dbus` in rcorder; set `dbus=YES` if LXQt or
Plasma should get the system bus.

## 6. Troubleshooting

- Back to the greeter right away: the session command failed or is
  not installed. Look in ~/.xsession-errors.
- A session starts the wrong desktop: its name is missing from the
  `case` block in ~/.xinitrc, so DEFAULT_SESSION ran.
- "Server is already active for display 0": SDDM or a stale X is still
  running; see section 4.
