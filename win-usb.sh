#!/bin/sh
# SPDX-License-Identifier: MIT
# win-usb.sh -- Create a bootable Windows USB drive from Linux
# Shell: POSIX sh (no bashisms).  Platform: Linux only.
#
# Original method:
#   https://guillermodotn.github.io/posts/Creating_a_bootable_Windows_USB_on_linux/
#
# This script partitions a USB drive with GPT, creates an NTFS data
# partition and a small FAT32 EFI System partition, copies Windows ISO
# contents, writes Rufus' uefi-ntfs.img boot image, and installs GRUB
# into a BIOS boot partition for legacy BIOS compatibility.
# The resulting drive will boot on both UEFI and legacy BIOS systems.
#
# All data on the target device will be DESTROYED.

set -o nounset

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"

# Rufus UEFI:NTFS boot image.  Pinned to a specific upstream commit and
# verified by SHA-256, so a change to upstream 'master' cannot silently
# alter what is written to the USB.  Override both variables to update.
: "${WIN_USB_BOOT_IMG_URL:=https://raw.githubusercontent.com/pbatard/rufus/2350489fe902bdc71d37f255a7684fe06a0ab2d0/res/uefi/uefi-ntfs.img}"
: "${WIN_USB_BOOT_IMG_SHA256:=72683fa1250eeea772d3399277b434d4e55ba8dd0dc926e52d817e701fc2eb9e}"
UEFI_NTFS_URL="$WIN_USB_BOOT_IMG_URL"
UEFI_NTFS_SHA256="$WIN_USB_BOOT_IMG_SHA256"

REFERENCE_URL="https://guillermodotn.github.io/posts/Creating_a_bootable_Windows_USB_on_linux/"
WIN11_URL="https://www.microsoft.com/en-us/software-download/windows11"

# GPT layout created by partition_device():
#   p1  NTFS data partition   all space minus the two boot partitions
#   p2  EFI System (FAT32)    40 MiB, holds the UEFI:NTFS boot image
#   p3  BIOS boot (EF02)      ~1 MiB, lets GRUB embed core.img on GPT
# p1 must stay first: Windows mounts only the first partition of removable
# media.
BOOT_PART_SIZE="+40M"
BOOT_PART_RESERVE="-42M"
MIN_FREE_BYTES=134217728   # 128 MiB headroom beyond the ISO size

# Work paths -- populated by setup_workdir()
WORK_DIR=""
ISO_MNT=""
DATA_MNT=""
BOOT_IMG=""

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} -- Create a bootable Windows USB drive from Linux

USAGE
    ${SCRIPT_NAME} [options] -i <windows.iso> [-d <device>]

OPTIONS
    -i, --iso <iso>      Path to Windows ISO file (required)
    -d, --device <dev>   Target USB device, e.g. /dev/sde
                         (prompts interactively if omitted)
    -y, --yes            Non-interactive mode -- skip all confirmation prompts
        --force          Allow a target that does not look removable/USB.
                         Dangerous; required only for unusual hardware.
    -h, --help           Show this help message and exit

    The long forms also accept --iso=<iso> and --device=<dev>.

DESCRIPTION
    Partitions a USB drive with GPT: an NTFS data partition (p1), a
    40 MiB FAT32 EFI System partition (p2), and a 1 MiB BIOS boot
    partition (p3).  Copies all Windows installation files from the ISO
    to p1, writes the Rufus UEFI:NTFS boot image to p2, and installs
    GRUB into p3 for legacy BIOS boot.

    The resulting USB drive will boot on both UEFI and legacy BIOS
    systems.  DESTRUCTIVE: ALL DATA on the target device will be ERASED.

PLATFORM
    Linux only.  Written for POSIX sh (no bashisms); requires util-linux
    (fdisk, lsblk), ntfs-3g, dosfstools, parted (partprobe) and GRUB.

EXAMPLES
    ${SCRIPT_NAME} -i ~/Downloads/Win11_23H2.iso
    ${SCRIPT_NAME} -y -i Win11_23H2.iso -d /dev/sde

ENVIRONMENT
    WIN_USB_BOOT_IMG_URL     Override the boot image download URL
    WIN_USB_BOOT_IMG_SHA256  Override the expected SHA-256 of the image

REFERENCES
    Original guide: ${REFERENCE_URL}
    Windows 11 ISO: ${WIN11_URL}
    Rufus:          https://rufus.ie/en/
EOF
    exit 0
}

