# Running 32-bit Windows apps (Wine) on NetBSD 10.1 amd64

## Why this is needed

NetBSD's pkgsrc `emulators/wine` package on amd64 is built **64-bit only**.
It has no netbsd32 multi-arch support, so:

- Genuine 32-bit `.exe` files (`PE32`) fail outright with:
  `err:module:__wine_process_init ... not supported on this system`
- Many "64-bit" installers are actually 32-bit NSIS/InnoSetup stubs that
  unpack 64-bit payloads. These trip Wine's WoW64 compatibility path,
  which fails on this package with:
  `wine: failed to load L"\??\C:\windows\syswow64\ntdll.dll" error c0000135`

There is no supported way to add 32-bit execution to the 64-bit `wine`
package on NetBSD. The working solution is a **separate 32-bit (i386)
chroot sandbox**, built and managed with NetBSD's `sandboxctl`, with its
own native i386 `wine` package installed inside it.

## Important version note

**Use wine 5.0.5, not wine 9.0, inside the i386 sandbox.**

Testing on NetBSD 10.1/i386 found that wine 9.0 (`wine-9.0nb12`) fails to
even load its own core loader:

```
wine: could not load ntdll.so: (null)
```

This happened with PaX MPROTECT correctly disabled, valid ELF binaries,
and no missing library dependencies (`ldd` clean, `dmesg` clean). It
appears to be a real regression or packaging issue specific to that
build on NetBSD. Wine 5.0.5 (`wine-5.0.5nb3`) loads and runs cleanly on
the same system. If a newer working version becomes available later,
test it in a scratch sandbox before relying on it.

## Prerequisites

- NetBSD 10.1 amd64 host with a working X11 session (Xorg already
  running, you are logged in graphically or via `startx`)
- `doas` or `sudo` configured for your user
- Enough disk space for a second NetBSD userland (roughly 1-2 GB)

---

## Part 1 — One-time host setup

### 1.1 Install sandboxctl and required sysctls

```sh
pkgin install sandboxctl
```

Enable at runtime:

```sh
sudo sysctl -w hw.audio0.multiuser=1
sudo sysctl -w vm.user_va0_disable=0
sudo sysctl -w machdep.user_ldt=1
```

Persist across reboots by adding the same three lines (without `sysctl -w`)
to `/etc/sysctl.conf`:

```
hw.audio0.multiuser=1
vm.user_va0_disable=0
machdep.user_ldt=1
```

Note: `machdep.user_ldt` and `vm.user_va0_disable` are also needed for
**native 64-bit** wine on NetBSD 10. If you already run `wine64` on this
host, these may already be set.

### 1.2 Download the i386 release sets

These become the sandbox's root filesystem.

```sh
mkdir -p ~/netbsd-i386/binary/sets
cd ~/netbsd-i386/binary/sets

ftp https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/i386/binary/sets/base.tgz
ftp https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/i386/binary/sets/etc.tgz
ftp https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/i386/binary/sets/xbase.tgz
ftp https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/i386/binary/sets/xetc.tgz
ftp https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/i386/binary/sets/xfont.tgz
```

Match the release number to your host (10.1 here). Mismatched releases
can work but are not guaranteed to.

### 1.3 Configure sandboxctl

Create `/usr/pkg/etc/sandboxctl/wine.conf` (adjust the path in
`NETBSD_RELEASE_RELEASEDIR` to match where you downloaded the sets, and
the username in the path to your own):

```
SANDBOX_TYPE=netbsd-release
SANDBOX_ROOT="/var/chroot/wine-i386"

NETBSD_RELEASE_RELEASEDIR="/home/<youruser>/netbsd-i386"
NETBSD_RELEASE_SETS="base etc xbase xetc xfont"
```

### 1.4 Create the sandbox and the wine user

```sh
sudo sandboxctl -c wine create
sudo sandboxctl -c wine run useradd -m -d /home/wine wine
```

Confirm the user's UID/GID (needed later for host-side file ownership,
since this user only exists inside the sandbox's own `/etc/passwd`):

```sh
sudo sandboxctl -c wine run id wine
```

Typically `uid=1000(wine) gid=100(users)`. Note these numbers if
different on your system — the helper script later assumes 1000/100.

---

## Part 2 — Installing wine inside the sandbox

### 2.1 Enter the sandbox

```sh
sudo sandboxctl -c wine shell
```

You are now root inside the i386 chroot.

### 2.2 Set up pkgin inside the sandbox

```sh
export PKG_PATH=http://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/i386/10.1/All
pkg_add pkgin
pkgin update
```

### 2.3 Install wine 5.0.5 specifically (not the default 9.0)

Check what versions are available:

```sh
pkgin search wine
```

You will typically see both a current version (e.g. `wine-9.0nbN`,
marked `=`) and an older one (e.g. `wine-5.0.5nb3`, marked `>` meaning
"available but not the newest"). Install the older one explicitly with
`pkg_add`, since `pkgin` always prefers the newest:

```sh
pkg_add -r wine-5.0.5nb3
```

If `pkg_add -r` cannot resolve it, find your configured package
repository and fetch it directly:

```sh
cat /usr/pkg/etc/pkgin/repositories.conf
pkg_add http://<repo-url-from-above>/All/wine-5.0.5nb3.tgz
```

### 2.4 (If you installed 9.0 first) remove it before installing 5.0.5

Two wine versions cannot coexist; installing the second will conflict
on files.

```sh
pkgin remove wine
```

then repeat step 2.3.

