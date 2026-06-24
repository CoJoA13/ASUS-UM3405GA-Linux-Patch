# Ubuntu Instructions

The Ubuntu path is for mutable systems where replacing a file under
`/lib/modules` is acceptable.

1. Patch installed kernels:

   ```bash
   sudo ./ubuntu/patch-um3405ga-sound.sh
   sudo reboot
   ```

2. Verify the Realtek codec driver wins:

   ```bash
   readlink -f /sys/bus/hdaudio/devices/hdaudioC1D0/driver
   journalctl -k -b --no-pager | grep -Ei 'UM3405|cs35l41|CSC3551|ALC294'
   ```

3. If speakers work but are quiet, install the CS35L41 tuning aliases:

   ```bash
   sudo ./ubuntu/install-cs35l41-tuning.sh install
   sudo reboot
   ```

4. Restore fallback tuning if needed:

   ```bash
   sudo ./ubuntu/install-cs35l41-tuning.sh restore
   sudo reboot
   ```

The mutable Ubuntu module patch is not the preferred Bazzite approach. Use
[docs/bazzite-rpm-ostree.md](bazzite-rpm-ostree.md) for rpm-ostree systems.
