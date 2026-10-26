# SPDX-License-Identifier: GPL-2.0-or-later
"""Building ztOS: an Arch Linux ARM system made into ztOS, then a disk.

Everything runs unprivileged. The system is put together inside a user
namespace (`unshare --map-auto --map-root-user`): there, files can belong to
root and the other system users, and an aarch64 chroot runs through the
host's qemu-user binfmt handler. The disk images are made in the same
namespace (mke2fs -d, mtools), so nothing is ever mounted for real.
"""
from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]          # the repository
OS = ROOT / "os"
WORK = ROOT / "build" / "ztos"
TARBALL = ROOT / "build" / "alarm.tar.gz"
TARBALL_URL = "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
SDK = ROOT / "sdk"
PKGCACHE = ROOT / "build" / "pkg-cache"
EDK2 = Path("/usr/share/edk2/aarch64")


class Fail(Exception):
    pass


@dataclass
class Settings:
    target: str = "qemu"            # qemu | starlte | panther
    user: str = "ztos"
    password: str = "ztos"
    hostname: str = "ztos"
    timezone: str = "UTC"
    size_gb: int = 10               # the root filesystem
    fresh: bool = False             # start from the tarball again

    @property
    def dir(self) -> Path:
        return WORK / self.target


def say(*words):
    print("ztos:", *words, flush=True)


def packages(target: str) -> list:
    names = []
    for name in ("common", target):
        path = OS / "packages" / name
        if path.exists():
            for line in path.read_text().splitlines():
                line = line.split("#", 1)[0].strip()
                if line:
                    names.append(line)
    return names


def check_host(target: str = "qemu"):
    """What building needs on this computer (the FAT tools: only the emulator's disk)."""
    missing = []
    tools = ["unshare", "newuidmap", "bsdtar", "sfdisk", "python3"]
    if target == "qemu":
        tools += ["mkfs.fat", "mcopy", "mmd"]
    for tool in tools:
        if shutil.which(tool) is None:
            missing.append(tool)
    if not Path("/usr/bin/mke2fs").exists() and not Path("/usr/sbin/mke2fs").exists():
        missing.append("mke2fs (e2fsprogs)")
    if not Path("/proc/sys/fs/binfmt_misc/qemu-aarch64").exists():
        missing.append("qemu-user-static + qemu-user-static-binfmt (to run aarch64 programs)")
    user = os.environ.get("USER", "")
    subuid = Path("/etc/subuid").read_text() if Path("/etc/subuid").exists() else ""
    if os.geteuid() != 0 and not re.search(rf"^{re.escape(user)}:", subuid, re.M):
        missing.append(f"a /etc/subuid range for {user} (usermod --add-subuids 100000-165535 {user})")
    if missing:
        raise Fail("this computer is missing what building ztOS needs:\n  " + "\n  ".join(missing) +
                   "\nOn Arch Linux: sudo pacman -S --needed util-linux libarchive dosfstools mtools e2fsprogs "
                   "qemu-user-static qemu-user-static-binfmt")


def fetch_tarball():
    if TARBALL.exists() and TARBALL.stat().st_size > 100_000_000:
        return
    say(f"downloading Arch Linux ARM ({TARBALL_URL})")
    TARBALL.parent.mkdir(parents=True, exist_ok=True)
    tmp = TARBALL.with_suffix(".part")
    subprocess.run(["curl", "-L", "--fail", "-o", str(tmp), TARBALL_URL], check=True)
    tmp.replace(TARBALL)


