# Shrinking and moving NetBSD FFS (UFS2) partitions on a GPT disk

Guide for resizing NetBSD installs on a GPT/UEFI disk without losing data,
e.g. to free space for another OS. Based on a ThinkPad T440s (238 GiB SSD)
with two NetBSD installs (10.1 and 11) booted by NetBSD efiboot from the ESP.

Core idea: FFSv2 (UFS2) cannot be shrunk in place, so the procedure is
**dump -> shrink/recreate GPT partition -> newfs -> restore**, always working
on a partition from *another* booted NetBSD install (so the target is
unmounted).

## Key facts and pitfalls

- `resize_ffs` can **grow** UFS2, but shrinking fails with
  `resize_ffs: shrinking not supported for ufs2`. Shrinking needs dump/restore.
- GParted cannot resize UFS/FFS. Use NetBSD's `gpt(8)` only.
- **Wedge numbers (`dkN`) change between boots** (e.g. a USB stick attached
  at boot shifts everything). Always run `dkctl wd0 listwedges` after every
  reboot and every `gpt` change, and identify partitions by **start offset**,
  never by `dkN` from memory.
- `gpt remove -i N` / `gpt resize -i N` use **GPT indices**, not `dkN`.
- `/etc/fstab` uses `NAME=<partition GUID>`, so it survives wedge renumbering.
  - `gpt resize` keeps the GUID.
  - `gpt remove -i N` followed by `gpt add -i N` reused the old GUID of that
    slot (verify with `gpt show -i N wd0`). If the GUID changes, update the
    root line in that install's `/etc/fstab`.
  - The GUID printed by `gpt add` (`49f48d5a-b10e-11dc-b99b-0019d1879648`)
    is the **type** GUID for NetBSD FFS, not the partition GUID.
- efiboot's `boot.cfg` refers to partitions by index: `hd0b` = GPT index 2,
  `hd0c` = GPT index 3. Keep the same indices and the boot menu keeps working.
- `installboot` is only for BIOS/legacy boot. Not needed for UEFI boot via
  efiboot.
- Sizes in `gpt` and `resize_ffs -s` are 512-byte sectors:
  `GiB * 2097152 = sectors`. Keep starts aligned to 1 MiB (multiple of 2048).
- A `cp` to a slow USB stick may ignore Ctrl-C (uninterruptible disk I/O).
  Wait for it; do not unplug the stick.
- `rsync file user@host` (no trailing colon) copies **locally** into a file
  named `user@host`. Remote destination needs `user@host:`.

## Example layout

Before:

| Index | Content     | Start     | Size (sectors) | Size      |
|------:|-------------|----------:|---------------:|----------:|
| 1     | ESP         | 2048      | 262144         | 128 MiB   |
| 2     | NetBSD 10.1 | 264192    | 230422528      | 109.9 GiB |
| 3     | NetBSD 11   | 230688768 | 247461888      | 118 GiB   |
| 4     | swap        | 478152704 | 21965455       | 10.5 GiB  |

After (40% / 40% / 20% of the space after the ESP, swap removed):

| Index | Content     | Start     | Size (sectors) | Size      |
|------:|-------------|----------:|---------------:|----------:|
| 1     | ESP         | 2048      | 262144         | 128 MiB   |
| 2     | NetBSD 10.1 | 264192    | 199229440      | 95 GiB    |
| 3     | NetBSD 11   | 199493632 | 199229440      | 95 GiB    |
| -     | free        | 398723072 | 101395087      | ~48.3 GiB |

Computing the split:

```sh
# usable sectors after the ESP = (first sector of Sec GPT table) - (start of p2)
echo $((500118159 - 264192))        # 499853967 (~238.4 GiB)
echo $((95 * 2097152))              # 199229440 = 95 GiB
echo $((264192 + 199229440))        # 199493632 = start of p3 (1 MiB aligned)
```

## 0. Free space first

Smaller filesystems dump and restore faster.

```sh
sudo du -x -k -d 1 / | sort -n | tail
sudo du -x -k -d 1 /usr /var | sort -n | tail -15
sudo du -x -k -d 2 /usr/pkg | sort -n | tail -15
```

Typical candidates:

