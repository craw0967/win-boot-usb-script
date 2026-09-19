#!/bin/sh
# SPDX-License-Identifier: MIT
# tests/run-loopback.sh -- root-only end-to-end tests on a loop device
#
# Exercises the device-side functions (partition_device, format_partitions,
# mount_data_partition, copy_iso_contents, write_boot_image) and their failure
# branches without needing a physical USB stick.  A sparse file is attached
# with losetup --partscan and detached afterwards.
#
# Usage:  sudo sh tests/run-loopback.sh
# Exit:   0 if no assertions failed, 1 otherwise.
#
# Note: requires root, losetup, and (for the copy test) genisoimage.  If a
# prerequisite is missing the affected checks are skipped, not failed.

# `cmd && fallback || true` is the intended cleanup idiom.
# shellcheck disable=SC2015,SC2016
set -u

self=$0
case "$self" in */*) here=${self%/*} ;; *) here=. ;; esac
ROOT=$(cd "$here/.." && pwd) || exit 1
SCRIPT="$ROOT/win-usb.sh"
[ -f "$SCRIPT" ] || { echo "cannot find win-usb.sh under $ROOT"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/win-usb-loop.XXXXXX") || exit 1
LIB="$WORK/lib.sh"
IMG="$WORK/disk.img"
LOOP=""
P1MNT="$WORK/p1"

sed '/^main "\$@"$/d' "$SCRIPT" > "$LIB" || exit 1

_detach() {
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
}
trap _detach EXIT INT TERM

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s :: %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s :: %s\n' "$1" "$2"; }
assert_rc() { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1" "expected rc $2 got $3"; fi; }
assert_in() { case "$3" in *"$2"*) ok "$1" ;; *) no "$1" "missing [$2] in: $3" ;; esac; }
run_lib() { sh -c ". '$LIB'; $1"; }

echo "############################################################"
echo "# win-usb.sh loopback test run"
echo "############################################################"
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }
command -v losetup >/dev/null 2>&1 || { echo "FATAL: losetup not found"; exit 1; }

echo "== attaching 1.5 GiB sparse image =="
truncate -s 1536M "$IMG" || { echo "FATAL: truncate failed"; exit 1; }
LOOP=$(losetup --partscan --find --show "$IMG" 2>/dev/null) || LOOP=""
if [ -z "$LOOP" ]; then
    echo "FATAL: losetup could not attach $IMG (loop devices unavailable?)"
    exit 1
fi
echo "loop: $LOOP"
PB=$(run_lib "_part_base '$LOOP'" 2>/dev/null)
[ -n "$PB" ] || PB="${LOOP}p"
echo

# ===========================================================================
echo "--- partition_device (happy path) ---"
out=$(run_lib "partition_device '$LOOP'" 2>&1); rc=$?
assert_rc "L1 partition_device exit 0" 0 "$rc"
for _i in 1 2 3; do
    if [ -b "${PB}${_i}" ]; then ok "L1 partition ${PB}${_i} exists"; else no "L1 partition ${PB}${_i} exists" "missing"; fi
done
_lay=$(fdisk -l "$LOOP" 2>/dev/null)
assert_in "L1 p1 Microsoft basic data" "Microsoft basic data" "$_lay"
assert_in "L1 p2 EFI System" "EFI System" "$_lay"
assert_in "L1 p3 BIOS boot" "BIOS boot" "$_lay"

echo "--- format_partitions (happy path) ---"
out=$(run_lib "format_partitions '$LOOP'" 2>&1); rc=$?
assert_rc "L2 format_partitions exit 0" 0 "$rc"
assert_in "L2 p1 formatted NTFS" 'TYPE="ntfs"' "$(blkid "${PB}1" 2>/dev/null)"
assert_in "L2 p2 formatted vfat" 'TYPE="vfat"' "$(blkid "${PB}2" 2>/dev/null)"

echo "--- mount_data_partition writability probe ---"
mkdir -p "$P1MNT"
out=$(run_lib "DATA_MNT='$P1MNT'; mount_data_partition '$LOOP'; : > \"\$DATA_MNT/probe-ok\"; echo WROTE" 2>&1); rc=$?
assert_rc "L3 mount_data_partition exit 0" 0 "$rc"
assert_in "L3 data partition writable" "WROTE" "$out"
[ -f "$P1MNT/probe-ok" ] && ok "L3 probe file present" || no "L3 probe file present" "missing"
rm -f "$P1MNT/probe-ok" 2>/dev/null || true
umount "$P1MNT" 2>/dev/null || true

echo "--- mount_iso + copy_iso_contents (incl. hidden files) ---"
if command -v genisoimage >/dev/null 2>&1; then
    mkdir -p "$WORK/src/sources" "$WORK/src/boot"
    : > "$WORK/src/sources/install.wim"
    printf 'x' > "$WORK/src/boot/bootmgr"
    printf 'dot\n' > "$WORK/src/.hidden"
    genisoimage -quiet -R -J -o "$WORK/tiny.iso" "$WORK/src" 2>/dev/null
    ISOM="$WORK/isomnt"; mkdir -p "$ISOM"
    out=$(run_lib "ISO_MNT='$ISOM'; DATA_MNT='$P1MNT'; mount_iso '$WORK/tiny.iso'; mount_data_partition '$LOOP'; copy_iso_contents; ls -A \"\$DATA_MNT\"; umount \"\$ISO_MNT\"; umount \"\$DATA_MNT\"" 2>&1); rc=$?
    assert_rc "L4 mount/copy exit 0" 0 "$rc"
    assert_in "L4 sources/ copied" "sources" "$out"
    assert_in "L4 boot/ copied" "boot" "$out"
    assert_in "L4 hidden file copied" ".hidden" "$out"
else
    skip "L4 mount_iso + copy_iso_contents" "genisoimage unavailable"
fi
umount "$P1MNT" 2>/dev/null || true

echo "--- write_boot_image ---"
BOOT="$WORK/boot.img"
if command -v curl >/dev/null 2>&1 && run_lib "BOOT_IMG='$BOOT'; download_boot_image" >/dev/null 2>&1; then
    out=$(run_lib "BOOT_IMG='$BOOT'; write_boot_image '$LOOP'; echo DONE" 2>&1); rc=$?
    assert_rc "L5 write_boot_image exit 0" 0 "$rc"
    assert_in "L5 p2 label RUFUS_BOOT" "RUFUS_BOOT" "$(dd if="${PB}2" bs=1 skip=43 count=11 2>/dev/null | tr -d '\000')"
else
    # Synthesize a 1 MiB payload and verify dd wrote exactly it.
    dd if=/dev/urandom of="$BOOT" bs=1024k count=1 2>/dev/null
    _want=$(sha256sum "$BOOT" | awk '{print $1}')
    out=$(run_lib "BOOT_IMG='$BOOT'; write_boot_image '$LOOP'; echo DONE" 2>&1); rc=$?
    assert_rc "L5 write_boot_image exit 0" 0 "$rc"
    _got=$(dd if="${PB}2" bs=1024k count=1 2>/dev/null | sha256sum | awk '{print $1}')
    if [ "$_want" = "$_got" ]; then ok "L5 p2 starts with the boot image bytes"; else no "L5 p2 starts with the boot image bytes" "mismatch"; fi
fi

# ===========================================================================
echo "--- failure branches (fault injection) ---"
stub() { _d="$WORK/stub.$1"; mkdir -p "$_d"; printf '#!/bin/sh\nexit 1\n' > "$_d/$1"; chmod +x "$_d/$1"; echo "$_d"; }
EMPTYBIN="$WORK/emptybin"; mkdir -p "$EMPTYBIN"

_fault() { # name expected-message shell-body path [append|only]
    _name=$1; _msg=$2; _body=$3; _path=$4; _mode=${5:-append}
    if [ "$_mode" = "only" ]; then
        _faultpath="$_path"
    else
        _faultpath="$_path:$PATH"
    fi
    out=$(sh -c ". '$LIB'; PATH='$_faultpath'; $_body" 2>&1); rc=$?
    assert_rc "$_name exits 1" 1 "$rc"
    assert_in "$_name message" "$_msg" "$out"
}

_fault "L6 fdisk failure aborts" "Partitioning failed" "partition_device '$LOOP'" "$(stub fdisk)"
_fault "L7 mkfs.ntfs failure aborts" "Failed to format" "format_partitions '$LOOP'" "$(stub mkfs.ntfs)"
# mkfs.ntfs must succeed then mkfs.vfat fail: a stub dir where only vfat fails.
_d4="$WORK/stub.vfatonfy"; mkdir -p "$_d4"; printf '#!/bin/sh\nexit 1\n' > "$_d4/mkfs.vfat"; chmod +x "$_d4/mkfs.vfat"
_fault "L8 mkfs.vfat failure aborts" "Failed to format" "format_partitions '$LOOP'" "$_d4"
_fault "L9 cp failure aborts" "Failed to copy" "ISO_MNT='$WORK/nope'; DATA_MNT='$WORK/nope2'; mkdir -p \"\$ISO_MNT\" \"\$DATA_MNT\"; copy_iso_contents" "$(stub cp)"
_fault "L10 dd failure aborts" "Failed to write boot image" "BOOT_IMG='$BOOT'; write_boot_image '$LOOP'" "$(stub dd)"
_fault "L11 mount failure aborts" "Failed to mount" "DATA_MNT='$WORK/mnt-fail'; mount_data_partition '$LOOP'" "$(stub mount)"
# PATH-only (no real tools appended) so grub2-install is genuinely absent.
_fault "L12 missing grub installer aborts" "No GRUB installer found" "install_grub '$LOOP'" "$EMPTYBIN" only

echo
echo "############################################################"
printf 'LOOPBACK RESULT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
echo "############################################################"
[ "$FAIL" -eq 0 ]