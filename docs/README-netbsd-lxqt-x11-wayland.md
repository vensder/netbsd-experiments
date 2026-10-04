# LXQt on NetBSD 11 (X11 and Wayland)

Install and configure the LXQt desktop on NetBSD 11 (amd64) with two sessions:

- **X11**: LXQt + Openbox, started with `startx`
- **Wayland**: LXQt + labwc, started with `startlxqtwayland`

Tested on NetBSD 11.0 amd64 with binary packages from the official pkgsrc
repository: lxqt 2.4.0, lxqt-wayland-session 0.4.1, labwc 0.20.2, wlroots 0.20.2,
seatd 0.9.3, xwayland 24.1.

## Prerequisites

- NetBSD 11 installed, with the X11 sets (`xbase xcomp xetc xfont xserver`).
  Check: `ls /usr/X11R7/bin/Xorg`
- `pkgin` configured and working (network, correct clock, `certctl rehash` done).
- A regular (non-root) user for the desktop session.
- For Wayland: a GPU with a working DRM/KMS driver. Check: `ls /dev/dri`
  must show `card0`. Without it only the X11 session is possible.

## 1. Make pkgsrc install rc.d scripts automatically

Packages that ship services (dbus, avahi, ...) only print a note unless
`PKG_RC_D_SCRIPTS=YES` is in the environment at install time. It is read by the
package install scripts, so it belongs in root's environment, not in
`/etc/pkg_install.conf`.

```sh
echo 'export PKG_RC_D_SCRIPTS=YES' >> /root/.profile
export PKG_RC_D_SCRIPTS=YES
```

## 2. Install packages

```sh
pkgin install lxqt openbox obconf-qt lxqt-wayland-session labwc xwayland
```

- `lxqt` - meta-package for the desktop (no window manager included)
- `openbox`, `obconf-qt` - window manager for the X11 session and its settings tool
- `lxqt-wayland-session` - LXQt Wayland session files and `startlxqtwayland`
- `labwc` - Openbox-like wlroots compositor for the Wayland session
- `xwayland` - runs X11-only applications inside the Wayland session

`seatd` is pulled in as a dependency and is started by the Wayland session
script.

If `PKG_RC_D_SCRIPTS` was not set during install, copy the service scripts by
hand:

```sh
ls /usr/pkg/share/examples/rc.d/
cp /usr/pkg/share/examples/rc.d/dbus /etc/rc.d/dbus
chmod 0755 /etc/rc.d/dbus
```

## 3. System services

D-Bus is required by LXQt:

```sh
echo 'dbus=YES' >> /etc/rc.conf
service dbus start
```

Optional mDNS / `.local` discovery:

```sh
cp /usr/pkg/share/examples/rc.d/avahidaemon /etc/rc.d/
echo 'avahidaemon=YES' >> /etc/rc.conf
```

## 4. Virtual terminals (required for Wayland)

seatd must hand a real virtual terminal (`/dev/ttyE1`..`ttyE3`) to the
compositor. Logging in on `/dev/constty` does not work and fails with
`Could not open terminal for VT 1: Device not configured`.

Enable wscons:

```sh
echo 'wscons=YES' >> /etc/rc.conf
sh -n /etc/rc.conf && echo rc.conf OK
```

Turn on gettys for ttyE1..ttyE3 (leave ttyE0 off if `constty` is on, they are
the same screen):

```sh
sed -i.bak -E 's/^(ttyE[123][[:space:]].*wsvt25[[:space:]]+)off/\1on/' /etc/ttys
grep -E '^(constty|ttyE)' /etc/ttys
```

`/etc/wscons.conf` should list screens 1..3 (default):

```sh
grep '^screen' /etc/wscons.conf
```

Reboot. Ctrl-Alt-F2..F4 now give login prompts on ttyE1..ttyE3. Ctrl-Alt-F1
returns to the console.

## 5. Optional: silence the xkb warning

LXQt looks for keyboard layout lists at the Linux path and prints
`grep: /usr/share/X11/xkb/rules/base.lst: No such file or directory`. Harmless;
to fix:

```sh
ln -s /usr/X11R7/lib/X11 /usr/share/X11
```

## 6. X11 session (LXQt + Openbox)

As the desktop user:

```sh
echo 'exec startlxqt' > ~/.xinitrc
mkdir -p ~/.config/lxqt
printf '[General]\nwindow_manager=openbox\n' >> ~/.config/lxqt/session.conf
startx
```

If the window manager is not preset, LXQt asks on first start; choose
`openbox`. It can be changed later in LXQt Session Settings.

Troubleshooting: `/var/log/Xorg.0.log` (graphics driver), `~/.xsession-errors`.

## 7. Wayland session (LXQt + labwc)

NetBSD has no logind, so `XDG_RUNTIME_DIR` must be created by the user. Add to
the desktop user's `~/.profile`:

```sh
export XDG_RUNTIME_DIR=/tmp/$(id -u)-runtime
mkdir -p -m 700 $XDG_RUNTIME_DIR
```

Start from a virtual terminal (not constty, not inside X):

```sh
# Ctrl-Alt-F2, log in as the desktop user
tty                       # must be /dev/ttyE1 (or E2/E3)
startlxqtwayland
```

On first start the session settings dialog opens with an empty compositor
field; set it to `labwc`. The choice is saved for later sessions.

labwc reads Openbox-style themes, so both sessions can share the same look.

## Daily use

| Session | How to start                                  |
|---------|-----------------------------------------------|
| X11     | log in on any console, run `startx`           |
| Wayland | Ctrl-Alt-F2, log in, run `startlxqtwayland`   |

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `dbus does not exist in /etc/rc.d` | rc.d script not copied; see step 2 |
| `Could not open terminal for VT 1: Device not configured` | started from `/dev/constty`; use ttyE1..3 (step 4) |
| `Timeout waiting session to become active` / `Failed to start a DRM session` | same as above, or no DRM device |
| `/dev/dri` missing or empty | no DRM driver for the GPU; Wayland not possible, use X11 |
| `XDG_RUNTIME_DIR` errors | variable unset or directory not mode 700 (step 7) |
| `TERM` is `dumb` / `unknown` on console | set the terminal type in `/etc/ttys` to `wsvt25` |
| X11 starts with no window decorations | no window manager set; install/select `openbox` |

## Reference: rc.conf lines added

```
wscons=YES
dbus=YES
# optional
avahidaemon=YES
```
