# Ubuntu Fix

This keeps the original workaround for Ubuntu kernels that do not yet contain
upstream commit `f61bc797ac0075dbaac5e44238674858e9dbe399`.

The script patches installed `snd-hda-codec-alc269.ko.zst` modules by replacing
the existing ASUS UM3406HA subsystem ID `1043:1c03` with the UM3405GA subsystem
ID `1043:19f4`. Both entries use `ALC294_FIXUP_ASUS_I2C_HEADSET_MIC`.

Run from the repository root:

```bash
sudo ./ubuntu/patch-um3405ga-sound.sh
sudo reboot
```

If the speakers work but are quiet, install the borrowed CS35L41 tuning aliases:

```bash
sudo ./ubuntu/install-cs35l41-tuning.sh install
```

To return to generic fallback tuning:

```bash
sudo ./ubuntu/install-cs35l41-tuning.sh restore
```

To test the driver binding live:

```bash
sudo ./shared/rebind-um3405ga-sound.sh
```

Secure Boot/module-signature enforcement must not block the patched module. The
patch strips the stale appended signature after changing module contents.
