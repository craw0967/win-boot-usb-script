#!/bin/sh
# SPDX-License-Identifier: MIT
# tests/run-tests.sh -- non-destructive test suite for win-usb.sh
#
# Runs TEST.md sections 1-8 and 12 without a USB device.  Some checks need a
# normal (non-root) user; when run as root those are skipped with a notice.
#
# Usage:  sh tests/run-tests.sh
# Exit:   0 if no assertions failed, 1 otherwise.

# The single-quoted snippets below are deliberately passed verbatim to an
# inner `sh -c` (so they evaluate against the sourced library).
# shellcheck disable=SC2016
set -u

self=$0
case "$self" in
    */*) here=${self%/*} ;;
    *)   here=. ;;
esac
ROOT=$(cd "$here/.." && pwd) || exit 1
SCRIPT="$ROOT/win-usb.sh"
[ -f "$SCRIPT" ] || { echo "cannot find win-usb.sh under $ROOT"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/win-usb-tests.XXXXXX") || exit 1
LIB="$WORK/lib.sh"
FAKE="$WORK/fakebin"
CURLONLY="$WORK/curlonly"
WGETONLY="$WORK/wgetonly"
FALLBACK="$WORK/fallback"
OSSLONLY="$WORK/osslonly"
SHASUMONLY="$WORK/shasumonly"
AWKONLY="$WORK/awkonly"
NOMKT="$WORK/nomkt"
CATONLY="$WORK/catonly"
IDSTUB="$WORK/idstub"

# Sourceable copy with the final "main \"$@\"" invocation removed.
sed '/^main "\$@"$/d' "$SCRIPT" > "$LIB" || exit 1

# Pinned boot-image URL, taken from the script itself so the test follows the pin.
UEFI_TEST_URL=$(sh -c ". '$LIB'; printf '%s' \"\$UEFI_NTFS_URL\"" 2>/dev/null) || UEFI_TEST_URL=""
[ -n "$UEFI_TEST_URL" ] || { echo "cannot determine UEFI_NTFS_URL from script"; exit 1; }

# The actual trap spec from main(): tests must exercise this, not a copy.
TRAP_SPEC=$(grep -E '^[[:space:]]*trap .*INT TERM' "$SCRIPT" | head -1 | sed 's/^[[:space:]]*//')

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s :: %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s :: %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }
assert_rc() { if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1" "expected rc $2 got $3"; fi; }
assert_in() { case "$3" in *"$2"*) ok "$1" ;; *) no "$1" "missing [$2] in: $3" ;; esac; }
assert_not_in() { case "$3" in *"$2"*) no "$1" "unexpected [$2] in: $3" ;; *) ok "$1" ;; esac; }
run_lib() { sh -c ". '$LIB'; $1"; }
run_fake() { sh -c ". '$LIB'; PATH='$FAKE'; $1"; }