die() {
    echo "${SCRIPT_NAME}: ERROR: $*" >&2
    cleanup
    exit 1
}

cleanup() {
    _umount_silent "${ISO_MNT:-}"
    _umount_silent "${DATA_MNT:-}"
    if [ -n "${WORK_DIR:-}" ]; then
        case "$WORK_DIR" in
            */win-usb.*)
                if [ -d "$WORK_DIR" ]; then
                    rm -rf "$WORK_DIR" 2>/dev/null || true
                fi
                ;;
        esac
    fi
    WORK_DIR=""
    ISO_MNT=""
    DATA_MNT=""
    BOOT_IMG=""
}

_is_mounted() {
    _mp="$1"
    [ -n "$_mp" ] || return 1
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$_mp" 2>/dev/null && return 0
        return 1
    fi
    awk -v mp="$_mp" '$2 == mp { found = 1 } END { exit(found ? 0 : 1) }' \
        /proc/self/mounts 2>/dev/null
}

_umount_silent() {
    _mp="$1"
    [ -n "$_mp" ] || return 0
    if [ -d "$_mp" ] && _is_mounted "$_mp"; then
        umount "$_mp" 2>/dev/null || umount -l "$_mp" 2>/dev/null || true
    fi
}

_part_base() {
    case "$1" in
        /dev/nvme*|/dev/mmc*|/dev/loop*)
            echo "${1}p"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

# Print every mounted device that is $1 or one of its partitions.
# Optional 2nd argument is the mount table to read (defaults to the live
# one); the file argument keeps this unit-testable.
_mounted_parts() {
    _mnt="${2:-/proc/self/mounts}"
    awk -v d="$1" '
        $1 == d { print $1; next }
        index($1, d) == 1 && substr($1, length(d) + 1) ~ /^p?[0-9]+$/ { print $1 }
    ' "$_mnt" 2>/dev/null
}

# Unmount one specific device path (exact match).  Used to evict partitions
# that a desktop auto-mounter (udisks) may have mounted behind our back.
_unmount_device_path() {
    _d="$1"
    [ -n "$_d" ] || return 0
    _mp=$(awk -v d="$_d" '$1 == d { print $1 }' /proc/self/mounts 2>/dev/null)
    if [ -n "$_mp" ]; then
        printf '%s\n' "$_mp" | while read -r _p; do
            [ -n "$_p" ] || continue
            echo "  unmounting ${_p}"
            umount "$_p" 2>/dev/null || umount -l "$_p" 2>/dev/null || true
        done
    fi
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    iso_path=""
    target_dev=""
    yes_flag=0
    force_flag=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --yes|-y)
                yes_flag=1
                shift
                ;;
            --force)
                force_flag=1
                shift
                ;;
            --iso|-i)
                if [ -z "${2:-}" ]; then
                    die "Option $1 requires an argument"
                fi
                iso_path="$2"
                shift 2
                ;;
            --iso=*)
                iso_path="${1#--iso=}"
                shift
                ;;
            --device|-d)
                if [ -z "${2:-}" ]; then
                    die "Option $1 requires an argument"
                fi
                target_dev="$2"
                shift 2
                ;;
            --device=*)
                target_dev="${1#--device=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "Unknown option: $1 (see ${SCRIPT_NAME} -h)"
                ;;
            *)
                die "Unexpected positional argument: $1 (use -i for ISO, -d for device)"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (use sudo)"
    fi
}

check_deps() {
    _missing=""

    for _cmd in fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe awk; do
        if ! command -v "$_cmd" >/dev/null 2>&1; then
            _missing="${_missing}  ${_cmd}"
        fi
    done

    if ! command -v wget >/dev/null 2>&1 && \
       ! command -v curl >/dev/null 2>&1; then
        _missing="${_missing}  wget OR curl"
    fi

    if ! command -v sha256sum >/dev/null 2>&1 && \
       ! command -v shasum >/dev/null 2>&1 && \
       ! command -v openssl >/dev/null 2>&1; then
        _missing="${_missing}  sha256sum OR shasum OR openssl"
    fi

    if ! command -v grub-install >/dev/null 2>&1 && \
       ! command -v grub2-install >/dev/null 2>&1; then
        _missing="${_missing}  grub-install OR grub2-install"
    fi

    if [ "$yes_flag" -eq 0 ] && ! command -v lsblk >/dev/null 2>&1; then
        _missing="${_missing}  lsblk (needed for interactive device listing)"
    fi

    if [ -n "$_missing" ]; then
        die "Missing required tool(s):${_missing}"
    fi

    # Advisory: the i386-pc GRUB platform modules are needed for BIOS boot.
    _grub_dir_found=0
    for _d in /usr/lib/grub/i386-pc /usr/lib/grub2/i386-pc \
              /usr/share/grub/i386-pc /usr/share/grub2/i386-pc; do
        if [ -d "$_d" ]; then
            _grub_dir_found=1
            break
        fi
    done
    if [ "$_grub_dir_found" -eq 0 ]; then
        echo "${SCRIPT_NAME}: WARNING: GRUB i386-pc modules not found;" \
             "install grub-pc-bin (Debian/Ubuntu) or grub2-tools (Fedora/RHEL)." >&2
    fi
}

