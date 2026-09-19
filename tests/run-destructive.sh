#!/bin/sh
# SPDX-License-Identifier: MIT
# tests/run-destructive.sh -- root-required destructive tests for win-usb.sh
#
# Covers the checks the non-root suite cannot: the real full workflow and its
# on-disk artifacts, the ISO filesystem-view guards, auto-mount eviction, the
# re-run path, and the pre-mounted / stuck-mount handling.
#
# Required environment:
#   WIN_USB_DEV       whole USB disk to erase, e.g. /dev/sda
#   WIN_USB_ISO       Windows ISO path
#   CONFIRM_ERASE=yes explicit acknowledgement that the device is expendable
#
# Optional environment:
#   RERUN=1           run the workflow a second time (re-run test)
#   WIN_USB_MODEL     substring the device model must contain (extra safety)
#   MTEST=1           build tiny test ISOs to exercise the mount_iso guards
#
# Usage:
#   sudo CONFIRM_ERASE=yes WIN_USB_DEV=/dev/sda WIN_USB_ISO=Win11.iso \
#        sh tests/run-destructive.sh
#
# Exit: 0 if no assertions failed, 1 otherwise.

# Suppressed deliberately: ls/case-folding of ISO entry names is fine here, and
# `cmd && fallback || true` is the intended cleanup idiom.
# shellcheck disable=SC2012,SC2015,SC2018,SC2019,SC2016
set -u

DEV=${WIN_USB_DEV:-}
ISO=${WIN_USB_ISO:-}
MTEST=${MTEST:-0}
RERUN=${RERUN:-0}

self=$0
case "$self" in */*) here=${self%/*} ;; *) here=. ;; esac
ROOT=$(cd "$here/.." && pwd) || exit 1
SCRIPT="$ROOT/win-usb.sh"
[ -f "$SCRIPT" ] || { echo "cannot find win-usb.sh under $ROOT"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/win-usb-destr.XXXXXX") || exit 1
LIB="$WORK/lib.sh"
sed '/^main "\$@"$/d' "$SCRIPT" > "$LIB" || exit 1
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT INT TERM

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s :: %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s :: %s\n' "$1" "$2"; }
assert_rc() { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1" "expected rc $2 got $3"; fi; }
assert_in() { case "$3" in *"$2"*) ok "$1" ;; *) no "$1" "missing [$2] in: $3" ;; esac; }
assert_not_in() { case "$3" in *"$2"*) no "$1" "unexpected [$2] in: $3" ;; *) ok "$1" ;; esac; }
run_lib() { sh -c ". '$LIB'; $1"; }

umount_safe() { umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null || true; }
is_mounted_at() { awk -v m="$1" '$2 == m { found = 1 } END { exit(found ? 0 : 1) }' /proc/self/mounts 2>/dev/null; }
unmount_dev_parts() {
    awk -v d="$1" 'index($1, d) == 1 && substr($1, length(d) + 1) ~ /^[0-9]+$/ { print $1 }' \
        /proc/self/mounts 2>/dev/null | while read -r _p; do
        umount "$_p" 2>/dev/null || umount -l "$_p" 2>/dev/null || true
    done
}

# --- gates -----------------------------------------------------------------
echo "############################################################"
echo "# win-usb.sh destructive test run"
echo "############################################################"
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }
[ "${CONFIRM_ERASE:-no}" = "yes" ] || { echo "FATAL: set CONFIRM_ERASE=yes"; exit 1; }
[ -n "$DEV" ] || { echo "FATAL: set WIN_USB_DEV"; exit 1; }
[ -n "$ISO" ] || { echo "FATAL: set WIN_USB_ISO"; exit 1; }
[ -b "$DEV" ] || { echo "FATAL: not a block device: $DEV"; exit 1; }
[ -f "$ISO" ] || { echo "FATAL: ISO not found: $ISO"; exit 1; }

_name=${DEV##*/}
if [ -e "/sys/class/block/$_name/partition" ]; then
    echo "FATAL: $DEV is a partition, not a whole disk"; exit 1
fi
_tran=$(lsblk -ndo TRAN "$DEV" 2>/dev/null || true)
if [ "$_tran" != "usb" ]; then
    echo "FATAL: $DEV is not USB (TRAN='$_tran')"; exit 1
fi
for _mp in / /boot /boot/efi /home; do
    _src=$(findmnt -no SOURCE "$_mp" 2>/dev/null || true)
    case "$_src" in "$DEV"*) echo "FATAL: $DEV backs $_mp -- refusing"; exit 1 ;; esac
