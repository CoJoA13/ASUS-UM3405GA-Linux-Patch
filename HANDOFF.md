# Fresh Bazzite Handoff

This file is the short path back to the UM3405GA sound workaround after the
current machine is formatted and Bazzite is installed.

## Clone This Repository

```bash
git clone https://github.com/CoJoA13/ASUS-UM3405GA-Linux-Patch.git
cd ASUS-UM3405GA-Linux-Patch
```

If this work was pushed to a temporary branch instead of `main`, fetch and check
out that branch before building:

```bash
git fetch origin
git checkout codex/bazzite-rpm-ostree-fix
```

## Install Build Tooling If Needed

Run the builders first. If they report that `rpmbuild` is missing:

```bash
sudo rpm-ostree install rpm-build
sudo reboot
```

Then return to the cloned repository.

## Build the RPMs

```bash
./bazzite/build-support-rpm.sh
./bazzite/build-cs35l41-tuning-rpm.sh
./bazzite/build-module-hotfix-rpm.sh
```

The RPMs are written to `./dist`.

If `build-module-hotfix-rpm.sh` says the booted kernel already contains the
UM3405GA quirk, do not install the module hotfix RPM.

## Install Support and Firmware Tuning

```bash
sudo rpm-ostree install ./dist/um3405ga-support-*.rpm ./dist/um3405ga-cs35l41-tuning-*.rpm
sudo reboot
sudo systemctl enable --now um3405ga-sound-rebind.service
```

## Install the Kernel Module Hotfix Only If Needed

Only run this when `./dist/um3405ga-snd-hda-alc269-hotfix-*.rpm` exists:

```bash
sudo rpm-ostree install --force-replacefiles ./dist/um3405ga-snd-hda-alc269-hotfix-*.rpm
sudo reboot
```

Secure Boot/module-signature enforcement can block the patched module. If that
happens, boot with enforcement disabled or sign the module with a trusted local
key.

## Verify

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

## Remove or Roll Back

To roll back the last deployment:

```bash
sudo rpm-ostree rollback
sudo reboot
```

To remove the local fix packages:

```bash
sudo rpm-ostree uninstall um3405ga-snd-hda-alc269-hotfix um3405ga-cs35l41-tuning um3405ga-support
sudo reboot
```

Full details live in `docs/bazzite-rpm-ostree.md`.
