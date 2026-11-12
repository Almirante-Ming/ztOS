#!/bin/bash
# Build the boot images for the Pixel 7 (panther): mainline 7.3 with the gs201
# support of linux-omarchy-mobile, ztOS's board file (kernel/panther/), and
# the zboot boot stage (initramfs/panther/) in vendor_kernel_boot.
#
#   scripts/build-boot-panther.sh [options]
#     --no-kernel        reuse the kernel already built in build/out-panther
#     --rescue           boot stage stays in the rescue shell (zboot.rescue=1)
#     --cmdline "..."    extra kernel command line
#
# Output: out/panther/{boot,init_boot,vendor_boot,vendor_kernel_boot,dtbo}.img
# (+ SHA256SUMS). These are slot A's images: scripts/flash-panther.sh writes
# them. Runs unprivileged; the toolchain, kernel tree, AOSP tools and busybox
# live under build/.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
B=$ROOT/build
SRC=$B/linux-omamobile
KO=$B/out-panther
OUT=$ROOT/out/panther
TC=$B/toolchain/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu/bin
AOSP=$B/aosp
export PATH=$B/host/usr/bin:$TC:$PATH LC_ALL=C ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu-

# What ABL checks, from the stock images of CP3A.261005.002.A1 (stock/panther)
SOC_IDS="0x9855001 0x9855000"   # B0 first: the value the DTB is built with, as dtc prints it
BOARD_ID=0x30406 BOARD_REV=0x10000
OS_VERSION=17.0.0 OS_PATCH_LEVEL=2026-10
# boot and init_boot are chained in vbmeta: each needs its own AVB footer.
# Unlocked, ABL accepts the test key (orange state); it does not accept none.
ROLLBACK_INDEX=1791158400
BOOT_SIZE=0x4000000 INIT_BOOT_SIZE=0x800000
VENDOR_PAGESIZE=0x800
VENDOR_CMDLINE="console=tty0 earlycon=exynos4210,0x10A00000 clk_ignore_unused pd_ignore_unused printk.devkmsg=on bootconfig"

KERNEL=1 EXTRA=
while [ $# -gt 0 ]; do
	case "$1" in
	--no-kernel) KERNEL= ;;
	--rescue) EXTRA="$EXTRA zboot.rescue=1" ;;
	--cmdline) EXTRA="$EXTRA $2"; shift ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift
done

for need in "$SRC/Makefile" "$TC/aarch64-none-linux-gnu-gcc" "$B/host/usr/bin/bc" "$B/busybox-arm64" \
	"$AOSP/mkbootimg/mkbootimg.py" "$AOSP/libufdt/utils/src/mkdtboimg.py" "$AOSP/avb/avbtool.py"; do
	[ -e "$need" ] || { echo "missing $need (see kernel/panther/README.md)" >&2; exit 1; }
done

# --- kernel ---------------------------------------------------------------------
DTS=$SRC/arch/arm64/boot/dts/exynos/google
cp "$ROOT/kernel/panther/gs201-panther.dts" "$ROOT/kernel/panther/gs201-panther-audio.dtsi" \
	"$ROOT/kernel/panther/gs201-panther-camera.dtsi" "$DTS/"
grep -q gs201-panther.dtb "$DTS/Makefile" || sed -i \
	-e 's/^\tgs201-cheetah.dtb$/\tgs201-cheetah.dtb \\\n\tgs201-panther.dtb/' \
	-e 's/^DTC_FLAGS_gs201-cheetah += -@$/&\nDTC_FLAGS_gs201-panther += -@/' "$DTS/Makefile"
