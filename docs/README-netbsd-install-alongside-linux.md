# NetBSD 11 on a dedicated GPT partition alongside Fedora and Slackware

Real-world notes from installing NetBSD 11 (amd64, UEFI) onto an HP laptop that
already had Fedora 44 and Slackware 15.0 installed, with Fedora's GRUB as the
only boot manager. Ends with NetBSD reachable over SSH on the local Wi-Fi.

Key lesson: do NOT let sysinst touch the partition table on a disk that already
has other OSes. In this case it misread the ESP as a zero-size MSDOS partition,
and deleting that entry removed the real ESP from the GPT. Use sysinst only to
get a shell, and install by hand.

## Disk layout (single NVMe, GPT)

| # | Size      | Type       | GPT label              | Use              |
|---|-----------|------------|------------------------|------------------|
| 1 | 600M      | EFI System | EFI System Partition   | shared ESP       |
| 2 | 2G        | Linux      | -                      | Fedora /boot     |
| 3 | ~101G     | Linux      | -                      | Fedora btrfs     |
| 4 | 70G       | Linux      | slackware              | Slackware ext4   |
| 5 | rest ~65G | NetBSD FFS | netbsd                 | NetBSD /         |

Device names:

| Thing          | Linux            | NetBSD                 |
|----------------|------------------|------------------------|
| NVMe disk      | /dev/nvme0n1     | ld0                    |
| ESP            | /dev/nvme0n1p1   | dk0 (wedge)            |
| NetBSD root    | /dev/nvme0n1p5   | dk4 (wedge, `netbsd`)  |
| USB stick      | /dev/sda         | sd0                    |
| USB Wi-Fi      | -                | run0                   |

ESP filesystem UUID: `1DA5-E71D`. ESP position: start sector 2048,
size 1228800 sectors (1 MiB to 601 MiB).

## 0. Before you start (in Fedora)

Create partition 5 from Fedora (type `a902` = NetBSD FFS, label `netbsd`):

```sh
sudo sgdisk -n 5:0:0 -t 5:a902 -c 5:netbsd /dev/nvme0n1
```

Back up the ESP and the partition table:

```sh
sudo tar -C /boot/efi -czf ~/esp-backup.tgz .
sudo sgdisk --backup=gpt-nvme0n1.bin /dev/nvme0n1
```

