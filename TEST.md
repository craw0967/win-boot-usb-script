# Test Plan: win-usb.sh

A comprehensive test matrix covering argument parsing, error handling, edge cases, the ISO/device safety guards, the device-side workflow, and full-workflow verification.

## How to run these tests

Three committed runners automate this plan:

| Runner | Needs | Covers |
|--------|-------|--------|
| `sh tests/run-tests.sh` | no USB, no root (network for §8; non-root for 2.1/2.3) | §1–§8, §12 |
| `sudo sh tests/run-loopback.sh` | root, `losetup`, optionally `genisoimage` | §12 device-side + failure branches |
| `sudo … sh tests/run-destructive.sh` | root, USB, Windows ISO | §9, §10, §13 artifact checks |

Destructive runner invocation:

```sh
sudo CONFIRM_ERASE=yes \
     WIN_USB_DEV=/dev/sde \
     WIN_USB_ISO=~/Win11.iso \
     sh tests/run-destructive.sh
# optional: MTEST=1 (tiny ISO-view tests, needs genisoimage), RERUN=1 (re-run test),
#           WIN_USB_MODEL=SSK (extra device-identity gate)
```

**Harness integrity:** the runners do not re-implement script logic. §12 drives the
script's own `_fdisk_script()` and `_format_ntfs()`/`_format_vfat()` helpers, and
§6.1/§6.2 install the exact `trap … INT TERM` line read from the script. This was
verified by mutation testing: changing `trap 'cleanup; exit 1' INT TERM` to
`trap cleanup INT TERM`, changing `BOOT_PART_SIZE`, changing `mkfs.vfat -F 32`
to `-F 16`, or disabling the curl fallback each makes the suite fail.

**Legend:** ✅ automated — 🙋 manual/on-hardware.

---

## 1. Argument parsing tests — ✅ `tests/run-tests.sh`

| # | Test | Command | Expected `iso_path` | Expected `target_dev` | Expected `yes_flag` | Expected `force_flag` |
|---|------|---------|---------------------|----------------------|---------------------|-----------------------|
| 1.1 | Help (short) | `./win-usb.sh -h` | — | — | usage, exits 0 (documents `--force`, `--iso`, `--device`, env overrides) | — |
| 1.2 | Help (long) | `./win-usb.sh --help` | — | — | usage, exits 0 | — |
| 1.3 | ISO only (short) | `./win-usb.sh -i foo.iso` | `foo.iso` | `""` | `0` | `0` |
| 1.4 | ISO only (long) | `./win-usb.sh --iso foo.iso` | `foo.iso` | `""` | `0` | `0` |
| 1.5 | ISO only (long `=`) | `./win-usb.sh --iso=foo.iso` | `foo.iso` | `""` | `0` | `0` |
| 1.6 | ISO + yes (short) | `./win-usb.sh -y -i foo.iso` | `foo.iso` | `""` | `1` | `0` |
| 1.7 | ISO + yes (long) | `./win-usb.sh --yes --iso foo.iso` | `foo.iso` | `""` | `1` | `0` |
| 1.8 | ISO + device (short) | `./win-usb.sh -i foo.iso -d /dev/sde` | `foo.iso` | `/dev/sde` | `0` | `0` |
| 1.9 | ISO + device (long) | `./win-usb.sh --iso foo.iso --device /dev/sde` | `foo.iso` | `/dev/sde` | `0` | `0` |
| 1.10 | ISO + device (long `=`) | `./win-usb.sh --iso=foo.iso --device=/dev/sde` | `foo.iso` | `/dev/sde` | `0` | `0` |
| 1.11 | ISO + device + yes | `./win-usb.sh -y -i foo.iso -d /dev/sde` | `foo.iso` | `/dev/sde` | `1` | `0` |
| 1.12 | `--force` sets flag | `./win-usb.sh --force -i foo.iso -d /dev/sde` | `foo.iso` | `/dev/sde` | `0` | `1` |
| 1.13 | Reversed order | `./win-usb.sh -d /dev/sde -y -i foo.iso` | `foo.iso` | `/dev/sde` | `1` | `0` |
| 1.14 | Missing `-i` value | `./win-usb.sh -i` | — | — | "Option -i requires an argument", exit 1 | — |
| 1.15 | Missing `-d` value | `./win-usb.sh -i foo.iso -d` | — | — | "Option -d requires an argument", exit 1 | — |
| 1.16 | Unknown short flag | `./win-usb.sh -z foo.iso` | — | — | "Unknown option", exit 1 | — |
| 1.17 | Unknown long flag | `./win-usb.sh --bogus foo.iso` | — | — | "Unknown option", exit 1 | — |
| 1.18 | Positional arg | `./win-usb.sh foo.iso` | — | — | "Unexpected positional argument", exit 1 | — |
| 1.19 | `--` terminator | `./win-usb.sh -i foo.iso -- -d /dev/sde` | `foo.iso` | `""` | `0` | `0` |
| 1.20 | No arguments | `./win-usb.sh` | `""` | `""` | `0` | `0` |
| 1.21 | Empty `-i` value | `./win-usb.sh -i "" -d /dev/sde` | — | — | "Option -i requires an argument", exit 1 | — |
| 1.22 | Empty `--iso=` | `./win-usb.sh --iso= -d /dev/sde` | `""` | `/dev/sde` | `0` | `0` |
| 1.23 | No ISO at main() level | `main -y` with `id -u` stubbed to 0 | `""` | `""` | "A Windows ISO is required", exit 1 | — |