validate_iso() {
    _path="$1"
    if [ ! -f "$_path" ]; then
        die "ISO file not found: $_path"
    fi
    if [ ! -r "$_path" ]; then
        die "ISO file not readable: $_path"
    fi
    if [ ! -s "$_path" ]; then
        die "ISO file is empty: $_path"
    fi

    # ISO9660 primary volume descriptor signature at byte offset 32769.
    _sig=$(dd if="$_path" bs=1 skip=32769 count=5 2>/dev/null)
    if [ "$_sig" != "CD001" ]; then
        echo "${SCRIPT_NAME}: WARNING: $_path does not look like an ISO9660" \
             "image ('CD001' signature not found); continuing anyway." >&2
    fi
}

# ---------------------------------------------------------------------------
# Device selection & confirmation
# ---------------------------------------------------------------------------

list_devices() {
    echo "Available block devices (only removable/USB disks are safe):"
    echo ""
    if command -v lsblk >/dev/null 2>&1; then
        # -p prints full device paths (e.g. /dev/sda) so the name shown here
        # matches what the user must pass to -d.
        lsblk -dpno NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null || \
            lsblk -dp 2>/dev/null || lsblk -d 2>/dev/null
    fi
    echo ""
}

select_device() {
    if [ -n "$target_dev" ]; then
        if [ ! -b "$target_dev" ]; then
            die "Not a block device: ${target_dev}"
        fi
        return 0
    fi

    if [ "$yes_flag" -eq 1 ]; then
        die "Option -d <device> is required in non-interactive mode"
    fi

    list_devices
    printf "Enter target USB device (e.g. /dev/sde): "
    read -r target_dev

    if [ -z "$target_dev" ]; then
        die "No device entered"
    fi
    if [ ! -b "$target_dev" ]; then
        die "Not a block device: ${target_dev}"
    fi
}

# Refuse to erase anything that is not a whole removable/USB disk unless
# --force was given.
check_target_device() {
    _dev="$1"
    _name="${_dev##*/}"

    if [ -e "/sys/class/block/${_name}/partition" ]; then
        die "${_dev} is a partition, not a whole disk. Pass the whole disk (e.g. /dev/sde)."
    fi

    if [ "$force_flag" -eq 1 ]; then
        return 0
    fi

    _removable=""
    if [ -r "/sys/class/block/${_name}/removable" ]; then
        _removable=$(cat "/sys/class/block/${_name}/removable" 2>/dev/null)
    fi

    _transport=""
    if command -v lsblk >/dev/null 2>&1; then
        _transport=$(lsblk -ndo TRAN "$_dev" 2>/dev/null || true)
    fi

    if [ "$_removable" = "1" ] || [ "$_transport" = "usb" ]; then
        return 0
    fi

    die "${_dev} does not look like a removable/USB device. Refusing to erase it. Use --force to override."
}

_dev_size_bytes() {
    _name="${1##*/}"
    _size_file="/sys/class/block/${_name}/size"
    if [ ! -r "$_size_file" ]; then
        return 1
    fi
    _sectors=$(cat "$_size_file" 2>/dev/null)
    case "$_sectors" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            echo $((_sectors * 512))
            ;;
    esac
}

