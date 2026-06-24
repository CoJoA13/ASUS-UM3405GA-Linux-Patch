#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

required_files=(
	"HANDOFF.md"
	"README.md"
	"bazzite/README.md"
	"bazzite/build-cs35l41-tuning-rpm.sh"
	"bazzite/build-module-hotfix-rpm.sh"
	"bazzite/build-support-rpm.sh"
	"docs/bazzite-rpm-ostree.md"
	"docs/ubuntu.md"
	"patches/um3405ga-upstream.patch"
	"shared/rebind-um3405ga-sound.sh"
	"ubuntu/README.md"
	"ubuntu/install-cs35l41-tuning.sh"
	"ubuntu/patch-um3405ga-sound.sh"
)

for path in "${required_files[@]}"; do
	if [[ ! -e "${repo_root}/${path}" ]]; then
		printf 'Missing required file: %s\n' "${path}" >&2
		exit 1
	fi
done

shell_scripts=(
	"bazzite/build-cs35l41-tuning-rpm.sh"
	"bazzite/build-module-hotfix-rpm.sh"
	"bazzite/build-support-rpm.sh"
	"shared/rebind-um3405ga-sound.sh"
	"ubuntu/install-cs35l41-tuning.sh"
	"ubuntu/patch-um3405ga-sound.sh"
)

for script in "${shell_scripts[@]}"; do
	bash -n "${repo_root}/${script}"
done

grep -Fq 'rpm-ostree install ./dist/um3405ga-support' "${repo_root}/docs/bazzite-rpm-ostree.md"
grep -Fq './dist/um3405ga-cs35l41-tuning' "${repo_root}/docs/bazzite-rpm-ostree.md"
grep -Fq 'rpm-ostree install --force-replacefiles' "${repo_root}/docs/bazzite-rpm-ostree.md"
grep -Fq 'rpm-ostree override reset' "${repo_root}/docs/bazzite-rpm-ostree.md"
grep -Fq 'Fresh Bazzite Handoff' "${repo_root}/HANDOFF.md"
grep -Fq 'git clone https://github.com/CoJoA13/ASUS-UM3405GA-Linux-Patch.git' "${repo_root}/HANDOFF.md"
grep -Fq '/usr/lib/firmware/cirrus' "${repo_root}/bazzite/build-cs35l41-tuning-rpm.sh"
grep -Fq '/usr/lib/modules' "${repo_root}/bazzite/build-module-hotfix-rpm.sh"
grep -Fq '/usr/lib/systemd/system' "${repo_root}/bazzite/build-support-rpm.sh"
grep -Fq 'f61bc797ac0075dbaac5e44238674858e9dbe399' "${repo_root}/patches/um3405ga-upstream.patch"

printf 'Repository packaging contract OK\n'