> `-i ""` is caught at parse time ("requires an argument"). The separate "A Windows ISO is required" branch is reached from `main()` only with `-i` omitted; the test stubs `id` to reach it without root.

---

## 2. Prerequisite / validation tests — ✅ `tests/run-tests.sh`

| # | Test | Command | Expected behaviour |
|---|------|---------|-------------------|
| 2.1 | Not root | run as non-root `-i foo.iso -d /dev/null` | "must be run as root", exit 1 (skipped when the suite runs as root) |
| 2.2 | ISO missing | `-i /nonexistent.iso` | "ISO file not found", exit 1 |
| 2.3 | ISO unreadable | `validate_iso unreadable.iso` **as non-root** | "ISO file not readable", exit 1 (skipped as root) |
| 2.4 | ISO empty | `: > /tmp/empty.iso; ...` | "ISO file is empty", exit 1 |
| 2.5 | Not a block device | `-d /dev/null` | "Not a block device", exit 1 |
| 2.6 | Missing `-d` in non-interactive | `./win-usb.sh -y -i real.iso` | "Option -d ... required in non-interactive mode", exit 1 |
| 2.7 | Non-ISO file | `-i /etc/hostname ...` | Warning "does not look like an ISO9660 image"; continues |
| 2.8 | Device too small | ISO larger than device minus 128 MiB | "too small", exit 1 |

> 2.3 cannot be triggered via `sudo` — root bypasses file modes. Run the suite as a normal user, or that check is skipped.

---

## 3. Dependency checks — ✅ `tests/run-tests.sh`

Simulated with a symlink-farm `PATH` built by the runner.

| # | Missing tool | Expected behaviour |
|---|-------------|-------------------|
| 3.1 | `fdisk` | lists `fdisk`, exit 1 |
| 3.2 | `mkfs.ntfs` | lists `mkfs.ntfs`, exit 1 |
| 3.3 | `mkfs.vfat` | lists `mkfs.vfat`, exit 1 |
| 3.4 | `mount` | lists `mount`, exit 1 |
| 3.5 | `umount` | lists `umount`, exit 1 |
| 3.6 | `dd` | lists `dd`, exit 1 |
| 3.7 | `partprobe` | lists `partprobe`, exit 1 |
| 3.8 | Both `wget` AND `curl` | lists `wget OR curl`, exit 1 |
| 3.9 | Both `grub-install` AND `grub2-install` | lists `grub-install OR grub2-install`, exit 1 |
| 3.10 | All SHA-256 tools | lists `sha256sum OR shasum OR openssl`, exit 1 |
| 3.11 | `lsblk` (interactive mode) | lists `lsblk`, exit 1 |
| 3.12 | `lsblk` in `-y` mode | **passes** (lsblk not required) |
| 3.13 | `awk` | lists `awk`, exit 1 |
| 3.14 | GRUB i386-pc modules absent | Warning only — 🙋 |

---

## 4. Interactive prompts & device listing — ✅ `tests/run-tests.sh`