grep -q gs201-panther.dtb "$DTS/Makefile" || { echo "could not add gs201-panther.dtb to $DTS/Makefile" >&2; exit 1; }
# ztOS's fixes to the kernel tree, each applied once
for p in "$ROOT"/kernel/panther/patches/*.patch; do
	[ -e "$p" ] || continue
	git -C "$SRC" apply -R --check "$p" 2>/dev/null && continue
	git -C "$SRC" apply "$p" || { echo "patch $(basename "$p") does not apply" >&2; exit 1; }
done

if [ ! -f "$KO/.config" ]; then
	echo "=== kernel config: defconfig + omamobile.config ==="
	make -C "$SRC" O="$KO" defconfig > /dev/null
	"$SRC/scripts/kconfig/merge_config.sh" -m -O "$KO" "$KO/.config" "$B/ref/omarchy-mobile/kernel/configs/omamobile.config" > /dev/null
	make -C "$SRC" O="$KO" olddefconfig > /dev/null
fi
# ztOS's own drivers (patches/), built in, on top of omamobile.config
added=
for opt in TOUCHSCREEN_FOCALTECH_FT3658; do
	grep -q "^CONFIG_$opt=y" "$KO/.config" && continue
	"$SRC/scripts/config" --file "$KO/.config" -e "$opt"
	added=1
done
# and as modules, next to the gs201 display drivers they work with
for opt in DRM_PANEL_SAMSUNG_S6E3FC3; do
	grep -q "^CONFIG_$opt=[ym]" "$KO/.config" && continue
	"$SRC/scripts/config" --file "$KO/.config" -m "$opt"
	added=1
done
[ -z "$added" ] || make -C "$SRC" O="$KO" olddefconfig > /dev/null
if [ -n "$KERNEL" ]; then
	echo "=== kernel ==="
	make -C "$SRC" O="$KO" -j"${JOBS:-$(nproc)}" Image exynos/google/gs201-panther.dtb
else
	# the board file may have changed even when the kernel has not
	make -C "$SRC" O="$KO" exynos/google/gs201-panther.dtb > /dev/null
fi
IMAGE=$KO/arch/arm64/boot/Image
DTB=$KO/arch/arm64/boot/dts/exynos/google/gs201-panther.dtb
DTC=$KO/scripts/dtc/dtc
[ -f "$IMAGE" ] && [ -f "$DTB" ] || { echo "no kernel built in $KO" >&2; exit 1; }

W=$B/panther-images
rm -rf "$W" && mkdir -p "$W" "$OUT"

# --- initramfs --------------------------------------------------------------------
echo "=== initramfs ==="
aarch64-none-linux-gnu-gcc -static -O2 -Wall -o "$W/devmem" "$ROOT/initramfs/panther/devmem.c"
aarch64-none-linux-gnu-strip "$W/devmem"
cat > "$W/initramfs.list" <<EOF
dir /bin 0755 0 0
dir /sbin 0755 0 0
dir /usr 0755 0 0
dir /usr/bin 0755 0 0
dir /usr/sbin 0755 0 0
dir /dev 0755 0 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /run 0755 0 0
dir /tmp 1777 0 0
dir /etc 0755 0 0
dir /newroot 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/kmsg 0644 0 0 c 1 11
file /bin/busybox $B/busybox-arm64 0755 0 0
slink /bin/sh busybox 0777 0 0
file /bin/devmem $W/devmem 0755 0 0
file /init $ROOT/initramfs/panther/init 0755 0 0
EOF
[ -x "$KO/usr/gen_init_cpio" ] || make -C "$SRC" O="$KO" usr/gen_init_cpio > /dev/null
"$KO/usr/gen_init_cpio" "$W/initramfs.list" | lz4 -l -9 -q > "$W/initramfs.cpio.lz4"
: | cpio -o -H newc --quiet > "$W/empty.cpio"

# --- device tree --------------------------------------------------------------------
# ABL picks the base DTB by soc_id: one copy per value, built value first
echo "=== dtb.img, dtbo.img ==="
first=${SOC_IDS%% *}
"$DTC" -q -I dtb -O dts "$DTB" | grep -c "soc_id = <$first " > /dev/null || { echo "$DTB is not built with soc_id $first" >&2; exit 1; }
dtbs=()
for id in $SOC_IDS; do
	if [ "$id" = "$first" ]; then
		cp "$DTB" "$W/panther-$id.dtb"
	else
		"$DTC" -q -I dtb -O dts "$DTB" | sed "s/soc_id = <$first /soc_id = <$id /" | "$DTC" -q -I dts -O dtb -o "$W/panther-$id.dtb" -
	fi
	dtbs+=("$W/panther-$id.dtb")
done
cat "${dtbs[@]}" > "$W/dtb.img"
# Our bootargs are the DTB's /chosen/bootargs (ABL ignores vendor_cmdline for
# kernel arguments); extra ones go into each copy.
if [ -n "$EXTRA" ]; then
	for f in "${dtbs[@]}"; do
		"$DTC" -q -I dtb -O dts "$f" | sed "s|bootargs = \"\([^\"]*\)\";|bootargs = \"\1$EXTRA\";|" | "$DTC" -q -I dts -O dtb -o "$f.new" -
		mv "$f.new" "$f"
	done
	cat "${dtbs[@]}" > "$W/dtb.img"
fi
grep -c "board_id = <$BOARD_ID>;" "$ROOT/kernel/panther/panther-dtbo.dts" > /dev/null || { echo "panther-dtbo.dts: board_id is not $BOARD_ID" >&2; exit 1; }
"$DTC" -q -@ -I dts -O dtb -o "$W/panther.dtbo" "$ROOT/kernel/panther/panther-dtbo.dts"
python3 -I "$AOSP/libufdt/utils/src/mkdtboimg.py" create "$OUT/dtbo.img" \
	--page_size=4096 --id="$BOARD_ID" --rev="$BOARD_REV" "$W/panther.dtbo"

# --- boot images (header v4) ------------------------------------------------------------
echo "=== boot images ==="
MKBOOT="python3 $AOSP/mkbootimg/mkbootimg.py"
lz4 -l -9 -f -q "$IMAGE" "$W/Image.lz4"
$MKBOOT --header_version 4 --kernel "$W/Image.lz4" --cmdline '' --output "$OUT/boot.img"
$MKBOOT --header_version 4 --ramdisk "$W/empty.cpio" \
	--os_version "$OS_VERSION" --os_patch_level "$OS_PATCH_LEVEL" --output "$OUT/init_boot.img"
$MKBOOT --header_version 4 --pagesize "$VENDOR_PAGESIZE" --vendor_cmdline "$VENDOR_CMDLINE" \
	--ramdisk_type 1 --ramdisk_name '' --vendor_ramdisk_fragment "$W/empty.cpio" --vendor_boot "$OUT/vendor_boot.img"
$MKBOOT --header_version 4 --pagesize "$VENDOR_PAGESIZE" --vendor_cmdline '' \
	--dtb "$W/dtb.img" --ramdisk_type 1 --ramdisk_name '' --vendor_ramdisk_fragment "$W/initramfs.cpio.lz4" \
	--vendor_boot "$OUT/vendor_kernel_boot.img"

AVB="python3 -I $AOSP/avb/avbtool.py"
KEY=$AOSP/avb/test/data/testkey_rsa4096.pem
$AVB add_hash_footer --image "$OUT/boot.img" --partition_name boot --partition_size $((BOOT_SIZE)) \
	--algorithm SHA256_RSA4096 --key "$KEY" --rollback_index $ROLLBACK_INDEX
$AVB add_hash_footer --image "$OUT/init_boot.img" --partition_name init_boot --partition_size $((INIT_BOOT_SIZE)) \
	--algorithm SHA256_RSA4096 --key "$KEY" --rollback_index $ROLLBACK_INDEX

(cd "$OUT" && sha256sum boot.img init_boot.img vendor_boot.img vendor_kernel_boot.img dtbo.img > SHA256SUMS)
echo "panther" > "$OUT/DEVICE"
ls -l "$OUT"