def build_apps(stage: Path):
    """Build the selected default system apps for aarch64."""
    out = stage / "apps"
    # A reused staging directory must not keep apps removed from the defaults.
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(SDK))
    from ztos_sdk import cli as sdk
    projects = (OS / "apps" / "welcome", OS / "apps" / "whatsapp", ROOT / "apps" / "music")
    for project in projects:
        p = sdk.find_project(str(project))
        python = "%d.%d" % sys.version_info[:2]
        binary = sdk.build(p, "aarch64", python=python)
        shutil.copy2(binary, out / p.id)
        shutil.copy2(project / p.icon, out / f"{p.id}.svg")
        (out / f"{p.id}.desktop").write_text("\n".join([
            "[Desktop Entry]", "Type=Application", f"Name={p.name}",
            f"Comment={p.manifest['description'] or p.name}",
            f"Exec=/usr/local/lib/ztos/apps/{p.id}",
            f"Icon=/usr/local/share/icons/hicolor/scalable/apps/{p.id}.svg",
            "Terminal=false", f"StartupWMClass=ztos.{p.id}", "Categories=System;", "",
        ]))


# The work inside the namespace, as root there. Each "step" line is what the
# installer shows; everything else goes to the log.
STAGE = r'''
set -eu
step() { echo "STEP $*"; }
R=$ROOTFS
umask 022

if [ "$FRESH" = 1 ] || [ ! -e "$R/etc/arch-release" ]; then
	step "unpacking Arch Linux ARM"
	rm -rf "$R"; mkdir -p "$R"
	bsdtar -xpf "$TARBALL" -C "$R" --no-xattrs --no-acls --no-fflags
fi

mount --bind "$R" "$R"
mount --rbind /dev "$R/dev"
mount -t proc proc "$R/proc"
mount -t tmpfs tmpfs "$R/tmp"
mkdir -p "$PKGCACHE" "$R/var/cache/pacman/pkg"
mount --bind "$PKGCACHE" "$R/var/cache/pacman/pkg"
rm -f "$R/etc/resolv.conf"; cp -L /etc/resolv.conf "$R/etc/resolv.conf"
ch() { chroot "$R" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin HOME=/root LANG=C.UTF-8 "$@"; }
P="pacman --disable-sandbox --noconfirm"
# Units are switched on from outside the chroot where the host has systemctl:
# under qemu-user, aarch64 systemctl crashes in this PID namespace (SIGSEGV).
sc() {
	if command -v systemctl > /dev/null 2>&1; then
		systemctl --root="$R" "$@"
	else
		ch systemctl "$@"
	fi
}

if [ "$TARGET" = starlte ] || [ "$TARGET" = panther ]; then
	# the kernel is ztOS's own boot image there, never a package
	sed -i 's/^#\?IgnorePkg *=.*/IgnorePkg   = linux-aarch64 linux-aarch64-headers/' "$R/etc/pacman.conf"
fi

step "setting up package signing keys"
ch sh -c 'pacman-key --init && pacman-key --populate archlinuxarm' > /dev/null

step "updating the base system"
ch $P -Syu

step "installing ztOS's packages (this is the long part)"
ch $P -S --needed $PACKAGES

if [ "$TARGET" = panther ]; then
	# Mesa with the Mali-G710 in Panfrost's model table (omarchy-mobile's
	# packages/mesa, built on the phone): Arch Linux ARM's refuses the GPU
	set -- "$SRC"/build/packages/panther-mesa/mesa-*.pkg.tar.*
	if [ -f "$1" ]; then
		cp "$1" "$R/tmp/"
		ch $P -U "/tmp/${1##*/}"
		sed -i 's/^IgnorePkg *=.*/& mesa/' "$R/etc/pacman.conf"
	else
		echo "(no build/packages/panther-mesa: the session draws in software)"
	fi
fi

step "removing the other desktops (ztMETRO is the only shell)"
for p in sddm gdm lightdm hyprland plasma-workspace kwin phosh phoc gnome-shell weston sway; do
	ch pacman -Qq "$p" > /dev/null 2>&1 && ch $P -Rns "$p" || true
done

step "building ztMETRO and its apps"
rm -rf "$R/usr/src/ztmetro"; mkdir -p "$R/usr/src"
cp -a --no-preserve=ownership "$SRC/ztmetro" "$R/usr/src/ztmetro"
rm -rf "$R/usr/src/ztmetro/ref"
ch sh -c 'cd /usr/src/ztmetro && make clean >/dev/null 2>&1; make -j"$(nproc)" && make install'
ch sh -c 'cd /usr/src/ztmetro && make clean >/dev/null 2>&1' || true

step "adding ztOS's files"
cp -a --no-preserve=ownership "$SRC/os/overlay/." "$R/"
cp -a --no-preserve=ownership "$SRC/os/overlay-$TARGET/." "$R/"
if [ "$TARGET" = starlte ]; then
	cp -a --no-preserve=ownership "$SRC/rootfs/overlay/." "$R/"         # the phone's own: USB link, charger, fallbacks
	# the panel's brightness table is made from its calibration (ztos-panel-bl)
	install -Dm755 "$SRC/kernel/s9p-bl-table.py" "$R/usr/local/lib/ztos/s9p-bl-table.py"
	# the Windows Phone / Lumia photos, made from the OneDrive zip by os/wallpapers/make-wallpapers.py
	if [ -d "$SRC/build/wallpapers/backgrounds/ztos" ]; then
		install -d "$R/usr/local/share/backgrounds"
		cp -a --no-preserve=ownership "$SRC/build/wallpapers/backgrounds/ztos" "$R/usr/local/share/backgrounds/"
	fi
	install -Dm644 -t "$R/usr/lib/firmware/brcm" "$SRC"/firmware/bcmdhd* "$SRC"/firmware/nvram*
	for f in "$SRC"/firmware/calliope_*.bin; do
		[ -f "$f" ] && install -Dm644 -t "$R/usr/lib/firmware" "$f"
	done
	install -d "$R/usr/lib/modules/7.1.0-zboot/extra"
	install -d "$R/usr/local/lib"
	if [ -f "$SRC/modem/zrn-modem/zrn-modem.ko" ]; then
		install -m644 "$SRC/modem/zrn-modem/zrn-modem.ko" "$R/usr/local/lib/zrn-modem.ko"
		install -m644 "$SRC/modem/zrn-modem/zrn-modem.ko" "$R/usr/lib/modules/7.1.0-zboot/extra/"
	elif [ -f "$SRC/prebuilts/modules/zrn-modem.ko" ]; then
		install -m644 "$SRC/prebuilts/modules/zrn-modem.ko" "$R/usr/local/lib/zrn-modem.ko"
		install -m644 "$SRC/prebuilts/modules/zrn-modem.ko" "$R/usr/lib/modules/7.1.0-zboot/extra/"
	fi
	for k in "$SRC"/prebuilts/modules/*.ko \
	         "$SRC"/power/idle/zrn-cpuidle.ko "$SRC"/haptics/zrn-haptic.ko \
	         "$SRC"/power/hotplug/zrn-hotplug.ko "$SRC"/leds/zrn-led.ko \
	         "$SRC"/sensors/driver/zrn-bbd.ko "$SRC"/audio/driver/snd-zrn-abox.ko \
	         "$SRC"/audio/modules/*.ko; do
		[ -f "$k" ] && install -m644 "$k" "$R/usr/lib/modules/7.1.0-zboot/extra/"
	done
	if [ -f "$SRC/build/linux-7.1/out/modules.builtin" ]; then
		install -m644 "$SRC/build/linux-7.1/out/modules.builtin" "$R/usr/lib/modules/7.1.0-zboot/"
		install -m644 "$SRC/build/linux-7.1/out/modules.builtin.modinfo" "$R/usr/lib/modules/7.1.0-zboot/"
	fi
	ch depmod -a 7.1.0-zboot > /dev/null 2>&1 || true
	for moddir in "$R"/usr/lib/modules/*; do
		[ -d "$moddir" ] || continue
		kver=$(basename "$moddir")
		[ "$kver" = "7.1.0-zboot" ] && continue
		install -d "$moddir/extra"
		for k in "$SRC"/prebuilts/modules/*.ko \
		         "$SRC"/power/idle/zrn-cpuidle.ko "$SRC"/haptics/zrn-haptic.ko \
		         "$SRC"/power/hotplug/zrn-hotplug.ko "$SRC"/leds/zrn-led.ko \
		         "$SRC"/sensors/driver/zrn-bbd.ko "$SRC"/audio/driver/snd-zrn-abox.ko \
		         "$SRC"/audio/modules/*.ko; do
			[ -f "$k" ] && install -m644 "$k" "$moddir/extra/"
		done
		ch depmod -a "$kver" > /dev/null 2>&1 || true
	done
	chmod 755 "$R"/usr/local/sbin/* 2>/dev/null || true
fi
if [ "$TARGET" = panther ]; then
	# of the S9's own files, what is not the S9's hardware: the USB link, the
	# first boot, the kept crash logs, the power key, sudo for the session
	for f in usr/local/sbin/zboot-usb-gadget usr/local/sbin/zboot-firstboot \
	         etc/systemd/system/zboot-usb-gadget.service etc/systemd/system/zboot-firstboot.service \
	         etc/systemd/system/ztos-pstore-keep.service etc/systemd/pstore.conf.d/ztos.conf \
	         etc/systemd/logind.conf.d/10-zboot.conf etc/sudoers.d/99-ztos-shell; do
		install -Dm644 "$SRC/rootfs/overlay/$f" "$R/$f"
	done
	chmod 755 "$R"/usr/local/sbin/zboot-*
	chmod 440 "$R/etc/sudoers.d/99-ztos-shell"
	# zrnperfd is the S9's cpufreq and hotplug policy: with no cpufreq here it
	# only spins and takes cores offline under the session
	rm -f "$R/etc/systemd/system/zrnperfd.service"
	ln -sf /dev/null "$R/etc/systemd/system/zrnperfd.service"
	# the modules of ztOS's kernel (scripts/build-boot-panther.sh, make modules)
	rm -rf "$R/usr/lib/modules/"*
	cp -a --no-preserve=ownership "$KMODS/lib/modules/." "$R/usr/lib/modules/"
	for kver in $(ls "$R/usr/lib/modules"); do
		ch depmod -a "$kver" > /dev/null 2>&1 || true
	done
	# Wi-Fi and Bluetooth firmware, Google's, from the user's own factory
	# image (tools/extract-vendor-firmware-panther): never in the repo
	if [ -d "$SRC/build/vendor-fw/out/usr/lib/firmware" ]; then
		cp -r --no-preserve=ownership "$SRC/build/vendor-fw/out/usr/lib/firmware/." "$R/usr/lib/firmware/"
		# the AoC's sensor registry, for omamobile-sensors
		cp -r --no-preserve=ownership "$SRC/build/vendor-fw/out/usr/share/omamobile" "$R/usr/share/"
	else
		echo "no build/vendor-fw (tools/extract-vendor-firmware-panther): no Wi-Fi, Bluetooth or AoC" >&2
	fi
	# the AoC's sensors as iio-sensor-proxy's D-Bus API (omarchy-mobile's
	# omamobile-sensors, MIT); its unit is overridden in overlay-panther to
	# follow ztos-aoc.service
	"$SRC/build/ref/omarchy-mobile/packages/omamobile-sensors/install" "$R"
	# the speakers and microphones behind the AoC (omarchy-mobile's
	# omamobile-audio, MIT): panther's amplifiers are cheetah's, with
	# subsystem-id "panther" (its firmware names) and cheetah's UCM verb
	A=$SRC/build/ref/omarchy-mobile/packages/omamobile-audio
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
fi
install -d "$R/usr/local/share/fonts/selawik"
install -m644 "$SRC"/os/fonts/selawik/*.ttf "$R/usr/local/share/fonts/selawik/"
ch fc-cache -f > /dev/null 2>&1 || true

step "installing the ztOS SDK"
rm -rf "$R/usr/local/lib/ztos-sdk"; mkdir -p "$R/usr/local/lib"
cp -a --no-preserve=ownership "$SRC/sdk" "$R/usr/local/lib/ztos-sdk"
ln -sf ../lib/ztos-sdk/bin/ztos-sdk "$R/usr/local/bin/ztos-sdk"
S=$R/etc/skel/.local/share/ztos
install -Dm644 "$SRC/sdk/runtime/zygote.py" "$S/zygote.py"
install -d "$S/lib/ztos"
install -m644 "$SRC"/sdk/runtime/ztos/*.py "$S/lib/ztos/"
ch python3 -m compileall -q /etc/skel/.local/share/ztos/lib > /dev/null || true

step "installing ztOS's apps (Welcome, Updates)"
install -d "$R/usr/local/lib/ztos/apps" "$R/usr/local/share/applications" "$R/usr/local/share/icons/hicolor/scalable/apps"
for f in "$STAGEDIR"/apps/*.desktop; do
	id=$(basename "$f" .desktop)
	install -m755 "$STAGEDIR/apps/$id" "$R/usr/local/lib/ztos/apps/$id"
	install -m644 "$f" "$R/usr/local/share/applications/$id.desktop"
	install -m644 "$STAGEDIR/apps/$id.svg" "$R/usr/local/share/icons/hicolor/scalable/apps/$id.svg"
done

step "making your account"
if [ "$USERNAME" != alarm ] && ch id alarm > /dev/null 2>&1; then
	ch userdel -r alarm > /dev/null 2>&1 || ch userdel alarm
fi
if ! ch id "$USERNAME" > /dev/null 2>&1; then
	ch useradd -m -u 1000 -G wheel,video,audio,input -s /bin/bash "$USERNAME"
fi
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | ch chpasswd
ch passwd -l root > /dev/null
install -Dm440 /dev/stdin "$R/etc/sudoers.d/10-wheel" <<'SUDO'
%wheel ALL=(ALL:ALL) ALL
SUDO
if [ -d "$R/etc/sudoers.d" ]; then
	chmod 440 "$R"/etc/sudoers.d/* 2>/dev/null || true
	if [ "$USERNAME" != alarm ] && [ -f "$R/etc/sudoers.d/99-ztos-alarm" ]; then
		sed -i "s/^alarm /$USERNAME /" "$R/etc/sudoers.d/99-ztos-alarm"
	fi
fi
sed -i "s/@USER@/$USERNAME/" "$R/etc/greetd/config.toml"

step "time, language and name"
echo "$HOSTNAME" > "$R/etc/hostname"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$R/etc/locale.gen"
ch locale-gen > /dev/null
echo LANG=en_US.UTF-8 > "$R/etc/locale.conf"
: > "$R/etc/machine-id"

step "turning on ztOS's services"
# (systemd-resolved: names; NetworkManager hands it each network's DNS)
# (systemd-pstore: the kernel log of a crash or hang is kept in /var/lib/systemd/pstore)
for u in greetd NetworkManager systemd-resolved sshd systemd-pstore ztos-pstore-keep ztoscoresensorframework ztos-update-check.timer; do
	sc enable "$u" > /dev/null 2>&1 || echo "(could not enable $u)"
done
# the user session's sound (Arch only presets them; with no preset run they stay off)
for u in pipewire.socket pipewire-pulse.socket wireplumber.service; do
	sc --global enable "$u" > /dev/null 2>&1 || echo "(could not enable $u for users)"
done
for u in systemd-networkd getty@tty1; do
	sc disable "$u" > /dev/null 2>&1 || true
done
if [ "$TARGET" = starlte ]; then
	for u in zboot-usb-gadget zboot-firstboot zboot-charge-hold zrn-charge zrn-cpuidle ztoscirrusaudio ztoscsf-sensorhub \
			ztoscsf-sensord ztoscorenetworking-modem ztoscorenetworking zrnperfd ztos-panel-selfmask ztos-panel-bl; do
		sc enable "$u" > /dev/null 2>&1 || echo "(no $u)"
	done
fi
if [ "$TARGET" = panther ]; then
	for u in zboot-usb-gadget ztos-usb-dhcp zboot-firstboot ztos-wifi bluetooth; do
		sc enable "$u" > /dev/null 2>&1 || echo "(no $u)"
	done
fi
if [ "$TARGET" = qemu ]; then
	cat > "$R/etc/fstab" <<'FSTAB'
# ztOS in QEMU
PARTLABEL=ztos-root  /          ext4  rw,relatime  0 1
PARTLABEL=ztos-esp   /boot/efi  vfat  rw,relatime,fmask=0077,dmask=0077  0 2
FSTAB
	mkdir -p "$R/boot/efi"
	step "making the start-up image (initramfs)"
	ch mkinitcpio -P > /dev/null 2>&1 || ch mkinitcpio -P
	# what the boot partition takes, readable outside this namespace
	install -d "$STAGEDIR/boot"
	install -m644 "$R/boot/Image" "$STAGEDIR/boot/Image"
	install -m644 "$R/boot/initramfs-linux.img" "$STAGEDIR/boot/initramfs.img"
	install -m644 "$R/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$STAGEDIR/boot/BOOTAA64.EFI"
fi

step "tidying up"
rm -f "$R/etc/resolv.conf"; ln -sf /run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
rm -rf "$R/tmp/"* "$R/var/log/pacman.log"
echo ztos > "$R/etc/ztos/built"
date -u +%Y-%m-%dT%H:%MZ >> "$R/etc/ztos/built"

step "writing the system image"
# Re-arm first boot even when building from a previously used root tree.
# The image filesystem is smaller than the phone's USERDATA partition.
if [ "$TARGET" = starlte ] || [ "$TARGET" = panther ]; then
	touch "$R/etc/zboot-firstboot"
fi
umount -l "$R/var/cache/pacman/pkg" 2>/dev/null || true
umount -l "$R/tmp" "$R/proc" 2>/dev/null || true
umount -lR "$R/dev" 2>/dev/null || true
umount -l "$R" 2>/dev/null || true
rm -f "$ROOTIMG"
"$MKE2FS" -q -t ext4 -L "$LABEL" -m 1 -O ^orphan_file -d "$R" "$ROOTIMG" "${SIZE}G"
echo STAGE-OK
'''


