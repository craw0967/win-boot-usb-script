# win-boot-usb-script

A shell script to create a bootable Windows USB installer. It is written for **POSIX `sh`** (no bashisms) and creates a USB drive that boots on both **UEFI** and **legacy BIOS** systems. It is **Linux-only** — see [Platform support](#platform-support).

## Why this exists

Most tutorials recommend `dd` for Linux ISOs (which are hybrid ISOs), but Windows ISOs are **not** hybrid — they lack the MBR structures needed to boot from USB directly. Dedicated tools exist ([WoeUSB](https://github.com/WoeUSB/WoeUSB) — no longer actively maintained, [WoeUSB-ng](https://github.com/WoeUSB/WoeUSB-ng), [Ventoy](https://www.ventoy.net/en/)), but each has its own dependencies and complexity. This script is a lightweight shell alternative that automates an alternative, manual method end-to-end.

This script implements the method described in [Guillermo N. Leiro Arroyo's guide](https://guillermodotn.github.io/posts/Creating_a_bootable_Windows_USB_on_linux/), which uses:

- A **GPT partition table** with three partitions
- **NTFS** data partition (accessible in Windows for the installer files)
- **FAT32** EFI System partition with **Rufus' UEFI-NTFS** image (for UEFI boot from NTFS)
- A **BIOS boot partition** plus **GRUB** installed to the MBR (for legacy BIOS boot)

## Partition layout

| Partition | Size | Type | Purpose |
|-----------|------|------|---------|
| `p1` | remainder | Microsoft basic data (NTFS) | Windows installer files; first so Windows mounts it |
| `p2` | 40 MiB | EFI System (FAT32) | Holds the Rufus `uefi-ntfs.img` UEFI bootloader |
| `p3` | ~1 MiB | BIOS boot (`EF02`) | Lets GRUB embed `core.img` on GPT for BIOS boot |

## Prerequisites

- **Linux** (only) with a POSIX shell (`sh`) — see [Platform support](#platform-support)
- **Root access** (`sudo`)
- A **USB drive** (8 GB minimum recommended)
- A **Windows ISO** (download from [Microsoft](https://www.microsoft.com/en-us/software-download/windows11))

### Required tools

The script checks for these automatically:

| Tool | Package (Debian/Ubuntu) | Package (RHEL/Fedora) |
|------|------------------------|----------------------|
| `fdisk` | `util-linux` | `util-linux` |
| `partprobe` | `parted` | `parted` |
| `mkfs.ntfs` | `ntfs-3g` | `ntfsprogs` |
| `mkfs.vfat` | `dosfstools` | `dosfstools` |
| `mount` / `umount` / `dd` | `util-linux` / `coreutils` | `util-linux` / `coreutils` |
| `grub-install` | `grub-pc-bin` (`grub-pc`) | `grub2-tools` |
| `sha256sum` | `coreutils` | `coreutils` |
| `wget` or `curl` | `wget` / `curl` | `wget` / `curl` |
| `lsblk` | `util-linux` | `util-linux` |
| `mount.ntfs-3g` | `ntfs-3g` | `ntfs-3g` |

Optional tools used when present: `wipefs` (util-linux) to clear stale signatures, `udevadm` (systemd) to settle device nodes, `mountpoint` (util-linux).

### Platform support

The shell code is written for **POSIX `sh`** (no bashisms) and is verified under `dash` and BusyBox `sh`. The tool itself is **Linux-only**: it relies on Linux kernel interfaces and Linux tooling — `/proc/self/mounts`, `/sys/class/block/*`, util-linux `fdisk`/`lsblk`/`wipefs`, `partprobe`, `udevadm`, `ntfs-3g`/`ntfs3`, `dosfstools`, `mount -o loop`, and POSIX `dd` block sizes. It does **not** run on BSD or macOS without a port (different device naming, partitioning, mounting, and filesystem tools).

Distro families **expected to work**, with the required packages installed. The "Tested" column reflects actual execution of the script and test suite — only Fedora has been exercised so far; the others are expected to work but are unverified. Test reports are welcome.

| Family | Examples | Tested | Notes |
|--------|----------|--------|-------|
| Debian/Ubuntu | Debian, Ubuntu, Mint, Pop!\_OS | No | uses `grub-install`; GRUB dir `boot/grub` |
| RHEL/Fedora | Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux | **Yes** (Fedora 44) | uses `grub2-install`; GRUB dir `boot/grub2` |
| Arch | Arch, Manjaro, EndeavourOS | No | `grub` package provides `grub-install` |
| openSUSE | Leap, Tumbleweed | No | uses `grub2-install`; package names differ (`grub2`, `ntfs-3g`) |
| Alpine | Alpine (BusyBox) | No | works only with non-BusyBox `util-linux` (for `fdisk`), `grub`, `ntfs-3g`, `dosfstools`, and `parted`; BusyBox `fdisk` cannot script GPT and is not supported |

**Not supported:** FreeBSD/OpenBSD/NetBSD and macOS.

## Usage

```sh
sudo ./win-usb.sh [options] -i <windows.iso> [-d <device>]
```

### Options

| Option | Description |
|--------|-------------|
| `-i`, `--iso <iso>` | Path to Windows ISO file **(required)** |
| `-d`, `--device <dev>` | Target USB device, e.g. `/dev/sde` (prompts if omitted) |
| `-y`, `--yes` | Non-interactive mode — skip all confirmation prompts |
| `--force` | Allow a target that does not look removable/USB (dangerous) |
| `-h`, `--help` | Show help message |

Long options also accept `--iso=<iso>` and `--device=<dev>`.

### Examples

```sh
# Interactive mode (you'll be prompted to select the USB device)
sudo ./win-usb.sh -i ~/Downloads/Win11_23H2.iso

# Fully automated mode (no prompts)
sudo ./win-usb.sh -y -i Win11_23H2.iso -d /dev/sde

# View help
./win-usb.sh -h
```

> **⚠️ WARNING:** The target device will be completely erased. Double-check the device name before proceeding. The script refuses to erase a device that is not a whole, removable/USB disk unless `--force` is given.

## How it works

1. **Validate** the ISO (existence, readability, and an ISO9660 `CD001` signature) and check the target has room for the ISO.
2. **Guard** the target: it must be a whole disk (not a partition) and appear removable/USB (`/sys/.../removable` or `lsblk -o TRAN`), unless `--force`.
3. **Unmount** any mounted partitions on the target and verify they are really gone.
4. **Partition** with GPT using `fdisk`:
   - Partition 1: Microsoft basic data (NTFS) — all space except the two boot partitions
   - Partition 2: EFI System — 40 MiB FAT32 for the UEFI bootloader
   - Partition 3: BIOS boot (`EF02`) — ~1 MiB for GRUB
5. **Format** NTFS on p1 and FAT32 on p2.
6. **Copy** all Windows ISO contents to p1 (including hidden files).
7. **Download** Rufus' `uefi-ntfs.img` — pinned to a specific upstream commit and verified by **SHA-256** — and **write** it to p2 via `dd`.
8. **Install** GRUB (`i386-pc`) into p3/the MBR and write a `grub.cfg` that chain-loads `/bootmgr`, so legacy BIOS boots the Windows installer.

The result is a single USB drive that boots on any system:

- **UEFI**: the firmware loads the UEFI-NTFS driver from the EFI System partition (p2), which can then read the Windows installer files from the NTFS partition (p1)
- **BIOS**: GRUB boots from the BIOS boot partition/MBR and chain-loads the Windows bootloader from p1

## Boot image pinning

The Rufus boot image is fetched from a commit-pinned GitHub URL and its SHA-256 is verified before it is written. To use a newer image, override both values:

```sh
sudo WIN_USB_BOOT_IMG_URL='https://.../uefi-ntfs.img' \
     WIN_USB_BOOT_IMG_SHA256='<sha256>' \
     ./win-usb.sh -i Win11.iso -d /dev/sde
```

## Testing

Three test runners cover the plan in [TEST.md](TEST.md):

```sh
# Non-destructive: parsing, validation, guards, dependency handling, download,
# and the GPT/format layout. No USB needed; run as a normal user (a few checks
# are skipped when run as root).
sh tests/run-tests.sh

# Loop-device end-to-end (no USB): partitions, formats, mounts, copies, writes,
# and the device-side failure branches, against a sparse file.
sudo sh tests/run-loopback.sh

# Destructive: runs the full workflow on a real USB and verifies the artifacts.
sudo CONFIRM_ERASE=yes WIN_USB_DEV=/dev/sde WIN_USB_ISO=Win11.iso \
     sh tests/run-destructive.sh
```

Each runner exits non-zero if any assertion fails. `run-destructive.sh` refuses to run unless the target is a whole USB disk and `CONFIRM_ERASE=yes` is set. The suite drives the script's own `_fdisk_script()`/`_format_*()` helpers rather than re-implementing them, and reads the real `trap` line; this is checked by mutation testing (see TEST.md).

## References

- **Original guide** (method & credit): [Creating a Bootable Windows USB on Linux](https://guillermodotn.github.io/posts/Creating_a_bootable_Windows_USB_on_linux/) by Guillermo N. Leiro Arroyo
- **Windows 11 ISO download**: [https://www.microsoft.com/en-us/software-download/windows11](https://www.microsoft.com/en-us/software-download/windows11)
- **Rufus** (UEFI-NTFS image): [https://rufus.ie/en/](https://rufus.ie/en/)

## License

Released under the [MIT License](LICENSE). See that file for the full text and the copyright notice.

This software is provided **"as is", without warranty of any kind**; you use it at your own risk.

Third-party components are **not** covered by this license:

- **Windows ISO** — not included here; obtain your own and comply with Microsoft's terms.
- **Rufus `uefi-ntfs.img`** — downloaded at runtime from the [Rufus project](https://rufus.ie/en/) (GPL-3.0); this project does not redistribute it.