| Path                     | Notes                                         |
|--------------------------|-----------------------------------------------|
| `/usr/pkgsrc`            | whole tree can be re-fetched later (incl. wip) |
| `/usr/pkgsrc/*/*/work`   | build work dirs                               |
| `/var/db/pkgin/cache`    | downloaded binary packages (`pkgin clean`)    |
| `/var/chroot`            | old sandboxes/chroots (check for mounts first) |
| `/var/crash`             | kernel crash dumps                            |
| `/usr/src`, `/usr/xsrc`, `/usr/obj` | system source/build trees          |

Do not delete files under `/usr/pkg` by hand; use `pkgin remove` /
`pkgin autoremove` from the running install.

Find big files and VM images:

```sh
sudo find / -xdev -type f -size +2097152 -exec ls -lh {} +    # >= 1 GiB
sudo find / -xdev -type f \( -iname '*.iso' -o -iname '*.img' -o -iname '*.qcow2' \
    -o -iname '*.raw' -o -iname '*.vdi' -o -iname '*.vmdk' \) -exec ls -lh {} +
```

## 1. Record the current state

Save this output somewhere off the machine.

```sh
sudo gpt show -l wd0
sudo dkctl wd0 listwedges
cat /etc/fstab
swapctl -l

sudo mount -t msdos /dev/dkESP /mnt      # ESP wedge from listwedges
find /mnt -type f
cat /mnt/EFI/NetBSD/boot.cfg
sudo umount /mnt
```

Also check the other install's fstab (mount its wedge read-only):

```sh
sudo mount -r /dev/dkOTHER /mnt && cat /mnt/etc/fstab && sudo umount /mnt
```

## 2. Prepare the USB backup stick (FFS)

FAT32 cannot hold files > 4 GiB. Use FFS. **This erases the stick** - confirm
the device name with `dmesg | tail` (USB = `sdN`, internal SATA = `wd0`).

```sh
sudo dd if=/dev/zero of=/dev/rsd0d bs=1m count=8     # wipe old ISO/hybrid layout
sudo gpt create -f sd0
sudo gpt add -a 1m -t ffs -l backup sd0
sudo dkctl sd0 listwedges                           # note dkN
sudo newfs -O 2 /dev/rdkN
sudo mkdir -p /backup
```

Back up the ESP too:

```sh
sudo mount /dev/dkUSB /backup
sudo mount -t msdos /dev/dkESP /mnt
sudo cp -Rp /mnt /backup/esp-copy
sudo umount /mnt
```

## 3. Disable swap (if removing the swap partition)

In **both** installs' `/etc/fstab`, comment out the swap line:

```
#NAME=<swap-guid>   none   swap   sw,dp   0 0
```

Then in the running system:

```sh
sudo swapctl -d /dev/dkSWAP
swapctl -l                  # "no swap devices configured"
```

## 4. Shrink partition A (index 2), working from install B

Boot install B. Find A's wedge by its start offset (264192 here) and call it
`dkA`.

### 4.1 Dump

```sh
sudo dkctl wd0 listwedges
mount | grep dkA                                    # must print nothing
sudo fsck -f /dev/rdkA
sudo dump -0 -a -f /home/$USER/pA.dump /dev/rdkA
restore -t -f /home/$USER/pA.dump | tail            # sanity check
```

### 4.2 Off-disk copy (compressed, resumable, verified)

```sh
gzip -1 -c /home/$USER/pA.dump > /home/$USER/pA.dump.gz
gzip -t /home/$USER/pA.dump.gz

sudo mount /dev/dkUSB /backup
sudo rsync --partial --progress /home/$USER/pA.dump.gz /backup/
sync
cksum -a sha256 /home/$USER/pA.dump.gz /backup/pA.dump.gz   # must match
sudo umount /backup
```

Alternative over the network (re-run the same command to resume):

```sh
nohup rsync --partial --progress /home/$USER/pA.dump.gz user@host: > rsync.log 2>&1 &
```

### 4.3 Shrink, newfs, restore

```sh
sudo gpt resize -i 2 -s 199229440 wd0               # keeps start and GUID
sudo dkctl wd0 listwedges                           # verify new size; reboot B if not updated
sudo newfs -O 2 /dev/rdkA
sudo mount /dev/dkA /mnt
cd /mnt && sudo restore -r -f /home/$USER/pA.dump
sudo rm restoresymtable
cd / && sudo umount /mnt
sudo fsck -f /dev/rdkA
```

