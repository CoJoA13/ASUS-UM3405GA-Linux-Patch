# Bazzite rpm-ostree Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and document local RPM packaging for the UM3405GA sound workaround on Bazzite.

**Architecture:** Split the repository by distro path. Keep Ubuntu's mutable scripts under `ubuntu/`, shared helpers under `shared/`, upstream patch material under `patches/`, and rpm-ostree builders under `bazzite/`.

**Tech Stack:** Bash, rpmbuild, rpm-ostree, zstd, perl.

## Global Constraints

- Do not directly modify `/usr` on Bazzite; produce RPMs for rpm-ostree.
- Keep the module hotfix specific to the kernel release it was built from.
- Preserve rollback instructions for both package layering and full kernel overrides.
- Keep shell scripts valid under `bash -n`.

---

### Task 1: Repository Contract Test

**Files:**
- Create: `tests/check-repo.sh`

**Interfaces:**
- Produces: a shell test that validates required files, shell syntax, and key documentation strings.

- [x] Add `tests/check-repo.sh`.
- [x] Run `bash tests/check-repo.sh` and confirm it fails before the restructure.

### Task 2: Distro Split

**Files:**
- Modify: `README.md`
- Move: `patch-um3405ga-sound.sh` to `ubuntu/patch-um3405ga-sound.sh`
- Move: `install-um3405ga-cs35l41-tuning.sh` to `ubuntu/install-cs35l41-tuning.sh`
- Move: `rebind-um3405ga-sound.sh` to `shared/rebind-um3405ga-sound.sh`
- Move: `um3405ga-upstream.patch` to `patches/um3405ga-upstream.patch`
- Create: `ubuntu/README.md`
- Create: `docs/ubuntu.md`

**Interfaces:**
- Consumes: the original Ubuntu scripts.
- Produces: a distro-specific Ubuntu path and a shared rebind helper.

- [x] Move files into distro-focused folders.
- [x] Update the Ubuntu patch script to find the shared rebind helper by script path.

### Task 3: Bazzite RPM Builders

**Files:**
- Create: `bazzite/build-support-rpm.sh`
- Create: `bazzite/build-cs35l41-tuning-rpm.sh`
- Create: `bazzite/build-module-hotfix-rpm.sh`
- Create: `bazzite/README.md`
- Create: `docs/bazzite-rpm-ostree.md`

**Interfaces:**
- Consumes: host firmware files, host kernel module, and shared rebind helper.
- Produces: local RPMs copied into `dist/`.

- [x] Add the support RPM builder.
- [x] Add the CS35L41 tuning RPM builder.
- [x] Add the kernel-module hotfix RPM builder.
- [x] Document build, install, verify, update, and rollback steps.

### Task 4: Verification

**Files:**
- Modify: executable bits for user-facing scripts.

**Interfaces:**
- Consumes: all scripts and docs created above.
- Produces: a passing static packaging contract.

- [x] Run `bash tests/check-repo.sh`.
- [x] Confirm output includes `Repository packaging contract OK`.
