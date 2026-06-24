# Bazzite rpm-ostree Packaging Design

## Goal

Provide a maintainable Bazzite path for the ASUS UM3405GA sound workaround
without directly mutating the immutable `/usr` deployment.

## Architecture

The repository is split by distro path. Ubuntu keeps the original mutable
module patch. Bazzite builds local RPMs that rpm-ostree can layer into a new
deployment.

The Bazzite fix is decomposed into three RPMs:

- `um3405ga-support` installs the modprobe soft dependency, rebind helper, and
  systemd unit.
- `um3405ga-cs35l41-tuning` installs the CS35L41 firmware aliases under
  `/usr/lib/firmware/cirrus`.
- `um3405ga-snd-hda-alc269-hotfix` replaces the exact kernel module for the
  currently installed kernel only when the UM3405GA quirk is missing.

## Constraints

- The module hotfix is kernel-version-specific and must be rebuilt after kernel
  updates until the upstream quirk ships.
- Secure Boot/module-signature enforcement may block the patched module unless
  it is signed with a trusted key or enforcement is disabled.
- The firmware tuning RPM reuses the related UM3406HA coefficient files and
  should be tested at low volume first.
- The rebind service remains optional but installable because the generic HDA
  codec can win probing on affected boots.

## Verification

The repository includes `tests/check-repo.sh`, which checks expected files,
shell syntax, and Bazzite instruction coverage.