done
_model=$(lsblk -ndo MODEL "$DEV" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
[ -n "$_model" ] || _model=$(cat "/sys/class/block/$_name/device/model" 2>/dev/null || true)
if [ -n "${WIN_USB_MODEL:-}" ]; then
    case "$_model" in *"$WIN_USB_MODEL"*) ;; *) echo "FATAL: model '$_model' lacks '$WIN_USB_MODEL'"; exit 1 ;; esac
fi

echo "== target =="
lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL,SERIAL "$DEV"
echo "model: $_model"
echo

# ===========================================================================
echo "--- SECTION 13: mount_iso filesystem-view guards (MTEST=1) ---"
if [ "$MTEST" -eq 1 ] && command -v genisoimage >/dev/null 2>&1; then
    mkdir -p "$WORK/ok/sources" "$WORK/ok/boot" "$WORK/bad"
    : > "$WORK/ok/sources/install.wim"
    printf 'x' > "$WORK/ok/boot/bootmgr"
    printf 'nothing here\n' > "$WORK/bad/README.TXT"
    genisoimage -quiet -o "$WORK/ok.iso" "$WORK/ok" 2>/dev/null
    genisoimage -quiet -o "$WORK/bad.iso" "$WORK/bad" 2>/dev/null

    out=$(sh -c ". '$LIB'; ISO_MNT='$WORK/iso-ok'; mkdir -p \"\$ISO_MNT\"; mount_iso '$WORK/ok.iso' && echo MOUNTED; umount \"\$ISO_MNT\"" 2>&1); rc=$?
    assert_rc "13.3 non-UDF ISO with sources mounts via fallback" 0 "$rc"
    assert_in "13.3 mounted" "MOUNTED" "$out"

    out=$(sh -c ". '$LIB'; ISO_MNT='$WORK/iso-bad'; mkdir -p \"\$ISO_MNT\"; mount_iso '$WORK/bad.iso'" 2>&1); rc=$?
    assert_rc "13.4 ISO with no sources/ aborts" 1 "$rc"
    assert_in "13.4 message" "no 'sources' directory" "$out"
    if is_mounted_at "$WORK/iso-bad"; then
        no "13.4b aborted mount is cleaned up" "still mounted at $WORK/iso-bad"
        umount_safe "$WORK/iso-bad"
    else
        ok "13.4b aborted mount is cleaned up"
    fi
else
    skip "13.3/13.4 mount_iso guards" "set MTEST=1 with genisoimage to enable"
fi

# Real ISO must expose the full payload, not the ISO9660 stub.
_iso_type=$(blkid -s TYPE -o value "$ISO" 2>/dev/null || true)
out=$(sh -c ". '$LIB'; ISO_MNT='$WORK/iso-real'; mkdir -p \"\$ISO_MNT\"; mount_iso '$ISO'; findmnt -no FSTYPE --target \"\$ISO_MNT\"; [ -d \"\$ISO_MNT/sources\" ] && echo HAS_SOURCES; [ -f \"\$ISO_MNT/README.TXT\" ] && echo HAS_STUB; umount \"\$ISO_MNT\"" 2>&1); rc=$?
assert_rc "13.2 real ISO mounts" 0 "$rc"
assert_in "13.2 stub coexistence: real ISO has sources/" "HAS_SOURCES" "$out"
if [ "$_iso_type" = "udf" ]; then
    assert_in "13.1 real hybrid ISO mounted as udf (not the ISO9660 stub)" "udf" "$out"
else
    skip "13.1 real ISO mounted as udf" "blkid type is '${_iso_type:-unknown}'"
fi

# ===========================================================================
echo "--- SECTION 10.2: pre-mounted target is handled ---"
unmount_dev_parts "$DEV"
PREMNT="$WORK/pre"; mkdir -p "$PREMNT"
PRE_MOUNTED=0
if [ -b "${DEV}1" ]; then
    if mount -t ntfs-3g -o ro "${DEV}1" "$PREMNT" 2>/dev/null || mount -o ro "${DEV}1" "$PREMNT" 2>/dev/null; then
        PRE_MOUNTED=1
        ok "10.2 pre-mounted ${DEV}1 before the run"
    fi
fi
[ "$PRE_MOUNTED" -eq 0 ] && skip "10.2 pre-mounted target" "${DEV}1 not mountable yet (first run)"

echo
echo "--- SECTION 9: full workflow ---"
date -u +"start: %FT%TZ"
_t0=$(date +%s)
sh "$SCRIPT" -y -i "$ISO" -d "$DEV"
_rc=$?
_t1=$(date +%s)
echo "script rc=$_rc elapsed=$((_t1 - _t0))s"
assert_rc "9.2 workflow exit 0" 0 "$_rc"

