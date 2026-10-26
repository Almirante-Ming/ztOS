# ztOS on the Pixel 7 (panther)

Google Pixel 7, Tensor G2 (gs201). Mainline Linux 7.3 with the gs201 support
of [linux-omarchy-mobile](https://github.com/derekross/linux-omarchy-mobile)
(the Pixel 7 Pro, cheetah, runs display, GPU, touch, Wi-Fi and battery on it),
and ztOS's own board file and boot stage.

## What differs from the Pixel 7 Pro

From the stock dtbo (factory image CP3A.261005.002.A1, entry 22, "PANTHER
MP", board id 0x30406 rev 0x10000):

| | panther | cheetah |
|---|---|---|
| Panel | Samsung S6E3FC3 (`samsung,s6e3fc3-p10`), 1080x2400, 60/90 Hz | S6E3HC3/HC4, BOE NT37290, 1440x3120 |
| Touch | Focaltech (`focaltech,ts`) on SPI, 10 points, 1079x2399 | Synaptics TCM on SPI |
| UWB | none | DW3000 |

Everything else is the same part: CS40L26A haptics, two CS35L41 amplifiers,
BCM4389 Wi-Fi and Bluetooth, BCM4775 GNSS, MAX77759 charger, fuel gauge and
Type-C, MAX77729, P9412 wireless charging, ST21NFC, the Goodix fingerprint
sensor and the S5300 modem.

## Slots

On this phone stock Android runs on **slot B**, and slot A was left
unbootable by an over-the-air update. ztOS goes on **slot A**, stock stays
on B:

- `scripts/flash-panther.sh prepare stock/panther` (once): the factory
  bootloader and vbmeta into slot A, so both slots start the same
  bootloader. Slot A is inactive, so a cut cable leaves B starting as before.
- `scripts/flash-panther.sh boot`: the five boot images into slot A, slot A
  active, reboot.
- `scripts/flash-panther.sh root <image>`: the Arch root into USERDATA.
  USERDATA is shared by both slots: Android's data is erased, and stock on B
  wants a factory reset if it is started again.
- `scripts/flash-panther.sh stock`: slot B active again.

Nothing marks slot A successful yet: every start uses one of ABL's retries,
and when they run out ABL starts stock on B. The boot stage guards the UFS:
only slot A's boot images and USERDATA are writable (`initramfs/panther/init`).

`boot` and `init_boot` are chained partitions in vbmeta, so they carry an
AVB footer signed with AVB's test key: an unlocked ABL accepts the wrong key
(orange state) but not a missing footer.

## Building

    scripts/build-boot-panther.sh [--rescue] [--no-kernel]

needs, under `build/` (none of it is in the repository):

| | |
|---|---|
| `linux-omamobile/` | `git clone --depth 1 -b omamobile-int https://github.com/derekross/linux-omarchy-mobile.git` |
| `ref/omarchy-mobile/` | `git clone --depth 1 https://github.com/derekross/omarchy-mobile.git` (its `kernel/configs/omamobile.config`) |
| `toolchain/` | ARM GNU toolchain 14.2.rel1, x86_64 host, aarch64-none-linux-gnu |
| `aosp/` | AOSP `system/tools/mkbootimg`, `system/libufdt`, `external/avb` |
| `busybox-arm64` | a static aarch64 busybox (Arch Linux ARM's has every applet the boot stage uses) |
| `host/usr/bin/bc` | if the host has no `bc` |

## Status

| | |
|---|---|
| Board file | first light, on the phone 2026-10-25: boot framebuffer (simpledrm, DECON0 trigger), USB NCM + ACM (telnet 172.16.42.1), UFS (the guard leaves only slot A's boot images and USERDATA writable), gpio-keys (power and volume seen in ztMETRO) |
| Touch | FocalTech FT3658 on SPI0, firmware 0x16: `patches/0002` (a mainline driver, fingers only) and `patches/0003` (S2MPG12 LDO25M/LDO26M as regulators: the bootloader leaves the touch unpowered on this phone) |
| GPU | Mali-G710 MC7 on Panthor, GLES 3.1. Arch Linux ARM's Mesa refuses the G710: ztOS installs omarchy-mobile's packages/mesa (G710 in the model table), built on the phone, from `build/packages/panther-mesa/` |
| Display | gs-decon (flip-only KMS on the bootloader's DECON0 -> DSIM0 -> panel), 90 Hz, on the phone 2026-10-25: `patches/0004` (the S6E3FC3 panel driver from Google's GPL one, gs-decon's modes chosen by the boot size, DPP0's stride following the buffer's (Mesa aligns 1080 pixels to 4352 bytes), the DSIM's link timers for 60 and 90 Hz). Brightness on `/sys/class/backlight/1c2c0000.dsi.0`; with the screen off the panel sleeps (`etc/modprobe.d/ztos-display.conf`) |
| Wi-Fi, Bluetooth | BCM4389C1, cheetah's nodes (the stock dtbo has the same pins), on the phone 2026-10-25: brcmfmac on PCIe GEN4A_1 (firmware 20.101.91, 2.4 and 5 GHz scan), hci_bcm on the APM UART. Firmware from the user's factory zip: `tools/extract-vendor-firmware-panther` into `build/vendor-fw/` (never in the repo); the build copies it in. Bring-up, MAC and BT address helpers from omarchy-mobile in `os/overlay-panther` |
| AoC, sensors | trusty, GSA and the AoC (board id 0x30401 from the stock dtbo), on the phone 2026-10-25: `ztos-aoc-start` (from omarchy-mobile) loads them in order after boot; omarchy-mobile's omamobile-sensors gives net.hadess.SensorProxy (accelerometer, light, proximity) |
| Sound | the AoC sound card (`gs201-panther-audio.dtsi`, omarchy-mobile's aoc-sound-test) and cheetah's two CS35L41 amplifiers on SPI7 (subsystem id `panther`), on the phone 2026-10-25: omarchy-mobile's omamobile-audio (protection firmware with the factory calibration read from persist, read-only; stage media, 17 dB below stock), cheetah's UCM verb under `Google/panther` |
| Next | a boot-successful marker for slot A, then cpufreq (ACPM DVFS), battery and charging |

`[I]` in `gs201-panther.dts` marks what is taken from cheetah and not yet
checked on this phone. The key presses themselves are still to be seen.