### 4.4 Verify before reboot

```sh
sudo mount -r /dev/dkA /mnt
df -h /mnt
ls -l /mnt/netbsd
grep ' / ' /mnt/etc/fstab           # NAME=<A's GUID>, unchanged by gpt resize
sudo umount /mnt
```

Reboot into A and check `df -h /` and `dmesg | grep -iE 'error|fail'`.

## 5. Move and shrink partition B (index 3), working from install A

Boot install A. Re-check wedges (`dkB` = wedge at B's old start offset).

### 5.1 Clean up B and dump it

Remove the A dumps from B's home first, so they are not dumped again:

```sh
sudo dkctl wd0 listwedges
sudo mount /dev/dkB /mnt
sudo rm -f /mnt/home/$USER/pA.dump /mnt/home/$USER/pA.dump.gz
grep ' / ' /mnt/etc/fstab           # note B's root GUID
sudo umount /mnt

sudo fsck -f /dev/rdkB
sudo dump -0 -a -f /home/$USER/pB.dump /dev/rdkB
restore -t -f /home/$USER/pB.dump | tail
```

Make the off-disk copy exactly as in 4.2 (with `pB.dump`).

### 5.2 Recreate B right after A

```sh
swapctl -l                          # no swap devices
mount | grep -E 'dkB|dkSWAP'        # nothing

sudo gpt remove -i 4 wd0            # swap partition
sudo gpt remove -i 3 wd0
sudo gpt add -i 3 -b 199493632 -s 199229440 -t ffs wd0
sudo gpt show wd0
sudo gpt show -i 3 wd0              # check the partition GUID
sudo dkctl wd0 listwedges           # new wedge for index 3; makewedges if not refreshed
```

### 5.3 newfs, restore, fstab

```sh
sudo newfs -O 2 /dev/rdkB
sudo mount /dev/dkB /mnt
cd /mnt && sudo restore -r -f /home/$USER/pB.dump
sudo rm restoresymtable
grep ' / ' /mnt/etc/fstab
```

If the partition GUID changed, edit the root line to the new GUID:

```sh
sudo vim /mnt/etc/fstab
```

Then:

```sh
cd / && sudo umount /mnt
sudo fsck -f /dev/rdkB
```

Reboot into B via the `hd0c` menu entry and check `df -h /` and `dmesg`.
If root mount fails (wrong GUID): in single user, `mount -u /`, fix
`/etc/fstab`, reboot.

### 5.4 Cleanup

After both installs boot and have been used for a while:

```sh
rm /home/$USER/pB.dump /home/$USER/pB.dump.gz
```

Remove the USB copies later.

## 6. Growing a partition later

UFS2 can be grown in place: first grow the partition, then the filesystem.
The space must be directly after the partition.

```sh
sudo gpt resize -i N -s <new-sectors> wd0           # or omit -s to fill free space
sudo dkctl wd0 listwedges
sudo fsck -f /dev/rdkN
sudo resize_ffs -p -v /dev/rdkN                     # grows to the partition size
sudo fsck -f /dev/rdkN
```

## 7. Adding Linux (Fedora Silverblue) in the free space

- Reuse the existing ESP: mount it at `/boot/efi`, **do not format** it.
  128 MiB is enough for shim + GRUB.
- Create in the free space: `/boot` ext4 (~2 GiB) and `/` btrfs (rest).
  Silverblue's read-only tree is an ostree deployment inside the btrfs root,
  not a separate partition. No swap partition needed (zram).
- Back up the ESP again right before installing.
- Booting: Fedora adds its own UEFI entry; choose NetBSD or Fedora from the
  firmware boot menu (F12 on ThinkPads). Optionally install rEFInd
  (maintained successor of rEFIt) into `EFI/refind/`, not `EFI/BOOT/`, and
  have it chainload `EFI/fedora/shimx64.efi` for Fedora.
- Secure Boot stays off (NetBSD efiboot is unsigned).

## 8. After the move

- Re-fetch pkgsrc (and wip) if it was deleted to save space.
- Re-create swap as a file if needed:

```sh
sudo dd if=/dev/zero of=/swapfile bs=1m count=4096
sudo chmod 600 /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo swapctl -A
```