if [ "$PRE_MOUNTED" -eq 1 ]; then
    if is_mounted_at "$PREMNT"; then
        no "10.2 script unmounted the pre-mounted partition" "still mounted at $PREMNT"
        umount_safe "$PREMNT"
    else
        ok "10.2 script unmounted the pre-mounted partition"
    fi
fi

partprobe "$DEV" 2>/dev/null || true
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

echo "--- SECTION 9.3: layout ---"
_lay=$(fdisk -l "$DEV" 2>/dev/null)
printf '%s\n' "$_lay"
assert_in "9.3 GPT disklabel" "gpt" "$(printf '%s' "$_lay" | tr 'A-Z' 'a-z')"
assert_in "9.3 p1 Microsoft basic data" "Microsoft basic data" "$_lay"
assert_in "9.3 p2 EFI System" "EFI System" "$_lay"
assert_in "9.3 p3 BIOS boot" "BIOS boot" "$_lay"
_p2line=$(printf '%s\n' "$_lay" | awk '/EFI System/{print}')
assert_in "9.3 p2 is 40 MiB" "40M" "$_p2line"
_b1=$(blkid "${DEV}1" 2>/dev/null); _b2=$(blkid "${DEV}2" 2>/dev/null)
assert_in "9.3 p1 is NTFS" 'TYPE="ntfs"' "$_b1"
assert_in "9.3 p2 is FAT" 'TYPE="vfat"' "$_b2"

echo "--- SECTION 9.4: UEFI:NTFS boot image ---"
_label=$(dd if="${DEV}2" bs=1 skip=43 count=11 2>/dev/null | tr -d '\000')
assert_in "9.4 p2 holds RUFUS_BOOT image" "RUFUS_BOOT" "$_label"

echo "--- SECTION 9.8: GRUB in MBR ---"
_mbr=$(dd if="$DEV" bs=512 count=1 2>/dev/null | strings)
if printf '%s' "$_mbr" | grep -qi grub; then ok "9.8 GRUB signature in MBR"; else no "9.8 GRUB signature in MBR" "not found"; fi

echo "--- SECTION 9.11: UEFI bootloader present on p2 ---"
unmount_dev_parts "$DEV"
P2MNT="$WORK/p2"; mkdir -p "$P2MNT"
if mount -o ro "${DEV}2" "$P2MNT" 2>/dev/null; then
    _efi=$(find "$P2MNT" -iname 'BOOTX64.EFI' 2>/dev/null | head -1)
    if [ -n "$_efi" ]; then ok "9.11 p2 contains EFI/BOOT/BOOTX64.EFI"; else no "9.11 p2 contains BOOTX64.EFI" "not found"; fi
    umount_safe "$P2MNT"
else
    no "9.11 mount p2" "could not mount ${DEV}2"
fi

echo "--- SECTION 9.12: GRUB core image embedded in p3 ---"
# A GRUB i386-pc core image has LZMA-compressed modules, so it contains no
# literal "grub"/"core" strings.  Its first sector (diskboot.img) carries the
# markers "loading", "Geom" and "Read", which is what we look for.
dd if="${DEV}3" bs=512 count=64 of="$WORK/p3.bin" 2>/dev/null
_p3_nz=$(tr -d '\000' < "$WORK/p3.bin" | wc -c)
echo "p3 non-zero bytes (first 32 KiB): $_p3_nz"
if strings "$WORK/p3.bin" 2>/dev/null | grep -qE 'Geom|loading'; then
    ok "9.12 p3 contains GRUB core image"
elif [ "$_p3_nz" -gt 0 ]; then
    no "9.12 p3 contains GRUB core image" "p3 is non-empty but has no GRUB marker (possible blocklist install?)"
else
    no "9.12 p3 contains GRUB core image" "p3 is empty -- core.img was not embedded"
fi

