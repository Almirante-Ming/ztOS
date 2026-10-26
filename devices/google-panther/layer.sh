# The Google Pixel 7 (panther) device layer, run by the installer inside the
# build namespace after the GSI part, with $R (the root), $DEVSRC (this folder:
# vendor/, overlay/, packages.txt), $DEVROOT (the device repository: kernel/,
# build/...; ztOSMobile itself before the split), $P (pacman), $KMODS (the
# kernel's modules, installed by build.py), step and ch (run in the root).
# Everything here is the Pixel 7's own: the GSI carries none of it.
D=$DEVSRC

step "adding the Pixel 7 device layer"
# (packages.txt went in with the GSI's packages, and the kernel was held
# back from pacman before the first update: build.py)

# ztOSIAL: the manifest
install -d "$R/vendor/ztos"
cp -a "$D/vendor/ztos/." "$R/vendor/ztos/"
chown -R 0:0 "$R/vendor"

cp -a --no-preserve=ownership "$D/overlay/." "$R/"   # the phone's own: AoC, Wi-Fi, Bluetooth, USB DHCP, speakers

# The filesystem recovery keeps its count on the S9's CACHE, and falls back to
# /dev/sda21 when no filesystem is labelled cache. Here sda21 is init_boot_b,
# stock Android's slot B, which ztOS never writes: no fallback, so with no
# CACHE the recovery stays bounded (it refuses to reboot in a loop).
for f in ztos-auto-recover ztos-fs-recovery-reset; do
	sed -i '\|device=/dev/sda21|d' "$R/usr/local/sbin/$f"
	! grep -q sda21 "$R/usr/local/sbin/$f" || { echo "$f still falls back to sda21" >&2; exit 1; }
done

# Mesa with the Mali-G710 in Panfrost's model table (omarchy-mobile's
# packages/mesa, built on the phone): Arch Linux ARM's refuses the GPU
set -- "$DEVROOT"/build/packages/panther-mesa/mesa-*.pkg.tar.*
if [ -f "$1" ]; then
	cp "$1" "$R/tmp/"
	ch $P -U "/tmp/${1##*/}"
	sed -i 's/^IgnorePkg *=.*/& mesa/' "$R/etc/pacman.conf"
else
	echo "(no build/packages/panther-mesa: the session draws in software)"
fi

# the modules of ztOS's kernel (scripts/build-boot-panther.sh, make modules)
rm -rf "$R/usr/lib/modules/"*
cp -a --no-preserve=ownership "$KMODS/lib/modules/." "$R/usr/lib/modules/"
for kver in $(ls "$R/usr/lib/modules"); do
	ch depmod -a "$kver" > /dev/null 2>&1 || true
done

# Wi-Fi and Bluetooth firmware, Google's, from the user's own factory
# image (tools/extract-vendor-firmware-panther): never in the repo
if [ -d "$DEVROOT/build/vendor-fw/out/usr/lib/firmware" ]; then
	cp -r --no-preserve=ownership "$DEVROOT/build/vendor-fw/out/usr/lib/firmware/." "$R/usr/lib/firmware/"
	# the AoC's sensor registry, for omamobile-sensors
	cp -r --no-preserve=ownership "$DEVROOT/build/vendor-fw/out/usr/share/omamobile" "$R/usr/share/"
else
	echo "no build/vendor-fw (tools/extract-vendor-firmware-panther): no Wi-Fi, Bluetooth or AoC" >&2
fi

# the AoC's sensors as iio-sensor-proxy's D-Bus API (omarchy-mobile's
# omamobile-sensors, MIT); its unit is overridden in overlay/ to follow
# ztos-aoc.service
"$DEVROOT/build/ref/omarchy-mobile/packages/omamobile-sensors/install" "$R"
# the speakers and microphones behind the AoC (omarchy-mobile's
# omamobile-audio, MIT): panther's amplifiers are cheetah's, with
# subsystem-id "panther" (its firmware names) and cheetah's UCM verb
A=$DEVROOT/build/ref/omarchy-mobile/packages/omamobile-audio
"$A/install" "$R"
sed -i 's/^SYSTEM=cheetah$/SYSTEM=panther/' "$R/usr/bin/omamobile-speaker-protection"
sed -i 's|cirrus/cs35l41-cheetah-|cirrus/cs35l41-panther-|' "$R/usr/lib/omamobile-audio/speaker_dsp.py"
U=$R/usr/share/alsa/ucm2
install -Dm644 "$A/ucm2/Google/cheetah/HiFi.conf" "$U/Google/panther/HiFi.conf"
rm -r "$U/Google/cheetah"
sed -i 's|/Google/cheetah/|/Google/panther/|' "$U/conf.d/aoc-snd-card/aoc-snd-card.conf"
# The amplifiers stay at omarchy-mobile's media levels (17 dB under stock):
# at stock's 817 / 17, with none of stock's AoC processing in front, music
# heated the coils past the watchdog's limit (earpiece 25 -> 60 C) and the
# bottom speaker distorted (2026-10-26). Even at media, music above about
# -18 dBFS overdrives them (the protection firmware clips audibly and the
# bottom coil heats past the watchdog's limit; a -16 dBFS limiter did not
# stop it). 50 % of PipeWire's volume (-18 dB) played clean, so the
# filter's trims make 100 % that
sed -i 's/\(name = trim_[lr] *label = linear *control = { "Mult" = \)1.0/\10.125/' \
	"$R/usr/share/pipewire/pipewire.conf.d/60-omamobile-speaker-loudness.conf"

# the Windows Phone / Lumia photos, made from the OneDrive zip by os/wallpapers/make-wallpapers.py
if [ -d "$DEVROOT/build/wallpapers/backgrounds/ztos" ]; then
	install -d "$R/usr/local/share/backgrounds"
	cp -a --no-preserve=ownership "$DEVROOT/build/wallpapers/backgrounds/ztos" "$R/usr/local/share/backgrounds/"
fi
chmod 755 "$R"/usr/local/bin/ztos-* 2>/dev/null || true

DEVICE_UNITS="zboot-usb-gadget ztos-usb-dhcp zboot-firstboot ztos-wifi bluetooth"
