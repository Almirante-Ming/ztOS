#!/bin/bash
# Write ztOS to a Pixel 7 (panther) in fastboot. ztOS lives on slot A and
# USERDATA; stock Android stays on slot B and is never written.
#
#   scripts/flash-panther.sh [--dry-run] prepare <factory dir>
#       once: the factory bootloader and vbmeta into slot A, so slot A boots
#       the same bootloader (cloudripper-17.0-15902555) as stock on B. Slot A
#       is the inactive one: if this is cut short, the phone still starts B.
#   scripts/flash-panther.sh [--dry-run] boot [image dir]
#       out/panther's five images into slot A, slot A made active, reboot
#   scripts/flash-panther.sh [--dry-run] root <ext4 image>
#       the Arch root (label ZR_ARCH) into USERDATA: erases Android's data
#   scripts/flash-panther.sh [--dry-run] stock
#       back to stock: slot B active, reboot
#
# fastboot is Android's platform-tools, here the Windows one when run in WSL
# ($FASTBOOT, default /mnt/z/Ferramentas/platform-tools/fastboot.exe).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FASTBOOT=${FASTBOOT:-/mnt/z/Ferramentas/platform-tools/fastboot.exe}
[ -x "$FASTBOOT" ] || FASTBOOT=$(command -v fastboot || true)
[ -n "$FASTBOOT" ] || { echo "no fastboot (set FASTBOOT=...)" >&2; exit 1; }
BOOTLOADER_VERSION=cloudripper-17.0-15902555
IMAGES="boot init_boot vendor_boot vendor_kernel_boot dtbo"

DRY=
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
CMD=${1:?prepare | boot | root | stock}
shift

# A Windows fastboot wants Windows paths
winpath() {
	case "$FASTBOOT" in *.exe) wslpath -w "$1" ;; *) echo "$1" ;; esac
}
# A Windows fastboot reads stdin dry (WSL interop): never give it ours
fb() {
	if [ -n "$DRY" ] && [ "$1" != getvar ]; then
		echo "would run: fastboot $*"
		return 0
	fi
	"$FASTBOOT" "$@" </dev/null
}
var() {
	timeout 20 "$FASTBOOT" getvar "$1" </dev/null 2>&1 | tr -d '\r' | sed -n "s/^$1: *//p" | head -n1
}
# Only slot A and userdata, ever
flash() {
	case "$1" in
	bootloader|vbmeta) [ "$2" = --slot=a ] || { echo "refusing $1 without --slot=a" >&2; exit 1; } ;;
	boot_a|init_boot_a|vendor_boot_a|vendor_kernel_boot_a|dtbo_a|userdata) ;;
	*) echo "refusing to write $1" >&2; exit 1 ;;
	esac
	if [ "$#" = 3 ]; then
		fb "$2" flash "$1" "$(winpath "$3")"
	else
		fb flash "$1" "$(winpath "$2")"
	fi
}

check_phone() {
	local product unlocked slot
	# fastboot waits forever for a phone; say so instead
	timeout 10 "$FASTBOOT" devices </dev/null 2>/dev/null | grep -q fastboot || {
		echo "no phone in fastboot (power off, then hold Power + Volume Down; plug it in)" >&2
		exit 1
	}
	product=$(var product)
	[ "$product" = panther ] || { echo "the phone in fastboot is '${product:-none}', not panther" >&2; exit 1; }
	unlocked=$(var unlocked)
	[ "$unlocked" = yes ] || { echo "the bootloader is locked" >&2; exit 1; }
	[ "$(var version-bootloader)" = "$BOOTLOADER_VERSION" ] || {
		echo "this phone's bootloader is $(var version-bootloader), not $BOOTLOADER_VERSION:" >&2
		echo "the images were checked against $BOOTLOADER_VERSION only" >&2
		exit 1
	}
	slot=$(var current-slot)
	echo "panther, unlocked, $BOOTLOADER_VERSION, current slot $slot"
	echo "slot b: successful=$(var slot-successful:b) unbootable=$(var slot-unbootable:b)"
	echo "slot a: successful=$(var slot-successful:a) unbootable=$(var slot-unbootable:a) retries=$(var slot-retry-count:a)"
}

case "$CMD" in
prepare)
	dir=${1:?factory image directory (with bootloader-panther-*.img and image-panther-*.zip)}
	check_phone
	bl=$(ls "$dir"/bootloader-panther-$BOOTLOADER_VERSION.img)
	vbmeta=$ROOT/stock/panther/vbmeta.img
	[ -f "$vbmeta" ] || { echo "no $vbmeta (the factory image's vbmeta.img)" >&2; exit 1; }
	echo "slot A gets: $(basename "$bl"), stock vbmeta.img"
	flash bootloader --slot=a "$bl"
	flash vbmeta --slot=a "$vbmeta"
	fb reboot-bootloader
	echo "done: slot A has stock's bootloader; stock is still active on B"
	;;
boot)
	dir=${1:-$ROOT/out/panther}
	[ "$(cat "$dir/DEVICE" 2>/dev/null)" = panther ] || { echo "$dir has no panther images" >&2; exit 1; }
	(cd "$dir" && sha256sum -c --quiet SHA256SUMS) || { echo "$dir: checksums do not match" >&2; exit 1; }
	check_phone
	for img in $IMAGES; do
		flash "${img}_a" "$dir/$img.img"
	done
	fb --set-active=a
	fb reboot
	echo "slot A active: ztOS starts; stock is on B (scripts/flash-panther.sh stock goes back)"
	;;
root)
	img=${1:?the ext4 root image}
	check_phone
	echo "USERDATA is erased: Android's apps and files on this phone are gone after this"
	if [ -z "$DRY" ]; then
		read -r -p "Type ERASE to go on: " ok
		[ "$ok" = ERASE ] || { echo "stopped; nothing written"; exit 1; }
	fi
	flash userdata "$img"
	;;
stock)
	check_phone
	fb --set-active=b
	fb reboot
	;;
*)
	echo "unknown command $CMD" >&2
	exit 2
	;;
esac
