# Recovering the NetBSD EFI System Partition (without rebooting)

Guide for a ThinkPad T440s with two NetBSD installs (10.1 and 11) on one GPT disk.
Covers restoring the EFI System Partition (ESP) after it was formatted or deleted,
from the still-running system, plus a shared boot menu on the ESP.

**Do not reboot until the bootloader is back on the ESP.**
Without it, the firmware has nothing to boot.

---

## 1. Disk layout (this machine)

```
$ sudo gpt show wd0
      start       size  index  contents
          0          1         PMBR
          1          1         Pri GPT header
          2         32         Pri GPT table
         34       2014         Unused
       2048     262144      1  GPT part - EFI System
     264192  230422528      2  GPT part - NetBSD FFSv1/FFSv2
  230686720       2048         Unused
  230688768  247461888      3  GPT part - NetBSD FFSv1/FFSv2
  478150656       2048         Unused
  478152704   21965455      4  GPT part - NetBSD swap
  500118159         32         Sec GPT table
  500118191          1         Sec GPT header

$ sudo dkctl wd0 listwedges
dk0: ... 262144 blocks at 2048,      type: msdos   (ESP, 128 MB)
dk1: ... 230422528 blocks at 264192, type: ffs     (NetBSD 10.1 root)
dk2: ... 247461888 blocks at 230688768, type: ffs  (NetBSD 11 root)
dk3: ... 21965455 blocks at 478152704, type: swap
```

| Wedge | GPT index | Boot loader name | Contents        |
|-------|-----------|------------------|-----------------|
| dk0   | 1         | hd0a             | EFI System (FAT) |
| dk1   | 2         | hd0b             | NetBSD 10.1     |
| dk2   | 3         | hd0c             | NetBSD 11       |
| dk3   | 4         | -                | swap            |

Check which install is running:

```sh
mount | grep ' on / '
```

---

## 2. How this happened (and how to avoid it)

While formatting an SD card (`ld0`), `newfs_msdos` was run against `/dev/rdk0`
assuming it was the card. It was the ESP on `wd0`.

Lesson: **`dkN` numbers are global, not per-disk.** Before writing to any `dkN`,
check which disk it belongs to:

```sh
sudo dkctl dk0 getwedgeinfo
# dk0 at wd0: ...   <- internal disk, not the SD card
```

---

## 3. Recovery

### Case A: ESP was reformatted (partition entry still exists)

Skip to step 3.3 if the filesystem is already FAT and mountable but empty.
Otherwise recreate the filesystem first:

```sh
sudo newfs_msdos -F 32 /dev/rdk0
```

### Case B: ESP partition entry was deleted from the GPT

Recreate it at the same position and size (values from `gpt show` above),
then create wedges and the filesystem:

```sh
sudo gpt add -i 1 -b 2048 -s 262144 -t efi -l "EFI system" wd0
sudo dkctl wd0 makewedges
sudo dkctl wd0 listwedges          # find the new msdos wedge, e.g. dk0
sudo dkctl dk0 getwedgeinfo        # confirm: dk0 at wd0, 262144 blocks at 2048
sudo newfs_msdos -F 32 /dev/rdk0
```

### 3.3 Restore the bootloader

```sh
sudo mount -t msdos /dev/dk0 /mnt
sudo mkdir -p /mnt/EFI/boot
sudo cp /usr/mdec/bootx64.efi /mnt/EFI/boot/
```

`/EFI/boot/bootx64.efi` is the default removable-media path. The ThinkPad
firmware falls back to it automatically, so no NVRAM boot entry is needed.

Keep `/mnt` mounted for the next section.

---

## 4. Shared boot menu on the ESP

The x86 EFI loader reads `esp:/EFI/NetBSD/boot.cfg` first, and only falls back
to `/boot.cfg` on the root partition if it is missing. Putting the menu on the
ESP gives the same menu regardless of which NetBSD partition is "active"
(GPT `bootme` attribute / first bootable FFS partition).

```sh
sudo mkdir -p /mnt/EFI/NetBSD
sudo cp /boot.cfg /mnt/EFI/NetBSD/boot.cfg    # start from the existing menu
sudo vim /mnt/EFI/NetBSD/boot.cfg
```

Contents:

```
menu=Boot NetBSD 10 normally:rndseed hd0b:/var/db/entropy-file;boot hd0b:netbsd
menu=Boot NetBSD 10 single user:rndseed hd0b:/var/db/entropy-file;boot -s hd0b:netbsd
menu=Boot NetBSD 11 normally:rndseed hd0c:/var/db/entropy-file;boot hd0c:netbsd
menu=Boot NetBSD 11 single user:rndseed hd0c:/var/db/entropy-file;boot -s hd0c:netbsd
menu=Drop to boot prompt:prompt
default=1
timeout=5
clear=1
userconf=disable i915drmkms*
```

Notes:

- Each `rndseed` path is prefixed with its own partition (`hd0b:` / `hd0c:`).
  A bare `/var/db/entropy-file` would be read from whichever partition is the
  current default, i.e. the wrong install's seed half the time.
- `hd0b` = GPT index 2 (dk1), `hd0c` = GPT index 3 (dk2). `hd0a` is the ESP.
- "Boot default" entries were dropped: their target depends on the active
  partition, which is what this setup avoids.

Verify and unmount:

```sh
ls -lR /mnt/EFI
# EFI/boot/bootx64.efi
# EFI/NetBSD/boot.cfg
sudo umount /mnt
```

Only now is it safe to reboot.

---

## 5. Optional: choose the default partition

The loader's default partition (used by a plain `boot` at the prompt) is the
first match of: partition with the GPT `bootme` attribute, partition the loader
came from, first bootable filesystem. To make NetBSD 11 (index 3) the default:

```sh
sudo gpt set -a bootme -i 3 wd0
# undo: sudo gpt unset -a bootme -i 3 wd0
```

With the ESP menu this mostly doesn't matter, since every entry names its
partition explicitly.

---

## 6. If it still doesn't boot

- BIOS (F1 at power-on): boot mode must be **UEFI** (not Legacy only), internal
  disk first in the boot order.
- At the loader prompt, boot manually:
  ```
  boot hd0b:netbsd
  boot hd0c:netbsd
  ```
  (`boot dk1:netbsd` / `boot dk2:netbsd` also work.)
- From a NetBSD install USB: drop to a shell and repeat section 3 against the
  internal disk.

---

## 7. Why not GRUB or rEFInd?

Both fit easily in 128 MB, but:

- rEFInd cannot read FFS; it would only chain-load NetBSD's `bootx64.efi`,
  adding a menu layer with no benefit.
- GRUB is awkward to install from NetBSD and replaces a native loader that
  already handles multiple installs via `boot.cfg`.

NetBSD's own `bootx64.efi` plus `EFI/NetBSD/boot.cfg` is the simplest working setup.