| # | Scenario | User input | Expected behaviour |
|---|----------|------------|-------------------|
| 4.1 | No device given | valid block device path | Device accepted **and stored** in `target_dev` |
| 4.2 | Invalid device | `bogus` | "Not a block device" |
| 4.3 | Empty device input | (just Enter) | "No device entered" |
| 4.4 | Destruction confirm, correct | `YES` | Continues |
| 4.5 | Destruction confirm, wrong case | `yes` | "Aborted.", exit 0 |
| 4.6 | Destruction confirm, empty | (just Enter) | "Aborted.", exit 0 |
| 4.7 | `list_devices` shows **full paths** | — | Output contains `/dev/sda`-style paths, never bare `sda` |
| 4.8 | Every listed entry is a full path | — | Each data line's first field starts with `/dev/` |
| 4.9 | `list_devices` without `lsblk` | — | Prints header, exit 0 |

---

## 5. Device naming edge cases (`_part_base()`) — ✅ `tests/run-tests.sh`

| # | Input | Expected output | Device type |
|---|-------|-----------------|-------------|
| 5.1 | `/dev/sda` | `/dev/sda` | SCSI/SATA |
| 5.2 | `/dev/sdb` | `/dev/sdb` | SCSI/SATA |
| 5.3 | `/dev/vda` | `/dev/vda` | VirtIO (no `p`) |
| 5.4 | `/dev/nvme0n1` | `/dev/nvme0n1p` | NVMe |
| 5.5 | `/dev/nvme1n1` | `/dev/nvme1n1p` | NVMe |
| 5.6 | `/dev/mmcblk0` | `/dev/mmcblk0p` | SD/MMC |
| 5.7 | `/dev/loop0` | `/dev/loop0p` | Loopback |

---

## 6. Cleanup / trap tests — ✅ `tests/run-tests.sh`

| # | Scenario | How to trigger | Expected behaviour |
|---|----------|---------------|-------------------|
| 6.1 | SIGINT | `timeout -s INT` with the script's **actual** trap | Handler runs; shell does **not** continue |
| 6.2 | SIGTERM | `timeout -s TERM` (same) | Handler runs; shell does **not** continue |
| 6.3 | Cleanup idempotency | Run `cleanup` twice | No errors on second run |
| 6.4 | `die` cleans workspace | `. lib.sh; setup_workdir; die "x"` | Exits 1; `/tmp/win-usb.*` removed |
| 6.5 | Cleanup keeps non-workspace dirs | `WORK_DIR=/tmp/win-usb-safety; cleanup` | Directory kept (pattern guard) |
| 6.6 | Cleanup removes matching workspace | `WORK_DIR=/tmp/win-usb.matchme; cleanup` | Directory removed |
| 6.7 | Ctrl+C during copy | 🙋 Ctrl+C during `cp -R` | ISO + data partition unmounted, workspace removed, exit 1 |
| 6.8 | `_is_mounted` without `mountpoint` | hide `mountpoint`; test `/` and a bogus path | awk fallback: `/` mounted, bogus path not |

---

## 7. Device safety guard tests — ✅ `tests/run-tests.sh`

| # | Scenario | Command | Expected behaviour |
|---|----------|---------|-------------------|
| 7.1 | Partition, not whole disk | `-d /dev/sda1` | "is a partition, not a whole disk", exit 1 |
| 7.1b | `--force` + partition | `--force -d /dev/sda1` | **Still rejected** (partition check precedes force) |
| 7.2 | Non-removable disk, no `--force` | `-d /dev/nvme0n1` | "does not look like a removable/USB device", exit 1 |
| 7.3 | Non-removable disk with `--force` | `--force -d /dev/nvme0n1` | Guard bypassed (⚠ destructive) |
| 7.4 | Removable/USB disk accepted | `-d /dev/sde` (`TRAN=usb`) | Guard passes |
| 7.5 | Capacity check | ISO larger than target minus 128 MiB | "too small", exit 1 |
| 7.5b | Capacity boundary | ISO exactly `device − MIN_FREE_BYTES` | Passes |
| 7.5c | Capacity boundary +1 | ISO one byte larger | Aborts "too small" |
| 7.6 | No removable flag, no transport | `-d /dev/zram0` | "does not look like a removable", exit 1 |

> Use an **internal** device (e.g. `/dev/nvme0n1`) as the "non-removable" example; `/dev/sda` is often the USB itself.

---

## 8. Boot image download / checksum tests — ✅ `tests/run-tests.sh`