Secure Boot must be off (NetBSD's loader is unsigned).

## 1. Installer media

Use the USB image, NOT the DVD ISO. The ISO written to USB boots but then looks
for the kernel on `cd0a` and fails.

```sh
lsblk                                   # confirm the stick is sda
gunzip NetBSD-11.0-amd64-install.img.gz
sudo dd if=NetBSD-11.0-amd64-install.img of=/dev/sda bs=4M status=progress conv=fsync
```

Boot it via F9 (HP boot menu), UEFI USB entry.

## 2. Get a shell, check the disk

In sysinst: Utility menu -> Run /bin/sh. Never accept a partitioning scheme,
and answer No to any "fix the partition table" prompt.

```sh
sysctl hw.disknames
gpt show ld0                  # indexes 1..5 must all be present
gpt backup ld0 > /tmp/gpt-ld0.backup
dkctl ld0 listwedges          # if empty: dkctl ld0 makewedges
```

### Recovery: ESP entry missing (index 1 gone)

If `gpt show ld0` starts at index 2 and the first "Unused" gap is start 34,
size 1230814, recreate the ESP entry at its exact old position. The data is
still there; only the table entry was lost.

```sh
gpt add -i 1 -b 2048 -s 1228800 -t efi -l "EFI System Partition" ld0
dkctl ld0 makewedges
mkdir -p /mnt/esp
mount_msdos -o ro /dev/dk0 /mnt/esp
ls /mnt/esp/EFI               # expect: BOOT fedora
umount /mnt/esp
```

The recreated entry gets a new partition GUID, so the firmware's Fedora boot
entry may be stale. If the laptop doesn't boot Fedora: F9 -> disk's UEFI entry
(fallback loader recreates the Fedora entry), or "Boot From EFI File" ->
`EFI/fedora/shimx64.efi`.

## 3. Manual install

```sh
newfs -O 2 /dev/rdk4
mkdir -p /targetroot
mount -o log /dev/dk4 /targetroot

ls /amd64/binary/sets || find / -name base.tar.xz
cd /targetroot
for s in base etc kern-GENERIC modules rescue misc text man comp; do
  tar -xJpf /amd64/binary/sets/$s.tar.xz
done
# optional X: xbase xcomp xetc xfont xserver

cd /targetroot/dev && sh ./MAKEDEV all
```

fstab (sysinst normally writes the extra lines; without `ptyfs`, SSH fails with
"PTY allocation request failed"):

```sh
cat > /targetroot/etc/fstab <<'EOF'
NAME=netbsd  /         ffs     rw,log    1 1
ptyfs        /dev/pts  ptyfs   rw        0 0
kernfs       /kern     kernfs  rw        0 0
procfs       /proc     procfs  rw,linux  0 0
EOF
mkdir -p /targetroot/dev/pts /targetroot/kern /targetroot/proc
```

Minimal rc.conf (without `rc_configured=YES` the system boots to single-user
with a read-only root):

```sh
cat >> /targetroot/etc/rc.conf <<'EOF'
rc_configured=YES
hostname=netbsd-shift
EOF
chroot /targetroot passwd root
```

EFI loader into the shared ESP, and mark the root partition for efiboot:

```sh
mount_msdos /dev/dk0 /mnt/esp
mkdir -p /mnt/esp/EFI/NetBSD
cp /targetroot/usr/mdec/bootx64.efi /mnt/esp/EFI/NetBSD/
umount /mnt/esp
gpt set -a bootme -i 5 ld0

cd /
umount /targetroot
reboot
```

## 4. GRUB entry (in Fedora)

```sh
sudo ls -l /boot/efi/EFI/NetBSD/       # bootx64.efi present
sudo vim /etc/grub.d/40_custom
```

Append:

```
menuentry "NetBSD 11" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root 1DA5-E71D
    chainloader /EFI/NetBSD/bootx64.efi
}
```

Keep os-prober off (it creates duplicate entries for the other Linux) and
regenerate:

```sh
grep OS_PROBER /etc/default/grub       # GRUB_DISABLE_OS_PROBER=true
sudo grub2-editenv - unset menu_auto_hide
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
efibootmgr -v                          # Fedora first in BootOrder
```

If efiboot stops at its `>` prompt: `boot NAME=netbsd:netbsd`. To make that
permanent, create `/boot.cfg` on the NetBSD root:

```
menu=Boot NetBSD:boot NAME=netbsd:netbsd
timeout=3
```

## 5. First boot fixes (on NetBSD, as root)

### If it boots to single-user / read-only root

```sh
mount -uw /
export TERM=vt100
grep -n rc_configured /etc/rc.conf
sh -n /etc/rc.conf && echo syntax OK
echo 'rc_configured=YES' >> /etc/rc.conf     # if missing
exit                                         # continue to multi-user
```

### Console terminal type (TERM=dumb on /dev/constty)

```sh
export TERM=wsvt25
vi /etc/ttys
```

Set the third field of the `constty` line to `wsvt25` (leave `ttyE0` off; it is
the same screen):

```
constty "/usr/libexec/getty Pc"  wsvt25  on secure
```

```sh
echo 'wscons=YES' >> /etc/rc.conf            # virtual consoles on Ctrl-Alt-F2..F4
```

### Time zone

```sh
ln -sf /usr/share/zoneinfo/Pacific/Auckland /etc/localtime
```

Keep the hardware clock in UTC on all OSes (Fedora and NetBSD default to UTC;
in Slackware `/etc/hardwareclock` should say `UTC`).

### Swap file

```sh
dd if=/dev/zero of=/swapfile bs=1m count=4096
chmod 600 /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
swapctl -a /swapfile
```

## 6. Wi-Fi

The built-in Intel Wi-Fi 6 card shows in `pcictl pci0 list` as an unnamed
"Intel product" (no NetBSD driver). A USB Wi-Fi dongle works; here it attached
as `run0` (check with `ifconfig -l`).

Note: if you associate fine but cannot reach even the router, check the
router's MAC address block list / access control for Wi-Fi.

`/etc/wpa_supplicant.conf` (`chmod 600`):

```
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=wheel
update_config=1
```

Start and add the network with wpa_cli:

```sh
ifconfig run0 up
wpa_supplicant -B -D bsd -i run0 -c /etc/wpa_supplicant.conf
wpa_cli -i run0
```

At the `>` prompt:

```
scan
scan_results
add_network
set_network 0 ssid "YourSSID"
set_network 0 psk "YourPassword"
enable_network 0
status
save_config
quit
```

The `ioctl ... Invalid argument` warning at startup is harmless as long as
`status` reaches `wpa_state=COMPLETED`. Many USB dongles are 2.4 GHz only.

Then:

```sh
dhcpcd run0
ifconfig run0                 # status: active, real LAN address (not 169.254.x.x)
```

Persist at boot:

```sh
echo up > /etc/ifconfig.run0
cat >> /etc/rc.conf <<'EOF'
wpa_supplicant=YES
wpa_supplicant_flags="-B -D bsd -i run0 -c /etc/wpa_supplicant.conf"
dhcpcd=YES
EOF
```

## 7. Time sync and TLS certificates

HTTPS (pkg_add, pkgin) fails with "certificate verify failed" until the clock
is right and the certificate store is populated (sysinst normally does the
latter).

```sh
ntpdate pool.ntp.org
certctl rehash
ls /etc/openssl/certs | wc -l          # well over 100
```

If `/usr/share/certs/mozilla` is missing, re-extract it from the USB stick:

```sh
mount -r /dev/sd0a /mnt
cd / && tar -xJpf /mnt/amd64/binary/sets/base.tar.xz ./usr/share/certs
certctl rehash
```

Persist time sync:

```sh
cat >> /etc/rc.conf <<'EOF'
ntpdate=YES
ntpd=YES
EOF
```

## 8. Binary packages (pkgin)

```sh
PKG_PATH="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/$(uname -p)/$(uname -r | cut -d. -f1,2)/All"
export PKG_PATH
pkg_add -v pkgin
pkgin update
pkgin install sudo
```

Everyday: `pkgin search X`, `pkgin install X`, `pkgin upgrade`, `pkgin list`.
For a regular user, add `/usr/pkg/bin:/usr/pkg/sbin` to PATH in `~/.profile`.

## 9. SSH over the local network

```sh
echo 'sshd=YES' >> /etc/rc.conf
service sshd start
useradd -m -G wheel vensder
passwd vensder
visudo                          # uncomment: %wheel ALL=(ALL) ALL
```

Root password login is disabled by default; log in as the user. From Fedora:

```sh
ssh vensder@<netbsd-ip>
```

If the client terminal is exotic (kitty, foot, alacritty), connect with a
common TERM, or set it in `~/.ssh/config` on the client:

```
Host netbsd-shift
    HostName <netbsd-ip>
    User vensder
    SetEnv TERM=xterm-256color
```

## Final rc.conf additions (summary)

```
rc_configured=YES
hostname=netbsd-shift
wscons=YES
wpa_supplicant=YES
wpa_supplicant_flags="-B -D bsd -i run0 -c /etc/wpa_supplicant.conf"
dhcpcd=YES
ntpdate=YES
ntpd=YES
sshd=YES
```

Check syntax after any edit: `sh -n /etc/rc.conf`.
