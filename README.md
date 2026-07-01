# UM3405GA Sound Patch

This machine is an ASUS Zenbook 14 UM3405GA with Realtek ALC294 audio and
Cirrus CS35L41 speaker amps exposed through `CSC3551`.

The upstream kernel fix is commit `f61bc797ac0075dbaac5e44238674858e9dbe399`:

> ALSA: hda/realtek: Add CS35L41 I2C quirk for ASUS UM3405GA

Linux `7.1.2` is the target supported path for this repository. Use the Ubuntu
Mainline Kernel build instead of patching installed Ubuntu kernel modules:

```bash
sudo ./install-ubuntu-mainline-kernel.sh 7.1.2
sudo reboot
```

After reboot:

```bash
uname -r
journalctl -k -b --no-pager | grep -Ei 'UM3405|cs35l41|CSC3551|ALC294|snd_hda_codec_alc269'
readlink -f /sys/bus/hdaudio/devices/hdaudioC1D0/driver
speaker-test -Dhw:1,0 -c2 -t wav
```

The legacy local workaround in `patch-um3405ga-sound.sh` remains for older
kernels that predate the upstream commit. It patches installed
`snd-hda-codec-alc269.ko.zst` modules by replacing the existing UM3406HA quirk
ID `1043:1c03` with the UM3405GA quirk ID `1043:19f4`; both use
`ALC294_FIXUP_ASUS_I2C_HEADSET_MIC`.

The legacy patch changes module contents, so it strips the stale appended
module signature before recompressing. This requires Secure Boot/module-
signature enforcement to be disabled until an official kernel containing the
upstream commit is installed.

It also installs `/etc/modprobe.d/um3405ga-sound.conf` so
`snd_hda_codec_alc269` registers before `snd_hda_intel` probes the codec. This
prevents `snd_hda_codec_generic` from claiming the Realtek ALC294 first.

If the generic driver still wins at boot, the legacy installer also enables
`um3405ga-sound-rebind.service`, which unbinds `hdaudioC1D0` from generic and
binds it to `snd_hda_codec_alc269` after the HDA device exists.

For the legacy workaround, run:

```bash
sudo ./patch-um3405ga-sound.sh
sudo reboot
```

For a live rebind test without rebooting:

```bash
sudo ./rebind-um3405ga-sound.sh
```

## CS35L41 speaker tuning

If the speakers work but are quiet, the amps may still be using the generic
fallback coefficients. The helper below creates the UM3405GA firmware names
requested by the driver (`104319f4-spkid1`): it aliases the generic CS35L41
WMFW file and copies the closely related UM3406HA CS35L41 coefficient files
(`10431c03-spkid0`). It then tries to reload the DSP firmware:

```bash
sudo ./install-um3405ga-cs35l41-tuning.sh install
```

If the live reload does not complete, reboot before testing volume. Start at a
low volume after installing borrowed speaker tuning.

To go back to the generic fallback tuning:

```bash
sudo ./install-um3405ga-cs35l41-tuning.sh restore
```
