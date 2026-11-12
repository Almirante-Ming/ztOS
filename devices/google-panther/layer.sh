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
# The amplifiers: stage c9 at digital 657 / analog 17 (20 dB under stock's
# 817 digital), with stock's V/I feedback stream to the AoC. At stock's
# 817 / 17, with none of stock's AoC processing in front, music heated the
# coils past the watchdog's limit (earpiece 25 -> 60 C) and the bottom
# speaker distorted; at media's 737 / 10 the bottom speaker hissed through
# the protection firmware. 657 / 17 played the tone tests clean, and the
# feedback stream made the bottom's hiss a little smaller (2026-10-26).
# Stage c9 also needs speaker_protection=1 (overlay/etc/modprobe.d) and the
# phone's own verification stamp: once, during playback,
#   omamobile-speaker-protection verify
cat >> "$R/etc/omamobile/speaker.conf" <<'EOF'
# ztOS, Pixel 7 (devices/google-panther/layer.sh)
OMAMOBILE_SPK_STAGE=c9
OMAMOBILE_SPK_DIGITAL=657
OMAMOBILE_SPK_ANALOG=17
OMAMOBILE_SPK_FEEDBACK=1
EOF
# The filter's trims: -12 dB. A -10 dBFS multitone held the coils at 25 C
# up to -9 dB; at -6 dB the bottom's coil temperature jumped 25 -> 52 C in
# under a second (most likely the firmware's estimate, but the watchdog
# mutes), so music, with its peaks, gets 3 dB more room (2026-10-26)
sed -i 's/\(name = trim_[lr] *label = linear *control = { "Mult" = \)1.0/\10.25/' \
	"$R/usr/share/pipewire/pipewire.conf.d/60-omamobile-speaker-loudness.conf"

# The cameras (kernel/panther/gs201-panther-camera.dtsi), with omarchy-mobile's
# loader (omamobile-device-cheetah, MIT): the drivers are blacklisted at boot
# (overlay/etc/modprobe.d/ztos-camera.conf) and loaded 40 s after it by
# omamobile-camera.timer, which gives up for good after a start that hung.
# The sensor and PHY settings are made from the user's own factory image
# (tools/extract-camera-data-panther) into build/camera-data: never in the repo
C=$DEVROOT/build/ref/omarchy-mobile/packages/omamobile-device-cheetah
install -m755 "$C/bin/omamobile-camera-start" "$R/usr/bin/omamobile-camera-start"
install -m644 "$C/vendor/systemd/system/omamobile-camera.service" \
	"$C/vendor/systemd/system/omamobile-camera.timer" "$R/etc/systemd/system/"
install -Dm644 "$C/vendor/udev/rules.d/70-omamobile-dma-heap.rules" "$R/etc/udev/rules.d/70-omamobile-dma-heap.rules"
# both wait for cheetah's ultrawide link (CSIS 2), which panther leaves off:
# the main camera's link 1 instead
sed -i 's|1a460000\.csis|1a450000.csis|' "$R/usr/bin/omamobile-camera-start" \
	"$R/etc/systemd/system/omamobile-camera.service"
! grep -q 1a460000 "$R/usr/bin/omamobile-camera-start" "$R/etc/systemd/system/omamobile-camera.service" \
	|| { echo "omamobile-camera still waits for CSIS 2" >&2; exit 1; }
if [ -d "$DEVROOT/build/camera-data" ]; then
	install -d "$R/usr/lib/firmware/omamobile/camera"
	cp --no-preserve=ownership "$DEVROOT"/build/camera-data/*.bin "$R/usr/lib/firmware/omamobile/camera/"
else
	echo "no build/camera-data (tools/extract-camera-data-panther): no cameras" >&2
fi

# the Windows Phone / Lumia photos, made from the OneDrive zip by os/wallpapers/make-wallpapers.py
if [ -d "$DEVROOT/build/wallpapers/backgrounds/ztos" ]; then
	install -d "$R/usr/local/share/backgrounds"
	cp -a --no-preserve=ownership "$DEVROOT/build/wallpapers/backgrounds/ztos" "$R/usr/local/share/backgrounds/"
fi
chmod 755 "$R"/usr/local/bin/ztos-* 2>/dev/null || true

# The boot-success marker (omarchy-mobile's omamobile-device-cheetah, MIT):
# without it ABL burns a retry each boot and after three goes back to stock
# on slot B. It sets one bit in devinfo, slot A's "successful" (byte 0x31),
# and checks that no other byte changed; the user allowed this one write
# (2026-10-26). A copy of devinfo from before is in build/devinfo-backup/.
B=$DEVROOT/build/ref/omarchy-mobile/packages/omamobile-device-cheetah
install -d "$R/usr/src/omamobile-bootctl"
cp "$B/src/omamobile-bootctl.c" "$R/usr/src/omamobile-bootctl/"
ch cc -O2 -Wall -o /usr/bin/omamobile-bootctl /usr/src/omamobile-bootctl/omamobile-bootctl.c
rm -rf "$R/usr/src/omamobile-bootctl"
install -m755 "$B/bin/omamobile-boot-success" "$R/usr/bin/omamobile-boot-success"
install -m644 "$B/vendor/systemd/system/omamobile-boot-success.service" "$R/etc/systemd/system/"

# USB back after a replug (omarchy-mobile's omamobile-device-cheetah, MIT):
# the MAX77759's Type-C side opens its USB2 data switch (TCPC register 0x93)
# on unplug, and with no Type-C driver nothing closes it again. While VBUS is
# valid this puts it back to 0x09, as the bootloader leaves it; needs i2c-tools.
install -m755 "$B/bin/omamobile-usb-rescue" "$R/usr/bin/omamobile-usb-rescue"
install -m644 "$B/vendor/systemd/system/omamobile-usb-rescue.service" "$R/etc/systemd/system/"

DEVICE_UNITS="zboot-usb-gadget ztos-usb-dhcp zboot-firstboot ztos-wifi bluetooth omamobile-boot-success omamobile-speaker-protection omamobile-camera.timer omamobile-usb-rescue"
