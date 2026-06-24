# Bazzite rpm-ostree Instructions

Use this path for Bazzite or another rpm-ostree image. The goal is to keep the
fix transactional and removable until Bazzite ships a kernel with upstream
commit `f61bc797ac0075dbaac5e44238674858e9dbe399`.

## What Gets Built

- `um3405ga-support`: installs the modprobe soft dependency, the rebind helper,
  and the systemd service.
- `um3405ga-cs35l41-tuning`: installs CS35L41 firmware aliases under
  `/usr/lib/firmware/cirrus`.
- `um3405ga-snd-hda-alc269-hotfix`: replaces the booted kernel's
  `snd-hda-codec-alc269.ko.zst` module when the UM3405GA quirk is missing.

The module hotfix is kernel-version-specific. Rebuild it after every Bazzite
kernel update until the upstream fix lands in the shipped kernel.

## Prepare Build Tools

On Bazzite, `rpm-build` may not be present. If the build scripts report a
missing `rpmbuild`, layer the build dependency and reboot:

```bash
sudo rpm-ostree install rpm-build
sudo reboot
```

The scripts also need `bash`, `perl`, and `zstd`. Those are normally available
on the host image; if not, layer the missing package the same way.

## Build RPMs

From the repository root on the Bazzite install:

```bash
./bazzite/build-support-rpm.sh
./bazzite/build-cs35l41-tuning-rpm.sh
./bazzite/build-module-hotfix-rpm.sh
```

The RPMs are copied into `./dist`.

If `build-module-hotfix-rpm.sh` prints that the kernel already contains the
UM3405GA quirk, do not install a module hotfix RPM. Install only support and
tuning.

## Install Support and Tuning

```bash
sudo rpm-ostree install ./dist/um3405ga-support-*.rpm ./dist/um3405ga-cs35l41-tuning-*.rpm
sudo reboot
sudo systemctl enable --now um3405ga-sound-rebind.service
```

## Install the Module Hotfix

Only do this if the module builder produced `um3405ga-snd-hda-alc269-hotfix`.

```bash
sudo rpm-ostree install --force-replacefiles ./dist/um3405ga-snd-hda-alc269-hotfix-*.rpm
sudo reboot
```

Secure Boot can block the patched module because changing the module invalidates
the original signature. If module-signature enforcement is active, either sign
the hotfixed module with a trusted local key or boot with enforcement disabled.

## Verify After Reboot

```bash
uname -r
readlink -f /sys/bus/hdaudio/devices/hdaudioC1D0/driver
systemctl status um3405ga-sound-rebind.service --no-pager
journalctl -k -b --no-pager | grep -Ei 'UM3405|104319f4|cs35l41|CSC3551|ALC294|Firmware Loaded|falling back'
speaker-test -Dhw:1,0 -c2 -t wav
```

The HDA codec should bind to `snd_hda_codec_alc269`. If it binds to
`snd_hda_codec_generic`, run:

```bash
sudo systemctl restart um3405ga-sound-rebind.service
readlink -f /sys/bus/hdaudio/devices/hdaudioC1D0/driver
```

## Update Flow

After a Bazzite update:

```bash
sudo rpm-ostree upgrade
sudo reboot
./bazzite/build-module-hotfix-rpm.sh
```

If the builder says the quirk is already present, remove the old hotfix package.
If it builds a new RPM, install the new one:

```bash
sudo rpm-ostree install --force-replacefiles ./dist/um3405ga-snd-hda-alc269-hotfix-*.rpm
sudo reboot
```

## Rollback and Removal

For an immediate bad deployment, roll back:

```bash
sudo rpm-ostree rollback
sudo reboot
```

To remove these local packages from the normal forward path:

```bash
sudo rpm-ostree uninstall um3405ga-snd-hda-alc269-hotfix um3405ga-cs35l41-tuning um3405ga-support
sudo reboot
```

If you later test a full kernel package set with `rpm-ostree override replace`
instead of this repository's local hotfix RPM, reset that style of override with
the matching base package names, for example:

```bash
sudo rpm-ostree override reset kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra
sudo reboot
```

## When Upstream Is Fixed

Once Bazzite ships a kernel containing
`f61bc797ac0075dbaac5e44238674858e9dbe399`, stop using the module hotfix. The
support and tuning RPMs may still be useful if firmware names are missing or the
generic driver wins during probing.