echo "--- SECTION 9.5/9.7/9.13/9.14: p1 contents, config, install image, probe ---"
unmount_dev_parts "$DEV"
P1MNT="$WORK/p1"; IMNT="$WORK/iso"; mkdir -p "$P1MNT" "$IMNT"
if mount -t ntfs-3g -o ro "${DEV}1" "$P1MNT" 2>/dev/null || mount -o ro "${DEV}1" "$P1MNT" 2>/dev/null; then
    for _f in bootmgr sources boot efi; do
        _hit=$(find "$P1MNT" -maxdepth 1 -iname "$_f" 2>/dev/null | head -1)
        [ -n "$_hit" ] && ok "9.5 p1 has $_f" || no "9.5 p1 has $_f" "missing"
    done
    _cfg=$(find "$P1MNT" -maxdepth 2 -name grub.cfg 2>/dev/null | head -1)
    if [ -n "$_cfg" ]; then
        ok "9.7 grub.cfg present (${_cfg#"$P1MNT"/})"
        grep -q 'ntldr /bootmgr' "$_cfg" && ok "9.7 grub.cfg chain-loads bootmgr" || no "9.7 grub.cfg content" "no ntldr line"
        grep -q 'menuentry' "$_cfg" && ok "9.7 grub.cfg has a menuentry" || no "9.7 grub.cfg has a menuentry" "missing"
    else
        no "9.7 grub.cfg present" "not found"
    fi
    if [ -e "$P1MNT/.win-usb-write-probe" ]; then
        no "9.14 write-probe file removed" "left behind on p1"
    else
        ok "9.14 write-probe file removed"
    fi
    if mount -o loop,ro "$ISO" "$IMNT" 2>/dev/null; then
        _i_img=$(find "$IMNT/sources" -maxdepth 1 -iname 'install.*' 2>/dev/null | head -1)
        _p_img=$(find "$P1MNT/sources" -maxdepth 1 -iname 'install.*' 2>/dev/null | head -1)
        if [ -n "$_i_img" ] && [ -n "$_p_img" ]; then
            _isz=$(wc -c < "$_i_img" | awk '{print $1}')
            _psz=$(wc -c < "$_p_img" | awk '{print $1}')
            if [ "$_isz" = "$_psz" ]; then ok "9.13 install image size matches ISO ($_psz bytes)"; else no "9.13 install image size" "iso=$_isz usb=$_psz"; fi
        else
            no "9.13 install image found" "iso='${_i_img:-none}' usb='${_p_img:-none}'"
        fi
        ls -A "$IMNT" 2>/dev/null | tr 'A-Z' 'a-z' | sort > "$WORK/iso.list"
        ls -A "$P1MNT" 2>/dev/null | tr 'A-Z' 'a-z' | sort > "$WORK/usb.list"
        _missing=$(comm -23 "$WORK/iso.list" "$WORK/usb.list" 2>/dev/null)
        if [ -z "$_missing" ]; then ok "9.6 all ISO root entries copied"; else no "9.6 all ISO root entries copied" "missing: $(printf '%s' "$_missing" | tr '\n' ' ')"; fi
        umount_safe "$IMNT"
    else
        no "9.5/9.6 ISO comparison" "could not mount ISO"
    fi
    umount_safe "$P1MNT"
else
    no "9.5/9.7 p1 mount" "could not mount ${DEV}1"
fi

echo "--- SECTION 10.4: auto-mount eviction ---"
unmount_dev_parts "$DEV"
J="$WORK/p2j"; mkdir -p "$J"
if mount -o ro "${DEV}2" "$J" 2>/dev/null || mount "${DEV}2" "$J" 2>/dev/null; then
    if awk -v d="${DEV}2" '$1==d{found=1} END{exit !found}' /proc/self/mounts; then
        run_lib "_unmount_device_path '${DEV}2'" >/dev/null 2>&1
        if awk -v d="${DEV}2" '$1==d{found=1} END{exit !found}' /proc/self/mounts; then
            no "10.4 _unmount_device_path evicts a mounted partition" "still mounted"
            umount_safe "$J"
        else
            ok "10.4 _unmount_device_path evicts a mounted partition"
        fi
    else
        no "10.4 mount ${DEV}2" "mount reported success but not in mounts"
    fi
else
    no "10.4 mount ${DEV}2" "could not mount"
fi

echo "--- SECTION 10.3: stuck mount aborts rather than corrupting ---"
unmount_dev_parts "$DEV"
SM="$WORK/sm"; SMNT="$WORK/smnt"; mkdir -p "$SM" "$SMNT"
printf '#!/bin/sh\nexit 1\n' > "$SM/umount"; chmod +x "$SM/umount"; ln -sf "$(command -v awk)" "$SM/awk"
if mount -t ntfs-3g "${DEV}1" "$SMNT" 2>/dev/null || mount "${DEV}1" "$SMNT" 2>/dev/null; then
    out=$(sh -c ". '$LIB'; PATH='$SM':\$PATH; unmount_device '$DEV'" 2>&1); rc=$?
    assert_rc "10.3 unmount failure aborts" 1 "$rc"
    assert_in "10.3 message" "still mounted" "$out"
    umount_safe "$SMNT"
else
    skip "10.3 stuck mount aborts" "could not mount ${DEV}1"
fi

# ===========================================================================
if [ "$RERUN" -eq 1 ]; then
    echo "--- SECTION 10.1: re-run ---"
    sh "$SCRIPT" -y -i "$ISO" -d "$DEV"
    assert_rc "10.1 second run exit 0" 0 "$?"
fi

echo
echo "############################################################"
printf 'DESTRUCTIVE RESULT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
echo "############################################################"
[ "$FAIL" -eq 0 ]