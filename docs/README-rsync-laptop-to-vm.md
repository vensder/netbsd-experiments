# Syncing built pkgsrc packages: laptop ↔ PC's NetBSD VM (via jump host)

Short reference for pushing/pulling locally-built `.tgz` binary
packages between the laptop and the NetBSD VM running on the PC,
reusing the PC itself as an SSH jump host (`ProxyJump`).

**Prerequisite: matching NetBSD release + architecture on both ends.**
Binary packages aren't portable across releases (e.g. a 10.1 build
won't reliably install on 11.0) or architectures. Confirm both sides
match before syncing anything:
```sh
uname -rm
```
Run on both the laptop (or whichever OS partition built/will install
the package) and the VM — they must agree.

---

## 1. One-time prerequisites (skip whichever you've already done)

**`rsync` installed on both ends**, and reachable even in a
non-interactive SSH session (NetBSD's `pkgin`-installed binaries under
`/usr/pkg/bin` aren't always guaranteed to be found via a bare `rsync`
call over SSH — pass the explicit path to be safe, as shown in every
command below):
```sh
pkgin install rsync          # on both the laptop and the VM
```

**Package directory owned by your regular user on *both* ends, not
root.** `/usr/pkgsrc/packages/All` ends up root-owned from
`make bin-install` builds run as root, on whichever machine did the
building. This bites you from *either* direction — as the sender
(rsync trying to `chgrp` files it doesn't own) or as the receiver
(`mkstemp ... Permission denied`). Fix it once, on both machines, so
future syncs in either direction just work without `su`/`sudo`:
```sh
su - root
chown -R <your-username>:users /usr/pkgsrc/packages
exit
```
Run this on the laptop **and** on the VM.

**Belt-and-braces: always sync with `--no-owner --no-group`.** Even
with the ownership fix above, it's worth never asking `rsync` to
preserve exact uid/gid across two different machines in the first
place — for a package binary cache, only the file *contents* matter,
not who technically owns the file. Every example command below
includes this.

**SSH config**, `~/.ssh/config`, as your regular user — **not** root.
SSH config is per-user; root has its own separate home directory and
won't see a config you set up for another user, which is why running
these commands via `su - root` typically fails with a hostname
resolution error even when everything works fine as your normal user.

On the laptop, `~/.ssh/config`:
```
Host pc-host
    HostName 192.168.1.9        # the PC's actual LAN IP
    User vensder

Host pkgsrc-vm
    HostName 192.168.122.XXX    # the VM's internal libvirt IP
    User vensder
    ProxyJump pc-host
```

Confirm key-based (passwordless) access works before attempting the
sync:
```sh
ssh pkgsrc-vm "echo ok"
```
Should print `ok` immediately, no password prompt.

---

## 2. Laptop → VM

Push the whole local package repository in one go:
```sh
rsync -av --no-owner --no-group -e ssh --rsync-path=/usr/pkg/bin/rsync \
    /usr/pkgsrc/packages/All/ pkgsrc-vm:/usr/pkgsrc/packages/All/
```

Or just specific packages (faster for a single new build):
```sh
rsync -av --no-owner --no-group -e ssh --rsync-path=/usr/pkg/bin/rsync \
    /usr/pkgsrc/packages/All/chromium-*.tgz pkgsrc-vm:/usr/pkgsrc/packages/All/
```

`ssh`'s `ProxyJump` handling means this one `rsync` command
transparently tunnels through the PC — no separate copy-to-PC-then-
copy-to-VM step needed.

If this is the first sync to a fresh VM, create the destination
first (`rsync` won't create missing parent directories on its own
with a trailing-slash source):
```sh
ssh pkgsrc-vm "mkdir -p /usr/pkgsrc/packages/All"
```

---

## 3. VM → laptop

Same pattern, reversed — this is what was used earlier in this
project to ship the Plasma6/KDE builds from the VM to the laptop, and
more recently the overnight Chromium build:
```sh
rsync -av --no-owner --no-group -e ssh --rsync-path=/usr/pkg/bin/rsync \
    pkgsrc-vm:/usr/pkgsrc/packages/All/ /usr/pkgsrc/packages/All/
```

---

## 4. Installing after a sync — worked example: Chromium, VM → laptop

Full walkthrough, using the actual Chromium build synced from the VM
as the example.

**a. Pull the package(s) from the VM** (from the laptop):
```sh
rsync -av --no-owner --no-group -e ssh --rsync-path=/usr/pkg/bin/rsync \
    pkgsrc-vm:/usr/pkgsrc/packages/All/ /usr/pkgsrc/packages/All/
```

**b. Confirm it arrived:**
```sh
ls /usr/pkgsrc/packages/All/chromium-*
```

**c. Install, with a `PKG_PATH` fallback to the CDN for ordinary
dependencies** — Chromium pulled in several other packages during its
own build (`nodejs`, `libcares`, `pkgconf`, `x11-links`, etc.); most
of those are likely available as regular binaries from the CDN and
don't need to have been individually synced, only the packages that
specifically needed a custom/WIP build (`chromium`, `carla`, `ibus`,
the bumped `libcares`) do:
```sh
export PKG_PATH="/usr/pkgsrc/packages/All;https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/10.1/All"
pkg_add -I chromium-*
```
(Adjust the release/arch segment of the CDN URL to match your actual
system — see the main project's `mk.conf`/`BINPKG_SITES` setup.)

Remember: `PKG_PATH` should only be exported for this one-off
`pkg_add` command/session — don't persist it to `.profile` (it
conflicts with `bmake` builds; see the main project README for why).

**d. Verify:**
```sh
pkg_info | grep chromium
```
```
chromium-151.0.7922.108 Open source web browser
```

**e. First launch — check for missing runtime dependencies** before
assuming it's broken if it doesn't start cleanly:
```sh
chromium
```
If it fails to launch, check for a dynamic-linking error first:
```sh
ldd /usr/pkg/bin/chromium | grep -i 'not found'
```
Any `not found` entries are shared libraries the binary needs that
aren't installed on the laptop yet (plausible if the laptop's package
set has drifted from the VM's build environment) — install the
missing ones the same way, via `pkgin install <libname>` or by
syncing the specific `.tgz` from the VM if it's a custom-built one.

**f. Confirm hardware acceleration status**, given the DRM/GL
permission issue found earlier in this project — worth checking this
isn't silently falling back to software rendering:
- In Chromium: `chrome://gpu`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `rsync` hangs or asks for a password | SSH key/ProxyJump not set up correctly | Confirm `ssh pkgsrc-vm "echo ok"` works passwordless first |
| `sh: rsync: not found` (remote side) | `rsync` not installed on the other machine, and/or not on the non-interactive SSH session's `PATH` even if installed | Install it on both ends: `pkgin install rsync`; pass `--rsync-path=/usr/pkg/bin/rsync` explicitly (all examples above already do) |
| `chgrp ... Operation not permitted` (sending side) | Local user isn't the owner of the source files (root-built packages) | One-time fix on the **sending** machine: `su - root` then `chown -R <user>:users /usr/pkgsrc/packages` |
| `mkstemp ... Permission denied` (receiving side) | Destination directory on the **other** machine is root-owned | One-time fix on the **receiving** machine: same `chown` as above, run there too |
| Either of the above, recurring | Not using `--no-owner --no-group` | Add both flags — sidesteps needing matching ownership on both ends at all |
| `pkg_add` can't find the package | Wrong `PKG_PATH`, or the file never actually landed in `/usr/pkgsrc/packages/All` | `ls /usr/pkgsrc/packages/All/ | grep <pkgname>` to confirm the file is actually there first |
| Package installs but immediately fails at runtime | Release/arch mismatch between build machine and target | Re-check `uname -rm` on both; rebuild on a matching release if they differ |
| Installed app won't launch, no obvious error | Missing runtime shared-library dependency | `ldd /usr/pkg/bin/<binary> | grep 'not found'`, install/sync whatever's missing |
| `rsync: mkdir failed` | Destination directory doesn't exist yet on a fresh VM | `ssh pkgsrc-vm "mkdir -p /usr/pkgsrc/packages/All"` first |
| `ssh: Could not resolve hostname pkgsrc-vm` | Running as a different user than the one whose `~/.ssh/config` has the `pkgsrc-vm`/`ProxyJump` entries (e.g. switched to `su - root`, which has its own separate home/config) | Use the user whose `~/.ssh/config` is actually set up — don't assume root inherits it |