| # | Scenario | Expected behaviour |
|---|----------|-------------------|
| 8.1 | Pinned URL | Downloads 1,048,576-byte image |
| 8.2 | curl only (no wget) | `curl -fsSL` follows the GitHub 302 and succeeds |
| 8.3 | wget only (no curl) | Succeeds |
| 8.3b | wget present but **fails** | Falls back to `curl` and succeeds (regression guard for the old `elif`) |
| 8.4 | Checksum mismatch (`WIN_USB_BOOT_IMG_SHA256=deadbeef`) | Fatal error showing expected/actual, exit 1 |
| 8.5 | Download failure (bad host) | "Failed to download boot image", exit 1 |
| 8.6 | `_sha256` fallback | Uses `openssl` when `sha256sum` absent |
| 8.7 | `_sha256` fallback | Uses `shasum` when `sha256sum` absent (emulated) |

---

## 9. Full workflow test — 🙋 + ✅ `tests/run-destructive.sh`

**Prerequisites:** USB drive sized **≥ ISO size + 128 MiB**, Windows ISO, all dependencies, `CONFIRM_ERASE=yes`.

| # | Test | Steps | Expected result |
|---|------|-------|----------------|
| 9.1 | Basic interactive | `sudo ./win-usb.sh -i Win.iso` → select USB → `YES` | Bootable Windows USB — 🙋 |
| 9.2 | Non-interactive | `sudo ./win-usb.sh -y -i Win.iso -d /dev/sde` | Same result, no prompts, exit 0 |
| 9.3 | Partitions verify | `fdisk -l` + `blkid` | GPT: p1 NTFS (`Microsoft basic data`), p2 **EFI System** **40 MiB** (`vfat`), p3 **BIOS boot** |
| 9.4 | Boot image on p2 | `dd if=/dev/sde2 … \| strings` | `RUFUS_BOOT` label present |
| 9.5 | ISO contents | Mounted p1 | Has `sources/`, `boot/`, `efi/`, `bootmgr`, and `install.wim` **or** `install.esd` |
| 9.6 | ISO root entry parity | Compare `ls -A` ISO root vs p1 | No ISO entry missing on p1 |
| 9.7 | GRUB config | `p1/grub/grub.cfg` or `grub2/grub.cfg` | Contains `menuentry` and `ntldr /bootmgr` |
| 9.8 | GRUB in MBR | `dd if=/dev/sde bs=512 count=1 \| strings \| grep -i grub` | MBR contains GRUB |
| 9.9 | UEFI boot | 🙋 boot on UEFI, Secure Boot off | Windows installer starts |
| 9.10 | BIOS boot | 🙋 boot on legacy BIOS/CSM | GRUB menu → Windows installer |
| 9.11 | UEFI bootloader on p2 | Mount p2, find `EFI/BOOT/BOOTX64.EFI` | Present (validates the UEFI path, not just the label) |
| 9.12 | GRUB `core.img` in p3 | diskboot markers (`Geom`/`loading`) in p3 | Present (core images contain no literal `grub` strings) |
| 9.13 | `install.wim` intact | Compare p1 file size with ISO's | Byte-for-byte size match (proves the >4 GiB copy) |
| 9.14 | Cleanup after success | Workspace + `.win-usb-write-probe` | No leftover `/tmp/win-usb.*`; probe file removed from p1 |

> **Note:** p2 is formatted FAT32 during the run, then **overwritten by `dd` with the image's FAT12 filesystem** (label `RUFUS_BOOT`). `blkid` therefore reports `vfat`; the partition *type* is `EFI System`.

---

## 10. Recovery / re-run tests — ✅ `tests/run-destructive.sh` / `tests/run-loopback.sh`

| # | Test | Steps | Expected result |
|---|------|-------|----------------|
| 10.1 | Re-run on same USB | `RERUN=1` | Second run succeeds (signatures cleared via `wipefs`) |
| 10.2 | USB already mounted | Pre-mount p1, then run | Script unmounts it; run succeeds |
| 10.3 | Stuck mount | Fail `umount` via a stub while p1 is mounted | Script aborts with "still mounted" rather than corrupting |
| 10.4 | Auto-mount eviction | Mount p2, call `_unmount_device_path` | Partition is unmounted (guards `dd` against udisks) |

---

## 11. Environment / distro compatibility — 🙋

