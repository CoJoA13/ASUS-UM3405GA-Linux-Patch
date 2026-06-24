# UM3405GA Sound Patch

This repository collects temporary Linux audio fixes for the ASUS Zenbook 14
UM3405GA. The laptop uses a Realtek ALC294 codec with two Cirrus CS35L41 speaker
amps exposed through `CSC3551`.

The upstream kernel fix is commit `f61bc797ac0075dbaac5e44238674858e9dbe399`:

> ALSA: hda/realtek: Add CS35L41 I2C quirk for ASUS UM3405GA

That patch is kept at [patches/um3405ga-upstream.patch](patches/um3405ga-upstream.patch).
Once your distro ships a kernel containing that commit, the binary module
hotfix is no longer needed.

## Layout

- [bazzite/](bazzite/) builds local RPMs for rpm-ostree systems.
- [ubuntu/](ubuntu/) keeps the original mutable Ubuntu workaround.
- [shared/](shared/) contains helpers used by more than one distro path.
- [docs/bazzite-rpm-ostree.md](docs/bazzite-rpm-ostree.md) has the Bazzite
  build, install, verify, update, and rollback instructions.
- [docs/ubuntu.md](docs/ubuntu.md) has the Ubuntu instructions.

## Recommended Path

For Bazzite, start with the rpm-ostree packaging path:

```bash
./bazzite/build-support-rpm.sh
./bazzite/build-cs35l41-tuning-rpm.sh
./bazzite/build-module-hotfix-rpm.sh
```

If the module builder says the kernel already contains the UM3405GA quirk, skip
the module hotfix RPM and install only the support and tuning RPMs.

For Ubuntu, use:

```bash
sudo ./ubuntu/patch-um3405ga-sound.sh
sudo reboot
```