find_internal_disk() {
    for _p in /sys/class/block/*; do
        _n=${_p##*/}
        [ -e "$_p/partition" ] && continue
        case "$_n" in zram*|loop*|ram*|dm-*|sr*) continue ;; esac
        [ -r "$_p/removable" ] || continue
        [ "$(cat "$_p/removable" 2>/dev/null)" = "1" ] && continue
        _t=$(lsblk -ndo TRAN "/dev/$_n" 2>/dev/null || true)
        [ "$_t" = "usb" ] && continue
        echo "/dev/$_n"; return 0
    done
    return 1
}
find_usb_disk() {
    for _p in /sys/class/block/*; do
        _n=${_p##*/}
        [ -e "$_p/partition" ] && continue
        case "$_n" in zram*|loop*|ram*|dm-*|sr*) continue ;; esac
        _t=$(lsblk -ndo TRAN "/dev/$_n" 2>/dev/null || true)
        [ "$_t" = "usb" ] && { echo "/dev/$_n"; return 0; }
    done
    return 1
}
find_partition() {
    _n=${1##*/}
    for _p in /sys/class/block/"$_n"*; do
        [ -e "$_p/partition" ] || continue
        echo "/dev/${_p##*/}"; return 0
    done
    return 1
}
dev_bytes() {
    _n=${1##*/}
    [ -r "/sys/class/block/$_n/size" ] || return 1
    echo $(( $(cat "/sys/class/block/$_n/size") * 512 ))
}

INTERNAL=$(find_internal_disk || true)
PART=$(find_partition "${INTERNAL:-/dev/null}" || true)
USB=$(find_usb_disk || true)
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

echo "win-usb.sh test suite"
echo "script:   $SCRIPT"
echo "internal: ${INTERNAL:-(none)}"
echo "usb:      ${USB:-(none)}"
echo "root:     $IS_ROOT (non-root-only checks are skipped when 1)"
echo

# ===========================================================================
echo "--- SECTION 1: argument parsing ---"
out=$(sh "$SCRIPT" -h 2>&1); rc=$?
assert_rc "1.1 -h exits 0" 0 "$rc"
assert_in "1.1 -h prints usage" "USAGE" "$out"
assert_in "1.1 -h documents --force" "--force" "$out"
assert_in "1.1 -h documents -i/--iso" "--iso" "$out"
assert_in "1.1 -h documents -d/--device" "--device" "$out"
assert_in "1.1 -h documents env override" "WIN_USB_BOOT_IMG_SHA256" "$out"
out=$(sh "$SCRIPT" --help 2>&1); rc=$?
assert_rc "1.2 --help exits 0" 0 "$rc"
out=$(run_lib 'parse_args -i foo.iso; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.3 -i foo.iso" "foo.iso||0" "$out"
out=$(run_lib 'parse_args --iso foo.iso; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.4 --iso foo.iso" "foo.iso||0" "$out"
out=$(run_lib 'parse_args --iso=foo.iso; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.5 --iso=foo.iso" "foo.iso||0" "$out"
out=$(run_lib 'parse_args -y -i foo.iso; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.6 -y -i foo.iso" "foo.iso||1" "$out"
out=$(run_lib 'parse_args --yes --iso foo.iso; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.7 --yes --iso" "foo.iso||1" "$out"
out=$(run_lib 'parse_args -i foo.iso -d /dev/sde; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.8 -i -d" "foo.iso|/dev/sde|0" "$out"
out=$(run_lib 'parse_args --iso foo.iso --device /dev/sde; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.9 --iso --device" "foo.iso|/dev/sde|0" "$out"
out=$(run_lib 'parse_args --iso=foo.iso --device=/dev/sde; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.10 --iso= --device=" "foo.iso|/dev/sde|0" "$out"
out=$(run_lib 'parse_args -y -i foo.iso -d /dev/sde; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.11 -y -i -d" "foo.iso|/dev/sde|1" "$out"
out=$(run_lib 'parse_args --force -i foo.iso -d /dev/sde; printf "%s|%s|%s" "$iso_path" "$target_dev" "$force_flag"' 2>&1); assert_eq "1.12 --force sets force_flag" "foo.iso|/dev/sde|1" "$out"
out=$(run_lib 'parse_args -d /dev/sde -y -i foo.iso; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.13 reversed order" "foo.iso|/dev/sde|1" "$out"
out=$(run_lib 'parse_args -i' 2>&1); rc=$?
assert_rc "1.14 missing -i value exits 1" 1 "$rc"; assert_in "1.14 message" "requires an argument" "$out"
out=$(run_lib 'parse_args -i foo.iso -d' 2>&1); rc=$?
assert_rc "1.15 missing -d value exits 1" 1 "$rc"
out=$(run_lib 'parse_args -z foo.iso' 2>&1); rc=$?
assert_rc "1.16 unknown short flag exits 1" 1 "$rc"; assert_in "1.16 message" "Unknown option" "$out"
out=$(run_lib 'parse_args --bogus foo.iso' 2>&1); rc=$?
assert_rc "1.17 unknown long flag exits 1" 1 "$rc"
out=$(run_lib 'parse_args foo.iso' 2>&1); rc=$?
assert_rc "1.18 positional arg exits 1" 1 "$rc"; assert_in "1.18 message" "Unexpected positional" "$out"
out=$(run_lib 'parse_args -i foo.iso -- -d /dev/sde; printf "%s|%s" "$iso_path" "$target_dev"' 2>&1); assert_eq "1.19 -- terminator" "foo.iso|" "$out"
out=$(run_lib 'parse_args; printf "%s|%s|%s" "$iso_path" "$target_dev" "$yes_flag"' 2>&1); assert_eq "1.20 no arguments" "||0" "$out"
out=$(run_lib 'parse_args -i "" -d /dev/sde' 2>&1); rc=$?
assert_rc "1.21 empty -i value exits 1" 1 "$rc"; assert_in "1.21 message" "requires an argument" "$out"
out=$(run_lib 'parse_args --iso= -d /dev/sde; printf "[%s]" "$iso_path"' 2>&1); assert_eq "1.22 --iso= empty accepted by parser" "[]" "$out"
# 1.23: reach main()'s "ISO required" branch without root by stubbing id.
mkdir -p "$IDSTUB"
printf '#!/bin/sh\n[ "$1" = "-u" ] && { echo 0; exit 0; }\nexit 1\n' > "$IDSTUB/id"; chmod +x "$IDSTUB/id"
out=$(sh -c ". '$LIB'; PATH='$IDSTUB':\$PATH; main -y" 2>&1); rc=$?
assert_rc "1.23 no ISO as (stubbed) root exits 1" 1 "$rc"
assert_in "1.23 message" "A Windows ISO is required" "$out"

# ===========================================================================
echo "--- SECTION 2: validation ---"
if [ "$IS_ROOT" -eq 1 ]; then
    skip "2.1 not-root rejection" "suite is running as root"
else
    out=$(sh "$SCRIPT" -i /tmp/none.iso -d /dev/null 2>&1); rc=$?
    assert_rc "2.1 non-root exits 1" 1 "$rc"; assert_in "2.1 message" "must be run as root" "$out"
fi
out=$(run_lib 'validate_iso /nonexistent.iso' 2>&1); rc=$?
assert_rc "2.2 ISO missing exits 1" 1 "$rc"; assert_in "2.2 message" "ISO file not found" "$out"
if [ "$IS_ROOT" -eq 1 ]; then
    skip "2.3 unreadable ISO" "root can read mode-000 files"
else
    printf 'x' > "$WORK/unreadable.iso"; chmod 000 "$WORK/unreadable.iso"
    out=$(run_lib "validate_iso '$WORK/unreadable.iso'" 2>&1); rc=$?
    assert_rc "2.3 ISO unreadable exits 1 (non-root)" 1 "$rc"; assert_in "2.3 message" "not readable" "$out"
    chmod 644 "$WORK/unreadable.iso"
fi
: > "$WORK/empty.iso"
out=$(run_lib "validate_iso '$WORK/empty.iso'" 2>&1); rc=$?
assert_rc "2.4 ISO empty exits 1" 1 "$rc"; assert_in "2.4 message" "ISO file is empty" "$out"
out=$(run_lib 'target_dev=/dev/null; select_device' 2>&1); rc=$?
assert_rc "2.5 not a block device exits 1" 1 "$rc"; assert_in "2.5 message" "Not a block device" "$out"
out=$(run_lib 'target_dev=""; yes_flag=1; select_device' 2>&1); rc=$?
assert_rc "2.6 missing -d non-interactive exits 1" 1 "$rc"; assert_in "2.6 message" "required in non-interactive" "$out"
out=$(run_lib 'validate_iso /etc/hostname' 2>&1); rc=$?
assert_rc "2.7 non-ISO warns but continues" 0 "$rc"; assert_in "2.7 warning" "does not look like an ISO9660" "$out"
if [ -n "$INTERNAL" ]; then
    _db=$(dev_bytes "$INTERNAL") || _db=""
    if [ -n "$_db" ]; then
        truncate -s $((_db + 1048576)) "$WORK/big.iso"
        out=$(run_lib "check_capacity '$INTERNAL' '$WORK/big.iso'" 2>&1); rc=$?
        assert_rc "2.8 device too small exits 1" 1 "$rc"; assert_in "2.8 message" "too small" "$out"
    else
        skip "2.8 device too small" "cannot read device size"
    fi
else
    skip "2.8 device too small" "no internal disk found"
fi

# ===========================================================================
echo "--- SECTION 3: dependency checks (simulated PATH) ---"
reset_fake() { rm -rf "$FAKE"; mkdir -p "$FAKE"; }
add_fake() {
    for _t in "$@"; do
        _p=$(command -v "$_t" 2>/dev/null)
        [ -n "$_p" ] && ln -s "$_p" "$FAKE/$_t"
    done
}
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe awk wget sha256sum grub2-install grub-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); rc=$?
assert_rc "3.0 all present passes" 0 "$rc"
reset_fake; add_fake mkfs.ntfs mkfs.vfat mount umount dd partprobe awk wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); rc=$?
assert_rc "3.1 missing fdisk exits 1" 1 "$rc"; assert_in "3.1 message" "fdisk" "$out"
reset_fake; add_fake fdisk mkfs.vfat mount umount dd partprobe awk wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); assert_in "3.2 missing mkfs.ntfs" "mkfs.ntfs" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mount umount dd partprobe awk wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); assert_in "3.3 missing mkfs.vfat" "mkfs.vfat" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat umount dd partprobe awk wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); assert_in "3.4 missing mount" "mount" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount dd partprobe awk wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); assert_in "3.5 missing umount" "umount" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount partprobe awk wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); assert_in "3.6 missing dd" "dd" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd awk wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); assert_in "3.7 missing partprobe" "partprobe" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe awk sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); rc=$?
assert_rc "3.8 missing wget+curl exits 1" 1 "$rc"; assert_in "3.8 message" "wget OR curl" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe awk wget sha256sum lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); rc=$?
assert_rc "3.9 missing grub exits 1" 1 "$rc"; assert_in "3.9 message" "grub-install OR grub2-install" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe awk wget grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); rc=$?
assert_rc "3.10 missing sha tools exits 1" 1 "$rc"; assert_in "3.10 message" "sha256sum OR shasum OR openssl" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe awk wget sha256sum grub2-install
out=$(run_fake 'yes_flag=0; check_deps' 2>&1); rc=$?
assert_rc "3.11 missing lsblk (interactive) exits 1" 1 "$rc"; assert_in "3.11 message" "lsblk" "$out"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe awk wget sha256sum grub2-install
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); rc=$?
assert_rc "3.12 missing lsblk OK in -y mode" 0 "$rc"
reset_fake; add_fake fdisk mkfs.ntfs mkfs.vfat mount umount dd partprobe wget sha256sum grub2-install lsblk
out=$(run_fake 'yes_flag=1; check_deps' 2>&1); rc=$?
assert_rc "3.13 missing awk exits 1" 1 "$rc"; assert_in "3.13 message" "awk" "$out"