def run_stage(s: Settings, log: Path) -> None:
    """The system, built in the namespace; its steps shown as they go."""
    s.dir.mkdir(parents=True, exist_ok=True)
    stage_dir = s.dir / "stage"
    build_apps(stage_dir)
    mke2fs = "/usr/bin/mke2fs" if Path("/usr/bin/mke2fs").exists() else "/usr/sbin/mke2fs"
    env = {
        "ROOTFS": str(s.dir / "root"), "TARBALL": str(TARBALL), "SRC": str(ROOT), "STAGEDIR": str(stage_dir),
        "TARGET": s.target, "PACKAGES": " ".join(packages(s.target)), "USERNAME": s.user,
        "PASSWORD": s.password, "HOSTNAME": s.hostname, "TIMEZONE": s.timezone, "FRESH": "1" if s.fresh else "0",
        "ROOTIMG": str(s.dir / "root.img"), "SIZE": str(s.size_gb), "MKE2FS": mke2fs,
        "LABEL": "ZR_ARCH" if s.target in ("starlte", "panther") else "ztos-root",
        "KMODS": str(panther_modules()) if s.target == "panther" else "",
        "PKGCACHE": str(PKGCACHE),
        "PATH": os.environ.get("PATH", "/usr/bin"),
    }
    script = s.dir / "stage.sh"
    script.write_text(STAGE)
    started = time.monotonic()
    total_pkgs = 0
    pkg_idx = 0
    in_progress = False
    with open(log, "w") as out:
        unshare_cmd = ["unshare", "--mount", "--fork", "--pid"] if os.geteuid() == 0 else [
            "unshare", "--map-auto", "--map-root-user", "--mount", "--fork", "--pid"
        ]
        proc = subprocess.Popen([*unshare_cmd, "sh", str(script)], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, bufsize=1)
        ok = False
        for line in proc.stdout:
            out.write(line)
            out.flush()
            if line.startswith("STEP "):
                if in_progress:
                    print()
                    in_progress = False
                minutes = (time.monotonic() - started) / 60
                say(f"[{minutes:4.1f} min] {line[5:].strip()}")
                total_pkgs = 0
                pkg_idx = 0
            elif line.strip() == "STAGE-OK":
                ok = True
            else:
                m = re.search(r"Packages \((\d+)\)", line)
                if m:
                    total_pkgs = int(m.group(1))
                    pkg_idx = 0
                elif line.startswith("installing "):
                    pkg_name = line[11:].rstrip(".\n")
                    pkg_idx += 1
                    pct = int((pkg_idx / total_pkgs) * 100) if total_pkgs > 0 else 0
                    bar_len = 16
                    filled = int(bar_len * pct / 100)
                    bar = "█" * filled + "░" * (bar_len - filled)
                    minutes = (time.monotonic() - started) / 60
                    status = f"[{bar}] {pct:3d}% ({pkg_idx}/{total_pkgs}) installing {pkg_name}"
                    print(f"\rztos: [{minutes:4.1f} min] {status[:60]:<60}", end="", flush=True)
                    in_progress = True
                elif " downloading...\n" in line:
                    dl_name = line.split()[0] if line.split() else ""
                    minutes = (time.monotonic() - started) / 60
                    status = f"downloading {dl_name}"
                    print(f"\rztos: [{minutes:4.1f} min] {status[:60]:<60}", end="", flush=True)
                    in_progress = True
                elif (line.startswith("cc ") or line.startswith("gcc ") or line.startswith("CC ") or
                      line.startswith("GEN ") or " -o " in line):
                    words = line.split()
                    target = words[-1] if words else ""
                    minutes = (time.monotonic() - started) / 60
                    status = f"compiling {target}"
                    print(f"\rztos: [{minutes:4.1f} min] {status[:60]:<60}", end="", flush=True)
                    in_progress = True
        if in_progress:
            print()
        proc.wait()
    if proc.returncode != 0 or not ok:
        tail = "".join(log.read_text().splitlines(True)[-25:])
        raise Fail(f"building the system failed (the whole log: {log}):\n{tail}")