### 2.5 Give the wine user a permanent DISPLAY

`su -l` does not inherit environment variables like `DISPLAY` from the
parent shell, so set it in the wine user's own profile once:

```sh
echo 'DISPLAY=:0; export DISPLAY' >> /home/wine/.profile
```

Exit the sandbox once done with initial setup:

```sh
exit
```

---

## Part 3 — X11 bridge (letting sandboxed Wine draw windows)

The sandbox is a separate filesystem root with its own `/tmp`, so it
needs its own path to your X server's socket and its own copy of your
X authentication cookie.

### 3.1 Bridge the X11 socket (one-time, survives reboots if `/tmp` is not cleared by your setup — otherwise repeat after reboot)

```sh
sudo mkdir -m 777 -p /var/chroot/wine-i386/tmp/.X11-unix
sudo ln -f /tmp/.X11-unix/X0 /var/chroot/wine-i386/tmp/.X11-unix/X0
sudo chmod 777 /var/chroot/wine-i386/tmp/.X11-unix/X0
```

### 3.2 X11 auth cookie (must be refreshed each login session)

Your X auth cookie changes each time your X session restarts, so this
step is **not** one-time — it is handled by the helper script in Part 4.

Manually, the steps are:

```sh
# on the host, as your normal user (not root)
/usr/X11R7/bin/xauth -f "$HOME/.Xauthority" extract - :0 > /tmp/wine-x0.xauth

# copy into the sandbox and fix ownership
# use numeric uid:gid from step 1.4 (typically 1000:100),
# since the "wine" username/group do not exist on the host
sudo cp /tmp/wine-x0.xauth /var/chroot/wine-i386/home/wine/.Xauthority
sudo chown 1000:100 /var/chroot/wine-i386/home/wine/.Xauthority
sudo chmod 600 /var/chroot/wine-i386/home/wine/.Xauthority
rm -f /tmp/wine-x0.xauth
```

Notes:
- `xauth` lives at `/usr/X11R7/bin/xauth` on NetBSD's base X11 install,
  not in pkgsrc — it may not be on your `$PATH` and `pkgin install
  xauth` will fail with "not available in the repository".
- Run the `xauth extract` step as your **normal logged-in user**, not
  root — root has no valid X auth of its own.
- If the sandbox's `wine` user has a different UID/GID than 1000/100 on
  your system, use `sudo sandboxctl -c wine run id wine` to check.

---

## Part 4 — Daily use

Use `wine32-sandbox.sh` (provided alongside this README) after every
reboot. It re-applies the sysctls and refreshes the X11 auth cookie,
then drops you into the sandbox:

```sh
sh ~/bin/wine32-sandbox.sh
su -l wine
wine <program.exe>
```

Because of the `.profile` change in step 2.5, `DISPLAY` is already set
once you're in as the `wine` user — no manual export needed.

### Copying files into the sandbox

The sandbox cannot see your normal home directory. Copy installers in
before running them:

```sh
sudo cp ~/Downloads/some-installer.exe /var/chroot/wine-i386/home/wine/
sudo chown 1000:100 /var/chroot/wine-i386/home/wine/some-installer.exe
```

---

## Troubleshooting reference

| Symptom | Cause | Fix |
|---|---|---|
| `wine: failed to load ...syswow64\ntdll.dll error c0000135` on native `wine64` | The .exe is actually a 32-bit installer stub; native wine64 has no WoW64 support | Use the i386 sandbox, or find a genuine 64-bit build/portable zip of the app |
| `err:module:import_dll Library SHELL32.dll ... not found` after a prior crash | Stale `wineserver` process holding bad state from an earlier failed launch | `wineserver -k` before retrying |
| `wine: could not load ntdll.so: (null)` inside the sandbox | Bug/regression in wine 9.0 on NetBSD | Use wine 5.0.5 instead |
| `chown: wine: invalid user name` (or `invalid group name`) run from the host | The `wine` user/group only exist inside the sandbox's own passwd/group database | Use numeric UID:GID (e.g. `chown 1000:100`) from the host |
| `xauth: not found` | Ran `xauth` inside the sandbox (not installed there), or it's not on `$PATH` on the host | Use the full host path `/usr/X11R7/bin/xauth`; it ships with base X11, not pkgsrc |
| `xauth: file /tmp/.Xauthority does not exist` | Ran `xauth extract` as root, which has no X auth of its own | Run it as your normal logged-in user instead |
| `Authorization required, but no authorization protocol specified` / `xeyes` fails in sandbox | Auth cookie missing, stale, or wrong ownership | Redo the cookie extract/copy/chown steps in Part 3.2 |
| `err:winediag:nodrv_CreateWindow ... no driver could be loaded` | `$DISPLAY` not set in the current shell (commonly after `su -l`, which does not inherit env vars) | `export DISPLAY=:0`, or rely on the `.profile` fix from step 2.5 |
| `sandboxctl: cannot create .sandbox_lock: permission denied` | Sandbox operations need root | Prefix with `sudo`/`doas` |
| `pkgin: nothing to do` for `xauth` | `xauth` is not a pkgsrc package on NetBSD | It's part of base X11 at `/usr/X11R7/bin/xauth` |

---

## Summary of what's native vs sandboxed

| Task | Where |
|---|---|
| Genuine 64-bit (`PE32+`) Windows apps, portable/zip builds | Native `wine64` on the host |
| 32-bit installers, 32-bit-only apps, anything that trips WoW64 | i386 sandbox, wine 5.0.5 |