# ===========================================================================
echo "--- SECTION 4: interactive prompts and device listing ---"
out=$(printf 'bogus\n' | run_lib 'target_dev=""; yes_flag=0; select_device' 2>&1); rc=$?
assert_rc "4.2 invalid device exits 1" 1 "$rc"; assert_in "4.2 message" "Not a block device" "$out"
out=$(printf '\n' | run_lib 'target_dev=""; yes_flag=0; select_device' 2>&1); rc=$?
assert_rc "4.3 empty device exits 1" 1 "$rc"; assert_in "4.3 message" "No device entered" "$out"
if [ -n "$INTERNAL" ]; then
    out=$(printf '%s\n' "$INTERNAL" | run_lib 'target_dev=""; yes_flag=0; select_device >/dev/null 2>&1; printf "%s|rc=%s" "$target_dev" "$?"' 2>&1)
    assert_eq "4.1 valid device accepted and stored" "$INTERNAL|rc=0" "$out"
else
    skip "4.1 valid device accepted" "no internal disk"
fi
out=$(printf 'YES\n' | run_lib 'yes_flag=0; target_dev=/dev/null; confirm_destruction; echo "rc=$?"' 2>&1)
assert_in "4.4 YES continues" "rc=0" "$out"
out=$(printf 'yes\n' | run_lib 'yes_flag=0; target_dev=/dev/null; confirm_destruction' 2>&1); rc=$?
assert_rc "4.5 wrong case aborts exit 0" 0 "$rc"; assert_in "4.5 message" "Aborted." "$out"
out=$(printf '\n' | run_lib 'yes_flag=0; target_dev=/dev/null; confirm_destruction' 2>&1); rc=$?
assert_rc "4.6 empty aborts exit 0" 0 "$rc"; assert_in "4.6 message" "Aborted." "$out"
out=$(run_lib 'list_devices' 2>&1)
assert_in "4.7 list_devices shows full paths" "/dev/" "$out"
_bad=$(printf '%s\n' "$out" | awk 'NR>2 && NF>0 && $1!="NAME" && substr($1,1,5)!="/dev/" {print}')
if [ -z "$_bad" ]; then ok "4.8 every listed device is a full path"; else no "4.8 every listed device is a full path" "$_bad"; fi
out=$(sh -c ". '$LIB'; PATH=/nonexistent list_devices; echo rc=\$?" 2>&1)
assert_in "4.9 list_devices without lsblk is harmless" "rc=0" "$out"