def make_qemu_disk(s: Settings) -> Path:
    """A GPT disk, as a PC or a phone has: an EFI system partition with
    systemd-boot and the kernel, and the ztOS root."""
    rootimg, esp = s.dir / "root.img", s.dir / "esp.img"
    boot = s.dir / "stage" / "boot"
    kernel, initrd, boot_efi = boot / "Image", boot / "initramfs.img", boot / "BOOTAA64.EFI"
    for need in (kernel, initrd, boot_efi):
        if not need.exists():
            raise Fail(f"the build left no {need.name} (see the log)")
    say("writing the boot partition (systemd-boot)")
    esp.unlink(missing_ok=True)
    subprocess.run(["truncate", "-s", "256M", str(esp)], check=True)
    subprocess.run(["mkfs.fat", "-F", "32", "-n", "ZTOS-ESP", str(esp)], check=True, stdout=subprocess.DEVNULL)
    m = ["-i", str(esp)]
    for d in ("::/EFI", "::/EFI/BOOT", "::/loader", "::/loader/entries", "::/ztos"):
        subprocess.run(["mmd", *m, d], check=True)
    loader = s.dir / "loader.conf"
    loader.write_text("default ztos.conf\ntimeout 0\nconsole-mode keep\n")
    entry = s.dir / "ztos.conf"
    entry.write_text("title ztOS\nlinux /ztos/Image\ninitrd /ztos/initramfs.img\n"
                     "options root=PARTLABEL=ztos-root rw quiet loglevel=3 console=ttyAMA0 console=tty1\n")
    for src, dst in ((boot_efi, "::/EFI/BOOT/BOOTAA64.EFI"), (loader, "::/loader/loader.conf"),
                     (entry, "::/loader/entries/ztos.conf"), (kernel, "::/ztos/Image"),
                     (initrd, "::/ztos/initramfs.img")):
        subprocess.run(["mcopy", *m, str(src), dst], check=True)
    say("putting the disk together")
    disk = s.dir / "ztos-qemu.img"
    mib = 1024 * 1024
    esp_size, root_size = esp.stat().st_size, rootimg.stat().st_size
    total = mib + esp_size + root_size + mib
    disk.unlink(missing_ok=True)
    subprocess.run(["truncate", "-s", str(total), str(disk)], check=True)
    layout = (f"label: gpt\n"
              f"start=2048, size={esp_size // 512}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=ztos-esp\n"
              f"start={2048 + esp_size // 512}, size={root_size // 512}, "
              f"type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name=ztos-root\n")
    subprocess.run(["sfdisk", "-q", str(disk)], input=layout, text=True, check=True)
    subprocess.run(["dd", f"if={esp}", f"of={disk}", "bs=1M", f"seek=1", "conv=notrunc,sparse", "status=none"],
                   check=True)
    subprocess.run(["dd", f"if={rootimg}", f"of={disk}", "bs=1M", f"seek={1 + esp_size // mib}",
                    "conv=notrunc,sparse", "status=none"], check=True)
    esp.unlink()
    return disk


