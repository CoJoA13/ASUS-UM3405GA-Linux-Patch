# UM3405GA Sound Patch

This machine is an ASUS Zenbook 14 UM3405GA with Realtek ALC294 audio and
Cirrus CS35L41 speaker amps exposed through `CSC3551`. It reports the Realtek
subsystem ID `1043:19f4`.

The upstream kernel fix is commit `f61bc797ac0075dbaac5e44238674858e9dbe399`:

> ALSA: hda/realtek: Add CS35L41 I2C quirk for ASUS UM3405GA

## Which kernel do I need?

The quirk landed in the **Linux 7.2 merge window**: it is in `v7.2-rc1` and
newer, and it is **not** in any `7.1.x` stable release. A `7.1.x` kernel still
needs the legacy module patch below.

Start by asking the machine what it has:

```bash
./check-um3405ga-sound.sh
```

That reports the running kernel, whether its Realtek quirk table actually
contains `1043:19f4`, which driver claimed the codec, what the CS35L41 amps
bound as, and which tuning files are installed.

## Preferred fix: a mainline kernel with the quirk

```bash
sudo ./install-ubuntu-mainline-kernel.sh latest
sudo reboot
```

`latest` picks the newest Ubuntu Mainline build that both contains the quirk
(7.2 or newer) and has published amd64 packages — not every version finishes
building. Passing an explicit version works too:

```bash
sudo ./install-ubuntu-mainline-kernel.sh 7.2-rc5
```

The installer refuses versions older than 7.2, verifies SHA256 checksums, and
reads the quirk table out of the downloaded `linux-modules` package before
installing anything, so a kernel that would leave the speakers silent is caught
before `dpkg` runs. Set `VERIFY_QUIRK=0` to skip that check.

Mainline builds ship an **unsigned** kernel image, so Secure Boot has to be off
(or the image signed and enrolled with a MOK) for it to boot. The installer
warns if `mokutil` reports Secure Boot as enabled.

After reboot:

```bash
uname -r
./check-um3405ga-sound.sh
speaker-test -c2 -t wav
```

## Legacy fix: patch the installed module

For kernels that predate 7.2, `patch-um3405ga-sound.sh` edits the installed
`snd-hda-codec-alc269` module (or `snd-hda-codec-realtek` on kernels before
6.17) in place. It replaces the UM3406HA quirk ID `1043:1c03` with the UM3405GA
ID `1043:19f4`; both use `ALC294_FIXUP_ASUS_I2C_HEADSET_MIC`. A compiled quirk
table cannot grow, so the patched module drives the UM3405GA *instead of* the
UM3406HA. Kernels that already carry the upstream quirk are left untouched.

Editing module contents invalidates the appended module signature, which the
script strips, so this needs Secure Boot / module-signature enforcement
disabled.

```bash
sudo ./patch-um3405ga-sound.sh
sudo reboot
```

It also installs `/etc/modprobe.d/um3405ga-sound.conf` so
`snd_hda_codec_alc269` registers before `snd_hda_intel` probes the codec. This
prevents `snd_hda_codec_generic` from claiming the Realtek ALC294 first.

If the generic driver still wins at boot, the installer also enables
`um3405ga-sound-rebind.service`, which unbinds the ALC294 from the generic
driver and binds it to `snd_hda_codec_alc269` once the HDA device exists. The
codec is located by vendor ID, so a shifting card index does not break it.

For a live rebind test without rebooting:

```bash
sudo ./rebind-um3405ga-sound.sh
```

## CS35L41 speaker tuning

If the speakers work but are quiet, the amps are using the generic fallback
coefficients. `linux-firmware` ships no UM3405GA (`104319f4`) tuning at all, so
the helper borrows the closely related UM3406HA (`10431c03`) coefficients and
pairs them with the generic `cs35l41-dsp1-spk-prot.wmfw` — the only WMFW
upstream ships for either machine.

Both filenames have to exist: the driver only requests board-specific `.bin`
coefficients after a board-specific `.wmfw` matches, otherwise it falls straight
back to the generic tuning.

```bash
sudo ./install-um3405ga-cs35l41-tuning.sh install
```

The exact filenames the driver asks for depend on the speaker-ID GPIO it reads
at probe time, so the script takes the subsystem ID and speaker ID from the
driver's own `CS35L41 Bound - SSID: ..., SPKID: ...` log line. If that line is
not available it installs every variant the donor provides, so whichever name
the driver requests is there. Override with `TARGET_SSID`, `TARGET_SPKID`
(a number or `none`) and `DONOR_SPKID` if needed.

If the live reload does not complete, reboot before testing volume. **Start at a
low volume after installing borrowed speaker tuning** — these coefficients
describe someone else's speakers.

To go back to the generic fallback tuning:

```bash
sudo ./install-um3405ga-cs35l41-tuning.sh restore
```

## Files

| File | Purpose |
| --- | --- |
| `check-um3405ga-sound.sh` | Read-only report on kernel, quirk, codec binding and amp firmware |
| `install-ubuntu-mainline-kernel.sh` | Install a mainline kernel that contains the quirk |
| `patch-um3405ga-sound.sh` | Legacy in-place module patch for pre-7.2 kernels |
| `rebind-um3405ga-sound.sh` | Move the ALC294 off `snd_hda_codec_generic` |
| `install-um3405ga-cs35l41-tuning.sh` | Install/remove borrowed CS35L41 speaker tuning |
| `um3405ga-upstream.patch` | The upstream commit, for building your own kernel |
