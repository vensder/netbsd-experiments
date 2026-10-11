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
- Installing Fedora **overwrites `EFI/boot/bootx64.efi`** (the generic
  fallback path) with shim, even when the ESP is not reformatted. Keep the
  NetBSD loader in `EFI/NetBSD/bootx64.efi` and boot it via rEFInd.
  FAT is case-insensitive: `EFI/boot` and `EFI/BOOT` are the same directory.

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

## 7. Installing Fedora Silverblue into the free space

### 7.1 Before installing

- If the USB stick holds the dumps/ESP backups, copy them elsewhere first:
  writing the ISO wipes the stick.
- Back up the ESP from NetBSD (the installer will write to it):

```sh
sudo mount -t msdos /dev/dkESP /mnt
tar -C /mnt -cf /home/$USER/esp-before-fedora.tar .
df -h /mnt                          # shim + GRUB need ~15 MB
sudo umount /mnt
```

- Leave the free space **unallocated**. NetBSD cannot create ext4/btrfs, and
  the installer creates the partitions itself.
- Secure Boot stays off (NetBSD efiboot is unsigned); Fedora boots fine
  without it.

### 7.2 Write the installer ISO (from Linux)

Check the device with `lsblk` first - `dd` overwrites the target.

```sh
sudo dd if=Fedora-Silverblue-ostree-x86_64-XX.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

### 7.3 Advanced (custom) partitioning in the installer

Boot the stick in **UEFI** mode (F12 on ThinkPads). Choose custom/advanced
storage, not automatic.

| Mount point | Device                  | Format              | Size           |
|-------------|-------------------------|---------------------|----------------|
| `/boot/efi` | existing ESP (p1)       | keep existing (efi) | 128 MiB        |
| `/boot`     | new, in free space      | ext4                | 2 GiB          |
| `/`         | new, in free space      | btrfs               | rest (~46 GiB) |

Notes:

- There is no explicit "do not format" option: the existing ESP row shows its
  current format (`efi`). Leave it unchanged; if a "Reformat" checkbox is
  shown, keep it unchecked.
- Warning "/boot/efi partition is less than 500 MB" is only a recommendation.
  Kernels and initramfs go to `/boot`, the ESP only holds shim + GRUB.
- Silverblue's read-only tree is an ostree deployment inside the btrfs root,
  not a separate partition. No swap partition (zram is used).
- Leave the NetBSD partitions unassigned.
- **Before clicking Install**, review the storage summary: only create/format
  of the two new partitions, and mount (no format) of the existing ESP.
  Nothing on the NetBSD partitions.

### 7.4 After installing

- After reboot only GRUB with Fedora is shown (Fedora is first in BootOrder).
- `EFI/boot/bootx64.efi` is now shim (see section 8 to restore NetBSD's
  loader in its own directory).
- To test custom images, install stock Silverblue first, then rebase:

```sh
rpm-ostree rebase ostree-unverified-registry:<registry>/<image>:<tag>
```

Resulting ESP layout:

```
EFI/
  boot/     BOOTIA32.EFI bootx64.efi(=shim) fbia32.efi fbx64.efi
  fedora/   shimx64.efi grubx64.efi mmx64.efi grub.cfg BOOTX64.CSV ...
  NetBSD/   boot.cfg bootx64.efi (restored, section 8)
  refind/   refind_x64.efi refind.conf icons/ (section 9)
```

## 8. Recovering the NetBSD UEFI loader (from Fedora)

### 8.1 Check whether it was overwritten

```sh
sudo sha256sum /boot/efi/EFI/boot/bootx64.efi /boot/efi/EFI/fedora/shimx64.efi
sudo grep -ac NetBSD /boot/efi/EFI/boot/bootx64.efi
```

Same hashes and `0` from grep means the fallback loader is now shim and
NetBSD is unbootable until its loader is restored.

### 8.2 Restore from a NetBSD partition

Every NetBSD install ships its UEFI loader as `/usr/mdec/bootx64.efi`. Use the
newest one (it boots older kernels too). Linux can read UFS2 read-only:

```sh
lsblk -o NAME,SIZE,FSTYPE            # identify the NetBSD partitions
sudo modprobe ufs
sudo mount -t ufs -o ro,ufstype=ufs2 /dev/sda3 /mnt
sudo cp /mnt/usr/mdec/bootx64.efi /boot/efi/EFI/NetBSD/bootx64.efi
sudo umount /mnt
sudo grep -ac NetBSD /boot/efi/EFI/NetBSD/bootx64.efi    # > 0
```

The ESP is mounted root-only under Fedora, so use `sudo` even for reads.

Fallbacks if the `ufs` module is missing:

- `EFI/boot/bootx64.efi` from the ESP backup (`esp-copy`,
  `esp-before-fedora.tar`).
- `bootx64.efi` from the matching NetBSD release sets on cdn.netbsd.org.

Leave `EFI/boot/bootx64.efi` as shim; the fallback path now belongs to
Fedora. NetBSD's loader reads `EFI/NetBSD/boot.cfg`, so the `hd0b`/`hd0c`
menu keeps working.

## 9. Installing and configuring rEFInd (from Fedora)

rEFInd (the maintained successor of rEFIt) lives in its own ESP directory, so
Fedora reinstalls do not touch it. It is not in Fedora's repos; on Silverblue
install the binaries manually.

### 9.1 Copy the files

Download the current `refind-bin-*.zip` from
https://www.rodsbooks.com/refind/getting.html, then:

```sh
unzip refind-bin-*.zip
sudo mkdir -p /boot/efi/EFI/refind
sudo cp refind-bin-*/refind/refind_x64.efi /boot/efi/EFI/refind/
sudo cp -r refind-bin-*/refind/icons /boot/efi/EFI/refind/
sudo df -h /boot/efi
```

Do not install rEFInd as `EFI/boot/bootx64.efi`; Fedora owns that path.

### 9.2 Configuration (manual entries only)

```sh
sudo vim /boot/efi/EFI/refind/refind.conf
```

```
timeout 10
scanfor manual

menuentry "Fedora" {
    icon   /EFI/refind/icons/os_fedora.png
    loader /EFI/fedora/shimx64.efi
}

menuentry "NetBSD" {
    icon   /EFI/refind/icons/os_netbsd.png
    loader /EFI/NetBSD/bootx64.efi
}
```

`scanfor manual` hides the clutter (shim, mm, fb, fallback loader) that
auto-scanning would show. NetBSD opens its own `boot.cfg` menu (10.1 / 11);
Fedora goes shim -> GRUB -> ostree deployments. Paths stay the same across
Fedora reinstalls, so the config never needs changes.

### 9.3 Register in NVRAM

```sh
sudo efibootmgr --create --disk /dev/sda --part 1 \
    --loader '\EFI\refind\refind_x64.efi' --label 'rEFInd'
efibootmgr                          # rEFInd should be first in BootOrder
```

### 9.4 After every Fedora reinstall

The installer puts "Fedora" first again. Restore the order:

```sh
efibootmgr                                  # note entry numbers
sudo efibootmgr -o XXXX,YYYY,...            # rEFInd first
```

Also re-check that `EFI/NetBSD/bootx64.efi` and `EFI/refind/` are intact.
rEFInd is always reachable through the F12 boot menu as well.

## 10. After the move

- Re-fetch pkgsrc (and wip) if it was deleted to save space.
- Re-create swap as a file if needed:

```sh
sudo dd if=/dev/zero of=/swapfile bs=1m count=4096
sudo chmod 600 /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo swapctl -A
```