def panther_modules() -> Path:
    """The Pixel 7 kernel's modules, installed into a directory of their own
    (the kernel itself is in the boot image: scripts/build-boot-panther.sh)."""
    out = ROOT / "build" / "out-panther"
    stage = ROOT / "build" / "panther-modules"
    if not (out / "modules.order").exists():
        raise Fail("the Pixel 7 kernel's modules are not built: scripts/build-boot-panther.sh, then "
                   "make -C build/linux-omamobile O=../out-panther modules")
    tc = ROOT / "build" / "toolchain" / "arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu" / "bin"
    env = dict(os.environ, ARCH="arm64", CROSS_COMPILE="aarch64-none-linux-gnu-",
               PATH=f"{ROOT / 'build' / 'host' / 'usr' / 'bin'}:{tc}:{os.environ.get('PATH', '')}")
    shutil.rmtree(stage, ignore_errors=True)
    say("installing the Pixel 7 kernel's modules")
    subprocess.run(["make", "-C", str(ROOT / "build" / "linux-omamobile"), "O=../out-panther",
                    f"INSTALL_MOD_PATH={stage}", "INSTALL_MOD_STRIP=1", "modules_install"],
                   env=env, check=True, stdout=subprocess.DEVNULL)
    return stage


def build(s: Settings) -> Path:
    check_host(s.target)
    fetch_tarball()
    log = s.dir / "build.log"
    rootimg = s.dir / "root.img"
    if rootimg.exists() and not s.fresh:
        say(f"using existing system image: {rootimg}")
    else:
        say(f"building ztOS for {s.target} (log: {log})")
        run_stage(s, log)
    if s.target == "qemu":
        disk = make_qemu_disk(s)
        (s.dir / "root.img").unlink(missing_ok=True)
        say(f"ready: {disk} ({disk.stat().st_size // (1024 ** 3)} GB)")
        return disk
    image = s.dir / "root.img"
    say(f"ready: {image} (the root filesystem, for USERDATA)")
    return image