All entries are **Linux**; BSD and macOS are out of scope (see the README's Platform support section). The shell language is POSIX `sh` (verified under `dash` and BusyBox `sh`), but the tool's interfaces and dependencies are Linux-specific.

| # | Environment | Notes |
|---|-------------|-------|
| 11.1 | Debian/Ubuntu (dash as `/bin/sh`) | POSIX-`sh` compatibility plus the `grub-install`/`grub/` path |
| 11.2 | Fedora/RHEL | Exercises `grub2-install` and the `grub2/` config dir |
| 11.3 | Arch / Manjaro | Rolling release compatibility |
| 11.4 | Alpine Linux (BusyBox) | Needs non-BusyBox `util-linux`, `grub`, `ntfs-3g`, `dosfstools`, `parted`; BusyBox `fdisk` cannot script GPT |
| 11.5 | openSUSE Leap/Tumbleweed | `grub2-install`; different package names |
| 11.6 | NVMe target | Covered by `_part_base` and `_mounted_parts` unit tests (§5.4/§12.4) |
| 11.7 | No `mountpoint` / no `udevadm` | `mountpoint` fallback is automated (§6.8); no-`udevadm` is manual |
| 11.8 | No `shasum`/`sha256sum` | SHA fallbacks automated (§8.6/§8.7) |
| 11.9 | BSD / macOS | **Out of scope** — different device naming, partitioning, mounting and filesystem tools |

---

## 12. Hardware-free harness — ✅ `tests/run-tests.sh` / `tests/run-loopback.sh`

The script now exposes testable units so the tests cannot drift from it:

```sh
# The exact GPT sequence, from the script itself (not a copy):
sh -c '. /tmp/win-usb-lib.sh; _fdisk_script' > /tmp/cmds
truncate -s 512M /tmp/layout.img && fdisk /tmp/layout.img < /tmp/cmds
fdisk -l /tmp/layout.img   # p1 Microsoft basic data, p2 EFI System 40M, p3 BIOS boot

# The exact formatters, from the script itself:
sh -c '. /tmp/win-usb-lib.sh; _format_vfat /tmp/boot.fat'   # -> FAT32
sh -c '. /tmp/win-usb-lib.sh; _format_ntfs /tmp/data.img'   # -> NTFS
```

Additional automated checks in §12: `_mounted_parts` NVMe `p`-suffix regex (fixture
mount table), `setup_workdir` without `mktemp`, `_dev_size_bytes` on a bogus device,
`check_capacity` with an unreadable ISO, `confirm_destruction` `-y` short-circuit
and no-`lsblk` fallback, and `install_grub` refusing an empty boot directory
(which would otherwise default to the host's `/boot`).

`tests/run-loopback.sh` additionally exercises, on a real loop device:
`partition_device`, `format_partitions`, `mount_data_partition` (writability probe),
`mount_iso` + `copy_iso_contents` (including a hidden dotfile), `write_boot_image`
(with the pinned image when online, else a synthesized payload), and the failure
branches for `fdisk`, `mkfs.ntfs`, `mkfs.vfat`, `cp`, `dd`, `mount`, and a missing
GRUB installer. The "missing GRUB installer" case uses a PATH containing **only**
an empty directory (no real tools appended) so a host `grub2-install` cannot be
found accidentally.

---

## 13. ISO filesystem-view tests — ✅ `tests/run-destructive.sh` (`MTEST=1`)

Windows ISOs are often ISO9660+UDF hybrids whose ISO9660 tree is a bare stub; the installer payload exists only in UDF.

| # | Scenario | Expected behaviour |
|---|----------|-------------------|
| 13.1 | Real hybrid ISO mounts | Uses the **UDF** view (`findmnt` FSTYPE `udf`), not the ISO9660 stub |
| 13.2 | Real hybrid ISO content | `sources/` present even when `README.TXT` (the stub) also exists |
| 13.3 | Non-UDF ISO that has `sources/` | Falls back through auto/ISO9660 and mounts successfully |
| 13.4 | ISO with no `sources/` | Aborts: "Mounted ISO has no 'sources' directory", exit 1 |
| 13.4b | Aborted mount leaks | The failed mount point is unmounted by `cleanup` |

---

## Known residuals

- §9.9/§9.10 (real UEFI/BIOS boot) and §6.7 (Ctrl+C during a live copy) remain manual.
- §11 is environment-specific; only Fedora is exercised here.
- `confirm_destruction` aborts with **exit 0** (by design); §4.5/§4.6 lock that in.
- `check_target_device`'s `/sys .../removable == 1` branch (non-USB removable media, e.g. an SD card) has no automated test; it needs such a device.

---

## Test result template

```
Test #:      ___
Date:        ___
Command:     ___
Result:      [PASS / FAIL]
Notes/Logs:  ___
```

---

## License

This test plan is part of the win-usb.sh project and is released under the
[MIT License](LICENSE) (see also [README.md](README.md#license)).