# Bazzite rpm-ostree Fix

These scripts build local RPMs that can be layered on Bazzite with rpm-ostree.
They do not directly modify `/usr` or `/lib/modules` on the running deployment.

Build order:

```bash
./bazzite/build-support-rpm.sh
./bazzite/build-cs35l41-tuning-rpm.sh
./bazzite/build-module-hotfix-rpm.sh
```

The module hotfix is only needed when the booted Bazzite kernel lacks upstream
commit `f61bc797ac0075dbaac5e44238674858e9dbe399`. If the builder reports that
the quirk is already present, skip the module RPM.

Full instructions are in [../docs/bazzite-rpm-ostree.md](../docs/bazzite-rpm-ostree.md).