check_capacity() {
    _dev="$1"
    _iso="$2"

    _dev_size=$(_dev_size_bytes "$_dev") || return 0

    _iso_size=$(wc -c < "$_iso" 2>/dev/null)
    _iso_size=${_iso_size##* }
    case "$_iso_size" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac

    _needed=$((_iso_size + MIN_FREE_BYTES))
    if [ "$_dev_size" -lt "$_needed" ]; then
        die "Target ${_dev} is too small: need at least $((_needed / 1048576)) MiB, device has $((_dev_size / 1048576)) MiB."
    fi
}

confirm_destruction() {
    if [ "$yes_flag" -eq 1 ]; then
        return 0
    fi

    _size=""
    _model=""
    _transport=""
    if command -v lsblk >/dev/null 2>&1; then
        _size=$(lsblk -dno SIZE "$target_dev" 2>/dev/null || true)
        _model=$(lsblk -dno MODEL "$target_dev" 2>/dev/null || true)
        _transport=$(lsblk -ndo TRAN "$target_dev" 2>/dev/null || true)
    fi
    if [ -z "$_size" ]; then
        _bytes=$(_dev_size_bytes "$target_dev") || _bytes=""
        if [ -n "$_bytes" ]; then
            _size="$((_bytes / 1048576)) MiB"
        fi
    fi

    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  DESTRUCTIVE ACTION -- ALL DATA WILL BE ERASED"
    echo ""
    echo "  Device:  ${target_dev}"
    [ -n "$_size"  ] && echo "  Size:    ${_size}"
    [ -n "$_model" ] && echo "  Model:   ${_model}"
    [ -n "$_transport" ] && echo "  Bus:     ${_transport}"
    echo ""
    echo "  This will permanently destroy ALL data on this device."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    printf 'Type YES to continue: '
    read -r _confirm
    echo ""

    if [ "$_confirm" != "YES" ]; then
        echo "Aborted."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Temporary workspace
# ---------------------------------------------------------------------------

setup_workdir() {
    _tmp="${TMPDIR:-/tmp}"
    case "$_tmp" in
        */) _tmp="${_tmp%/}" ;;
    esac

    if command -v mktemp >/dev/null 2>&1; then
        WORK_DIR=$(mktemp -d "${_tmp}/win-usb.XXXXXX") || \
            die "Failed to create a temporary directory under ${_tmp}"
    else
        WORK_DIR="${_tmp}/win-usb.$$"
        (umask 077 && mkdir "$WORK_DIR") || die "Failed to create ${WORK_DIR}"
    fi
    if [ ! -d "$WORK_DIR" ]; then
        die "Temporary directory was not created"
    fi

    ISO_MNT="${WORK_DIR}/iso"
    DATA_MNT="${WORK_DIR}/data"
    BOOT_IMG="${WORK_DIR}/uefi-ntfs.img"

    mkdir -p "$ISO_MNT" "$DATA_MNT" || die "Failed to create mount points"
}

# ---------------------------------------------------------------------------
# Device preparation (unmount, partition, format)
# ---------------------------------------------------------------------------

unmount_device() {
    _dev="$1"

    echo "Unmounting any mounted partitions on ${_dev}..."
    _targets=$(_mounted_parts "$_dev")
    if [ -n "$_targets" ]; then
        printf '%s\n' "$_targets" | while read -r _part; do
            [ -n "$_part" ] || continue
            echo "  unmounting ${_part}"
            umount "$_part" 2>/dev/null || umount -l "$_part" 2>/dev/null || true
        done
    fi

    _still=$(_mounted_parts "$_dev")
    if [ -n "$_still" ]; then
        die "Partition(s) still mounted on ${_dev}:
${_still}"
    fi
}

# Emit the scripted fdisk command sequence that builds the GPT layout.
# Kept separate from partition_device() so tests can validate the exact
# sequence (and the partition sizes/types) without a real block device.
_fdisk_script() {
    printf '%s\n' \
        'g' \
        'n' '1' '' "${BOOT_PART_RESERVE}" \
        'n' '2' '' "${BOOT_PART_SIZE}" \
        'n' '3' '' '' \
        't' '1' '11' \
        't' '2' '1' \
        't' '3' '4' \
        'x' 'A' '3' 'r' \
        'w'
}

partition_device() {
    _dev="$1"
    echo "Partitioning ${_dev}..."

    # Remove any stale filesystem signatures so fdisk never has to prompt
    # (matters when re-running the script on the same USB device).
    if command -v wipefs >/dev/null 2>&1; then
        wipefs -a "$_dev" >/dev/null 2>&1 || true
    fi

    _fdisk_script | fdisk "$_dev"

    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        die "Partitioning failed on ${_dev} (fdisk returned $_rc)"
    fi

    partprobe "$_dev" 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>/dev/null || true
    fi

    _pb=$(_part_base "$_dev")
    _tries=0
    while [ "$_tries" -lt 10 ]; do
        if [ -b "${_pb}1" ] && [ -b "${_pb}2" ] && [ -b "${_pb}3" ]; then
            return 0
        fi
        _tries=$((_tries + 1))
        sleep 1
    done

    die "Partition verification failed: ${_pb}1, ${_pb}2 or ${_pb}3 not found"
}

# Formatting helpers take an explicit device/file path so tests can run the
# exact same mkfs invocations against scratch image files.
_format_ntfs() { mkfs.ntfs -f -F "$1"; }
_format_vfat() { mkfs.vfat -F 32 "$1"; }

format_partitions() {
    _dev="$1"
    _pb=$(_part_base "$_dev")

    echo "Formatting partition 1 (NTFS) on ${_pb}1..."
    if ! _format_ntfs "${_pb}1"; then
        die "Failed to format ${_pb}1 as NTFS"
    fi

    echo "Formatting partition 2 (FAT32) on ${_pb}2..."
    if ! _format_vfat "${_pb}2"; then
        die "Failed to format ${_pb}2 as FAT32"
    fi
}

# ---------------------------------------------------------------------------
# ISO mounting and file copy
# ---------------------------------------------------------------------------

mount_iso() {
    _path="$1"
    echo "Mounting ISO: ${_path}..."
    mkdir -p "${ISO_MNT}" || die "Failed to create mount point ${ISO_MNT}"

    # Windows ISOs are commonly ISO9660+UDF hybrids where the ISO9660 tree is
    # a bare stub (e.g. only README.TXT) and the real payload lives in UDF.
    # Prefer the UDF view, then fall back to auto-detection / ISO9660.
    if mount -t udf -o loop,ro "$_path" "${ISO_MNT}" 2>/dev/null; then
        :
    elif mount -o loop,ro "$_path" "${ISO_MNT}" 2>/dev/null; then
        :
    elif mount -t iso9660 -o loop,ro "$_path" "${ISO_MNT}" 2>/dev/null; then
        :
    else
        die "Failed to mount ISO at ${ISO_MNT}"
    fi

    if [ ! -d "${ISO_MNT}/sources" ]; then
        die "Mounted ISO has no 'sources' directory -- wrong filesystem view, or not a Windows ISO"
    fi
}

mount_data_partition() {
    _dev="$1"
    _pb=$(_part_base "$_dev")
    echo "Mounting data partition ${_pb}1..."
    mkdir -p "${DATA_MNT}" || die "Failed to create mount point ${DATA_MNT}"

    if ! mount -t ntfs-3g "${_pb}1" "${DATA_MNT}" 2>/dev/null; then
        if ! mount -t ntfs3 "${_pb}1" "${DATA_MNT}" 2>/dev/null; then
            mount "${_pb}1" "${DATA_MNT}" || \
                die "Failed to mount ${_pb}1 at ${DATA_MNT}"
        fi
    fi

    # Make sure the filesystem is actually writable (a read-only NTFS mount
    # would otherwise fail halfway through the copy).
    if ! ( : > "${DATA_MNT}/.win-usb-write-probe" ) 2>/dev/null; then
        die "${DATA_MNT} is not writable (NTFS mounted read-only?)"
    fi
    rm -f "${DATA_MNT}/.win-usb-write-probe" 2>/dev/null || true
}

copy_iso_contents() {
    echo "Copying Windows installation files to USB (this may take a while)..."
    # "/." copies the directory contents including hidden dotfiles.
    cp -R "${ISO_MNT}/." "${DATA_MNT}/" || {
        die "Failed to copy ISO contents to ${DATA_MNT}"
    }
    sync
}

# ---------------------------------------------------------------------------
# Boot image and GRUB installation
# ---------------------------------------------------------------------------

download_boot_image() {
    echo "Downloading Rufus UEFI:NTFS boot image..."

    _downloaded=0
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$BOOT_IMG" "$UEFI_NTFS_URL" && _downloaded=1
    fi
    # Fall back to curl when wget is absent OR when it was present but failed.
    if [ "$_downloaded" -ne 1 ] && command -v curl >/dev/null 2>&1; then
        # -L follows GitHub's redirect; -f fails instead of saving an error page.
        curl -fsSL --retry 3 -o "$BOOT_IMG" "$UEFI_NTFS_URL" && _downloaded=1
    fi

    if [ "$_downloaded" -ne 1 ]; then
        die "Failed to download boot image from ${UEFI_NTFS_URL}"
    fi

    if [ ! -s "$BOOT_IMG" ]; then
        die "Downloaded image is empty or missing: ${BOOT_IMG}"
    fi

    _actual=$(_sha256 "$BOOT_IMG") || die "Failed to compute boot image checksum"
    if [ "$_actual" != "$UEFI_NTFS_SHA256" ]; then
        die "Boot image checksum mismatch:
  expected ${UEFI_NTFS_SHA256}
  actual   ${_actual}
Set WIN_USB_BOOT_IMG_URL and WIN_USB_BOOT_IMG_SHA256 to update the pin."
    fi
}

write_boot_image() {
    _dev="$1"
    _pb=$(_part_base "$_dev")
    echo "Writing UEFI:NTFS boot image to ${_pb}2..."
    if ! dd if="$BOOT_IMG" of="${_pb}2" bs=1024k; then
        die "Failed to write boot image to ${_pb}2"
    fi
    sync
}

install_grub() {
    _dev="$1"
    echo "Installing GRUB bootloader to ${_dev}..."

    if command -v grub-install >/dev/null 2>&1; then
        _grub=grub-install
    elif command -v grub2-install >/dev/null 2>&1; then
        _grub=grub2-install
    else
        die "No GRUB installer found (grub-install or grub2-install)"
    fi

    # An empty --boot-directory silently defaults to the host's /boot, which
    # must never happen.
    if [ -z "${DATA_MNT:-}" ]; then
        die "GRUB boot directory is not set (internal error)"
    fi

    if ! "$_grub" --target=i386-pc --boot-directory="${DATA_MNT}" \
            --force "$_dev"; then
        die "GRUB installation failed ($_grub)"
    fi

    # grub-install writes to <boot-directory>/grub (Debian) or
    # <boot-directory>/grub2 (Fedora/RHEL); find whichever it created.
    _grub_cfg_dir=""
    for _d in "${DATA_MNT}/grub" "${DATA_MNT}/grub2" "${DATA_MNT}/boot/grub"; do
        if [ -d "$_d" ]; then
            _grub_cfg_dir="$_d"
            break
        fi
    done
    if [ -z "$_grub_cfg_dir" ]; then
        die "GRUB directory not found under ${DATA_MNT}"
    fi

    echo "Writing GRUB menu to ${_grub_cfg_dir}/grub.cfg..."
    cat > "${_grub_cfg_dir}/grub.cfg" <<'GRUBCFG'
# Generated by win-usb.sh.  Chain-load the Windows installer (BIOS).
set timeout=5
set default=0

menuentry "Windows Installer" {
    insmod part_gpt
    insmod ntfs
    insmod ntldr
    insmod search_fs_file
    search --no-floppy --set=root --file /bootmgr
    ntldr /bootmgr
}
GRUBCFG
}

# ---------------------------------------------------------------------------
# Finalisation
# ---------------------------------------------------------------------------

finish() {
    sync
    _umount_silent "${DATA_MNT}"

    echo ""
    echo "================================================================"
    echo "  SUCCESS: Bootable Windows USB created on ${target_dev}."
    echo ""
    echo "  You can now plug the USB into your target machine and"
    echo "  boot from it. You may need to:"
    echo "    - Enable USB boot in BIOS/UEFI"
    echo "    - Disable Secure Boot"
    echo "    - Select the correct boot device"
    echo "================================================================"
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    check_root
    check_deps

    if [ -z "$iso_path" ]; then
        die "A Windows ISO is required (use -i <iso>; see ${SCRIPT_NAME} -h)"
    fi
    validate_iso "$iso_path"

    trap 'cleanup; exit 1' INT TERM
    trap cleanup EXIT

    setup_workdir

    select_device
    check_target_device "$target_dev"
    check_capacity "$target_dev" "$iso_path"
    confirm_destruction
    unmount_device "$target_dev"
    partition_device "$target_dev"
    # A desktop auto-mounter (udisks) may mount new partitions as soon as
    # udev reports them; evict anything it grabbed before formatting.
    unmount_device "$target_dev"
    format_partitions "$target_dev"
    mount_iso "$iso_path"
    mount_data_partition "$target_dev"
    copy_iso_contents

    _umount_silent "${ISO_MNT}"

    download_boot_image
    # Never dd over a partition that got auto-mounted after format.
    _unmount_device_path "$(_part_base "$target_dev")2"
    write_boot_image "$target_dev"
    install_grub "$target_dev"
    finish
}

main "$@"