# ===========================================================================
echo "--- SECTION 5: _part_base ---"
_i=1
for _pair in "/dev/sda:/dev/sda" "/dev/sdb:/dev/sdb" "/dev/vda:/dev/vda" "/dev/nvme0n1:/dev/nvme0n1p" "/dev/nvme1n1:/dev/nvme1n1p" "/dev/mmcblk0:/dev/mmcblk0p" "/dev/loop0:/dev/loop0p"; do
    _in=${_pair%%:*}; _exp=${_pair##*:}
    out=$(run_lib "_part_base $_in" 2>&1)
    assert_eq "5.$_i $_in" "$_exp" "$out"
    _i=$((_i + 1))
done

# ===========================================================================
echo "--- SECTION 6: cleanup and trap ---"
out=$(run_lib 'setup_workdir; d=$WORK_DIR; cleanup; cleanup; [ -d "$d" ] && echo LEAK || echo CLEAN' 2>&1)
assert_in "6.3 cleanup idempotent" "CLEAN" "$out"
out=$(sh -c ". '$LIB'; setup_workdir; echo WORK=\$WORK_DIR; trap cleanup EXIT; die x" 2>&1); rc=$?
_dir=$(printf '%s\n' "$out" | awk -F= '/^WORK=/{print $2}')
assert_rc "6.4 die exits 1" 1 "$rc"
if [ -n "$_dir" ] && [ -d "$_dir" ]; then no "6.4 die removes workspace" "$_dir"; else ok "6.4 die removes workspace"; fi
out=$(run_lib 'mkdir -p /tmp/win-usb-safety; WORK_DIR=/tmp/win-usb-safety; cleanup; [ -d /tmp/win-usb-safety ] && echo KEPT || echo REMOVED; rmdir /tmp/win-usb-safety 2>/dev/null' 2>&1)
assert_in "6.5 cleanup keeps non-workspace dirs" "KEPT" "$out"
out=$(run_lib 'D=/tmp/win-usb.matchme; mkdir -p "$D"; WORK_DIR="$D"; cleanup; [ -d "$D" ] && echo KEPT || echo REMOVED' 2>&1)
assert_in "6.6 cleanup removes matching workspace" "REMOVED" "$out"
# 6.1/6.2 exercise the trap spec actually present in the script (not a copy).
if [ -n "$TRAP_SPEC" ]; then
    out=$(timeout -s INT 1 sh -c ". '$LIB'; $TRAP_SPEC; trap cleanup EXIT; sleep 3; echo CONTINUED-BUG" 2>&1)
    assert_not_in "6.1 SIGINT: script's trap aborts (no continuation)" "CONTINUED-BUG" "$out"
    out=$(timeout -s TERM 1 sh -c ". '$LIB'; $TRAP_SPEC; trap cleanup EXIT; sleep 3; echo CONTINUED-BUG" 2>&1)
    assert_not_in "6.2 SIGTERM: script's trap aborts (no continuation)" "CONTINUED-BUG" "$out"
else
    no "6.1/6.2 trap spec" "no 'trap ... INT TERM' found in script"
fi
# _is_mounted fallback without `mountpoint`
mkdir -p "$AWKONLY"; ln -sf "$(command -v awk)" "$AWKONLY/awk"
out=$(sh -c ". '$LIB'; PATH='$AWKONLY'; _is_mounted /; echo a=\$?; _is_mounted /no-such-mnt-xyz; echo b=\$?" 2>&1)
assert_in "6.8 _is_mounted fallback (mounted root)" "a=0" "$out"
assert_in "6.8 _is_mounted fallback (unmounted path)" "b=1" "$out"

# ===========================================================================
echo "--- SECTION 7: device safety guard ---"
if [ -n "$PART" ]; then
    out=$(run_lib "force_flag=0; check_target_device '$PART'" 2>&1); rc=$?
    assert_rc "7.1 partition rejected exits 1" 1 "$rc"; assert_in "7.1 message" "is a partition" "$out"
    out=$(run_lib "force_flag=1; check_target_device '$PART'" 2>&1); rc=$?
    assert_rc "7.1b --force does NOT bypass partition check" 1 "$rc"
else
    skip "7.1 partition rejected" "no partition node found"
    skip "7.1b --force + partition" "no partition node found"
fi
if [ -n "$INTERNAL" ]; then
    out=$(run_lib "force_flag=0; check_target_device '$INTERNAL'" 2>&1); rc=$?
    assert_rc "7.2 non-removable rejected exits 1" 1 "$rc"; assert_in "7.2 message" "does not look like a removable" "$out"
    out=$(run_lib "force_flag=1; check_target_device '$INTERNAL'; echo rc=\$?" 2>&1)
    assert_in "7.3 --force bypasses removable check" "rc=0" "$out"
else
    skip "7.2/7.3 removable guard" "no internal disk"
fi
if [ -n "$USB" ]; then
    out=$(run_lib "force_flag=0; check_target_device '$USB'; echo rc=\$?" 2>&1)
    assert_in "7.4 USB transport accepted" "rc=0" "$out"
else
    skip "7.4 USB transport accepted" "no USB disk attached"
fi
# A whole disk with neither removable=1 nor TRAN=usb must be refused.
if [ -b /dev/zram0 ]; then
    out=$(run_lib 'force_flag=0; check_target_device /dev/zram0' 2>&1); rc=$?
    assert_rc "7.6 no-removable/no-transport rejected" 1 "$rc"
    assert_in "7.6 message" "does not look like a removable" "$out"
else
    skip "7.6 no-removable/no-transport rejected" "/dev/zram0 absent"
fi
# 7.5 capacity check (labelled explicitly)
if [ -n "$INTERNAL" ]; then
    _db=$(dev_bytes "$INTERNAL") || _db=""
    if [ -n "$_db" ]; then
        truncate -s $((_db + 1048576)) "$WORK/big5.iso"
        out=$(run_lib "check_capacity '$INTERNAL' '$WORK/big5.iso'" 2>&1); rc=$?
        assert_rc "7.5 capacity guard exits 1" 1 "$rc"; assert_in "7.5 message" "too small" "$out"
        # Boundary: exactly dev-MIN passes; one byte over fails (die exits).
        _min=$(run_lib 'echo "$MIN_FREE_BYTES"')
        truncate -s $((_db - _min)) "$WORK/edge-ok.iso"
        out=$(run_lib "check_capacity '$INTERNAL' '$WORK/edge-ok.iso'; echo rc=\$?" 2>&1)
        assert_in "7.5b boundary at MIN_FREE_BYTES passes" "rc=0" "$out"
        truncate -s $((_db - _min + 1)) "$WORK/edge-bad.iso"
        out=$(run_lib "check_capacity '$INTERNAL' '$WORK/edge-bad.iso'" 2>&1); rc=$?
        assert_rc "7.5c one byte over MIN_FREE_BYTES aborts" 1 "$rc"
        assert_in "7.5c message" "too small" "$out"
    else
        skip "7.5 capacity" "cannot read device size"
    fi
fi

# ===========================================================================
echo "--- SECTION 8: boot image download / checksum ---"
NET=0
if command -v curl >/dev/null 2>&1 && curl -fsSI --max-time 8 "$UEFI_TEST_URL" >/dev/null 2>&1; then NET=1
elif command -v wget >/dev/null 2>&1 && wget -q --spider --timeout=8 "$UEFI_TEST_URL" 2>/dev/null; then NET=1
fi
if [ "$NET" -eq 1 ]; then
    out=$(run_lib 'BOOT_IMG='"$WORK"'/dl.img; download_boot_image; echo rc=$?' 2>&1)
    assert_in "8.1 pinned download succeeds (wget/curl)" "rc=0" "$out"
    assert_eq "8.1 image size 1048576" "1048576" "$(wc -c < "$WORK/dl.img" 2>/dev/null || echo 0)"

    mkdir -p "$CURLONLY"; rm -f "$CURLONLY"/*; ln -s "$(command -v curl)" "$CURLONLY/curl"; ln -s "$(command -v sha256sum)" "$CURLONLY/sha256sum"; ln -s "$(command -v awk)" "$CURLONLY/awk"
    out=$(sh -c ". '$LIB'; PATH='$CURLONLY'; BOOT_IMG='$WORK/dl-curl.img'; download_boot_image; echo rc=\$?" 2>&1)
    assert_in "8.2 curl-only path succeeds" "rc=0" "$out"
    assert_eq "8.2 curl-only image size 1048576" "1048576" "$(wc -c < "$WORK/dl-curl.img" 2>/dev/null || echo 0)"

    if command -v wget >/dev/null 2>&1; then
        mkdir -p "$WGETONLY"; rm -f "$WGETONLY"/*; ln -s "$(command -v wget)" "$WGETONLY/wget"; ln -s "$(command -v sha256sum)" "$WGETONLY/sha256sum"; ln -s "$(command -v awk)" "$WGETONLY/awk"
        out=$(sh -c ". '$LIB'; PATH='$WGETONLY'; BOOT_IMG='$WORK/dl-wget.img'; download_boot_image; echo rc=\$?" 2>&1)
        assert_in "8.3 wget-only path succeeds" "rc=0" "$out"
        assert_eq "8.3 wget-only image size 1048576" "1048576" "$(wc -c < "$WORK/dl-wget.img" 2>/dev/null || echo 0)"
    else
        skip "8.3 wget-only" "wget absent"
    fi

    if command -v wget >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        mkdir -p "$FALLBACK"; rm -f "$FALLBACK"/*
        printf '#!/bin/sh\nexit 1\n' > "$FALLBACK/wget"; chmod +x "$FALLBACK/wget"
        ln -s "$(command -v curl)" "$FALLBACK/curl"; ln -s "$(command -v sha256sum)" "$FALLBACK/sha256sum"; ln -s "$(command -v awk)" "$FALLBACK/awk"
        out=$(sh -c ". '$LIB'; PATH='$FALLBACK'; BOOT_IMG='$WORK/dl-fb.img'; download_boot_image; echo rc=\$?" 2>&1)
        assert_in "8.3b failing wget falls back to curl" "rc=0" "$out"
    else
        skip "8.3b wget-fail->curl fallback" "needs both wget and curl"
    fi

    out=$(run_lib 'BOOT_IMG='"$WORK"'/dl2.img; UEFI_NTFS_SHA256=deadbeef; download_boot_image' 2>&1); rc=$?
    assert_rc "8.4 checksum mismatch exits 1" 1 "$rc"; assert_in "8.4 message" "checksum mismatch" "$out"
else
    skip "8.1/8.2/8.3/8.3b/8.4 download tests" "no network access"
fi
out=$(run_lib 'UEFI_NTFS_URL="https://invalid.invalid/nope.img"; BOOT_IMG='"$WORK"'/dl3.img; download_boot_image' 2>&1); rc=$?
assert_rc "8.5 download failure exits 1" 1 "$rc"
if command -v openssl >/dev/null 2>&1; then
    mkdir -p "$OSSLONLY"; rm -f "$OSSLONLY"/*; ln -s "$(command -v openssl)" "$OSSLONLY/openssl"; ln -s "$(command -v awk)" "$OSSLONLY/awk"
    printf 'known-content\n' > "$WORK/hash.txt"
    _want=$(sha256sum "$WORK/hash.txt" | awk '{print $1}')
    out=$(sh -c ". '$LIB'; PATH='$OSSLONLY'; _sha256 '$WORK/hash.txt'" 2>&1)
    assert_eq "8.6 _sha256 falls back to openssl" "$_want" "$out"
else
    skip "8.6 _sha256 openssl fallback" "openssl unavailable"
fi
# shasum fallback (shasum is rarely installed; emulate it)
if command -v sha256sum >/dev/null 2>&1; then
    mkdir -p "$SHASUMONLY"; rm -f "$SHASUMONLY"/*
    _ss=$(command -v sha256sum)
    printf '#!/bin/sh\n[ "$1" = "-a" ] && shift\n[ -n "${1:-}" ] && shift\nexec %s "$@"\n' "$_ss" > "$SHASUMONLY/shasum"
    chmod +x "$SHASUMONLY/shasum"; ln -s "$(command -v awk)" "$SHASUMONLY/awk"
    printf 'known-content\n' > "$WORK/hash2.txt"
    _want2=$("$_ss" "$WORK/hash2.txt" | awk '{print $1}')
    out=$(sh -c ". '$LIB'; PATH='$SHASUMONLY'; _sha256 '$WORK/hash2.txt'" 2>&1)
    assert_eq "8.7 _sha256 falls back to shasum" "$_want2" "$out"
fi

# ===========================================================================
echo "--- SECTION 12: hardware-free layout / format harness ---"
# 12.1 uses the script's own _fdisk_script(), not a copy.
IMG="$WORK/layout.img"
truncate -s 512M "$IMG"
run_lib '_fdisk_script' > "$WORK/fdisk.cmds" 2>/dev/null
assert_in "12.0 _fdisk_script non-empty" "w" "$(cat "$WORK/fdisk.cmds")"
fdisk "$IMG" < "$WORK/fdisk.cmds" > "$WORK/fdisk.log" 2>&1
assert_rc "12.1 fdisk scripted run exits 0" 0 "$?"
_lay=$(fdisk -l "$IMG" 2>/dev/null)
assert_in "12.1 p1 Microsoft basic data" "Microsoft basic data" "$_lay"
assert_in "12.1 p2 EFI System" "EFI System" "$_lay"
assert_in "12.1 p3 BIOS boot" "BIOS boot" "$_lay"
assert_in "12.1 legacy flag on p3" "LegacyBIOSBootable flag on partition 3 is enabled" "$(cat "$WORK/fdisk.log")"
# Sizes/types must match the script's constants, not just "some" layout.
_plines=$(printf '%s\n' "$_lay" | awk '/basic data|EFI System|BIOS boot/{print}')
assert_eq "12.1 exactly three partitions" "3" "$(printf '%s\n' "$_plines" | wc -l)"
assert_in "12.1 p2 is 40M (BOOT_PART_SIZE)" "40M" "$(printf '%s\n' "$_plines" | sed -n '2p')"
# 12.2/12.3 use the script's own format helpers.
: > "$WORK/fat.img"; truncate -s 40M "$WORK/fat.img"
out=$(run_lib "_format_vfat '$WORK/fat.img'" 2>&1); rc=$?
assert_rc "12.2 _format_vfat succeeds" 0 "$rc"
assert_not_in "12.2 no undersize warning" "less then suggested minimum" "$out"
assert_eq "12.2 image is actually FAT32" "FAT32" "$(dd if="$WORK/fat.img" bs=1 skip=82 count=5 2>/dev/null)"
: > "$WORK/ntfs.img"; truncate -s 64M "$WORK/ntfs.img"
out=$(run_lib "_format_ntfs '$WORK/ntfs.img'" 2>&1); rc=$?
assert_rc "12.3 _format_ntfs succeeds" 0 "$rc"
assert_eq "12.3 image is actually NTFS" "NTFS" "$(dd if="$WORK/ntfs.img" bs=1 skip=3 count=4 2>/dev/null)"
# 12.4 _mounted_parts regex (NVMe p-suffix) via a fixture mount table.
FIX="$WORK/mounts.fixture"
cat > "$FIX" <<'FIXEOF'
/dev/nvme0n1p1 /mnt/a ext4 rw 0 0
/dev/nvme0n1p2 /mnt/b ext4 rw 0 0
/dev/sda1 /mnt/c ext4 rw 0 0
/dev/sda10 /mnt/d ext4 rw 0 0
/dev/sdab1 /mnt/e ext4 rw 0 0
FIXEOF
out=$(run_lib "_mounted_parts /dev/nvme0n1 '$FIX'" 2>&1 | tr '\n' ' ')
assert_eq "12.4 _mounted_parts nvme p-suffix" "/dev/nvme0n1p1 /dev/nvme0n1p2 " "$out"
out=$(run_lib "_mounted_parts /dev/sda '$FIX'" 2>&1 | tr '\n' ' ')
assert_eq "12.4 _mounted_parts excludes non-numeric suffix" "/dev/sda1 /dev/sda10 " "$out"
# 12.5 setup_workdir fallback when mktemp is unavailable.
mkdir -p "$NOMKT"; ln -sf "$(command -v mkdir)" "$NOMKT/mkdir"
out=$(sh -c ". '$LIB'; PATH='$NOMKT'; TMPDIR='$WORK'; setup_workdir; case \"\$WORK_DIR\" in '$WORK'/win-usb.*) echo PATTERN_OK;; *) echo BAD:\$WORK_DIR;; esac; [ -d \"\$WORK_DIR\" ] && echo DIR_OK" 2>&1)
assert_in "12.5 setup_workdir no-mktemp fallback" "PATTERN_OK" "$out"
assert_in "12.5 setup_workdir created dir" "DIR_OK" "$out"
# 12.6 _dev_size_bytes on a nonexistent device fails cleanly.
out=$(run_lib '_dev_size_bytes /dev/does-not-exist; echo rc=$?' 2>&1)
assert_in "12.6 _dev_size_bytes bogus device fails" "rc=1" "$out"
# 12.7 check_capacity skips when ISO size is unreadable.
if [ -n "$INTERNAL" ]; then
    out=$(run_lib "check_capacity '$INTERNAL' /nonexistent.iso; echo rc=\$?" 2>&1)
    assert_in "12.7 check_capacity skips unreadable ISO" "rc=0" "$out"
fi
# 12.8 confirm_destruction -y short-circuit and no-lsblk fallback.
out=$(run_lib 'yes_flag=1; target_dev=/dev/null; confirm_destruction; echo rc=$?' 2>&1)
assert_in "12.8 -y skips the prompt" "rc=0" "$out"
assert_not_in "12.8 -y prints no prompt" "Type YES" "$out"
if [ -n "$INTERNAL" ]; then
    mkdir -p "$CATONLY"; ln -sf "$(command -v cat)" "$CATONLY/cat"
    out=$(printf 'YES\n' | sh -c ". '$LIB'; PATH='$CATONLY'; yes_flag=0; target_dev='$INTERNAL'; confirm_destruction" 2>&1)
    assert_in "12.8 no-lsblk size fallback" "Size:" "$out"
fi
# 12.9 install_grub must never run with an empty boot directory.
if command -v grub-install >/dev/null 2>&1 || command -v grub2-install >/dev/null 2>&1; then
    out=$(run_lib 'DATA_MNT=""; install_grub /dev/null' 2>&1); rc=$?
    assert_rc "12.9 install_grub rejects empty boot dir" 1 "$rc"
    assert_in "12.9 message" "boot directory is not set" "$out"
    assert_not_in "12.9 never invokes grub without a boot dir" "Installation" "$out"
else
    skip "12.9 install_grub boot-dir guard" "no GRUB installer present"
fi

# ===========================================================================
echo
echo "============================================================"
printf 'RESULT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
echo "============================================================"
[ "$FAIL" -eq 0 ]