# Porting the iwx driver (Intel Wi-Fi 6 AX200) to NetBSD

Notes for a future attempt at getting the built-in Wi-Fi of an HP EliteBook
840 G6 working on NetBSD 11.

## Current status (checked October 2026)

- Device: `vendor 0x8086 product 0x2723` = Intel Wi-Fi 6 AX200 (M.2 2230,
  removable card, not CNVi).
- NetBSD 11 dmesg:
  `Intel product 2723 (miscellaneous network, revision 0x1a) at pci6 dev 0 function 0 not configured`
- No NetBSD driver. NetBSD's newest Intel Wi-Fi driver is `iwm` (7260/8000
  series). `sys/dev/pci/files.pci` on trunk (rev 1.454, 2026-07-11) has no
  `iwx` entry, so a -current kernel does not help.
- `/libdata/firmware/` has `if_iwm`, `if_iwn`, but no `if_iwx`.
- Drivers exist elsewhere:
  - OpenBSD `iwx(4)`, since OpenBSD 6.7 (AX200/AX201/AX210/AX211)
  - FreeBSD `iwx`, since FreeBSD 15.0 (port of the OpenBSD driver)

Workarounds until a port exists: USB Wi-Fi dongle (e.g. `run0`, `urtwn0`), or
swap the M.2 card for an `iwm`-supported Intel card (see `man iwm` for the
list; check the HP BIOS WLAN whitelist first).

Scope: `if_iwx.c` is ~10k lines. The hard part is the 802.11 stack, not the
PCI glue. Expect weeks of kernel work.

## 1. Choose the source to port from

NetBSD's `iwm` was ported from OpenBSD's `iwm`, and OpenBSD's `iwx` was
derived from OpenBSD's `iwm`. Diffing NetBSD `if_iwm.c` against OpenBSD
`if_iwm.c` shows how every API was translated last time - use it as a map.

FreeBSD's `iwx` targets FreeBSD's net80211 (with VAPs), which is the stack
NetBSD has been migrating toward. Check which stack the tree has:

```sh
grep -rl ieee80211vap /usr/src/sys/net80211 | head
```

- No matches: old NetBSD net80211 -> port from OpenBSD, follow the `iwm` port.
- Matches: new FreeBSD-style net80211 -> FreeBSD `iwx` needs less 802.11 rework.

## 2. Kernel build setup

```sh
cd /usr && git clone --depth 1 https://github.com/NetBSD/src.git
cd /usr/src
./build.sh -U -m amd64 -j4 tools
./build.sh -U -m amd64 -j4 kernel=GENERIC
```

- Target `-current` (trunk) if the work is meant to be upstreamed.
- A `netbsd-11` branch checkout matches an installed NetBSD 11 more closely.

### Running a -current kernel on NetBSD 11 userland

Usually boots (newer kernels keep compatibility with older userland), but
kernel modules must match the kernel version exactly: a -current (11.99.x)
kernel loads modules only from `/stand/amd64/11.99.x/modules/`. Install the
matching modules set and keep the NetBSD 11 kernel as a boot fallback
(e.g. `/netbsd.old`).

## 3. Wire the driver into the tree

Copy into `sys/dev/pci/`:

- `if_iwx.c`
- `if_iwxreg.h`
- `if_iwxvar.h`

Add to `sys/dev/pci/files.pci`, modeled on the existing `iwm` entry:

```
# Intel Wi-Fi 6 AX200/AX201/AX210/AX211
device  iwx: ifnet, arp, wlan, firmload
attach  iwx at pci
file    dev/pci/if_iwx.c        iwx
```

PCI IDs: check `sys/dev/pci/pcidevs` for product `0x2723`; if missing, add it
and regenerate:

```sh
cd /usr/src/sys/dev/pci && make -f Makefile.pcidevs
```

Kernel config (`sys/arch/amd64/conf/GENERIC`):

```
iwx*    at pci? dev ? function ?
```

For faster iteration, also build it as a loadable module modeled on
`sys/modules/if_iwm`, then `modload` / `modunload` it without rebuilding and
rebooting into a new kernel each time. A panic still means a reboot.

## 4. API translation (the bulk of the work)

| OpenBSD                                   | NetBSD                                             |
|-------------------------------------------|----------------------------------------------------|
| `loadfirmware()`                          | `firmload(9)`, files in `/libdata/firmware/if_iwx/` |
| `timeout_set` / `timeout_add`             | `callout(9)`                                       |
| `task_add` / taskq                        | `workqueue(9)` or `softint(9)`                     |
| `rw_enter_write()`                        | `rw_enter(&l, RW_WRITER)`                          |
| `MCLGETL()`, ifq API                      | `MCLGET`, `if_snd` / `IFQ_*`                       |
| `pci_intr_establish` (OpenBSD signature)  | `pci_intr_alloc` / `pci_intr_establish_xname`      |
| net80211 HT/VHT, rate control, node layout| NetBSD net80211 - the largest difference           |

### Firmware

The AX200 needs Intel's `cc-a0` microcode, the same file Linux uses as
`iwlwifi-cc-a0-*.ucode`, available from linux-firmware. OpenBSD does not ship
it because of Intel's license terms (it fetches it via `fw_update`); using it
on your own machine is fine. Install under `/libdata/firmware/if_iwx/` and load
it with `firmload(9)`.

## 5. Bring-up stages

1. **Attach**: probe matches 0x2723, firmware loads, NVM read, MAC address
   printed in dmesg.
2. **Scan**: `ifconfig iwx0 scan` lists networks.
3. **Associate**: open network first, then WPA2/CCMP via
   `wpa_supplicant -D bsd`.
4. **Traffic**: DHCP (`dhcpcd iwx0`) and ping.
5. **Speed**: HT/VHT rates, later.

Keep stage 3 on legacy 11a/b/g rates. The original NetBSD `iwm` port started
that way, and it cuts the net80211 work drastically.

## 6. Before writing code

- Search the NetBSD **tech-net** mailing list archive and the PR database
  (gnats.netbsd.org) for "iwx" / "AX200" - there may be partial work.
- Post on tech-net that a port is starting; the `iwm` and net80211 maintainers
  can point out pitfalls.
- A working attach + scan is already a useful patch to share.

## Useful references

- OpenBSD: `sys/dev/pci/if_iwx.c`, `if_iwxreg.h`, `if_iwxvar.h`; `iwx(4)`
- OpenBSD vs NetBSD: `sys/dev/pci/if_iwm.c` in both trees (translation map)
- FreeBSD: `sys/dev/iwx/` (FreeBSD 15+)
- NetBSD man pages: `firmload(9)`, `callout(9)`, `workqueue(9)`, `pci(9)`,
  `ieee80211(9)`, `module(9)`
