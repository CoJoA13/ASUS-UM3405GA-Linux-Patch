#!/usr/bin/env bash
set -euo pipefail

# Install an Ubuntu Mainline Kernel build. Linux 7.1.2 contains the upstream
# UM3405GA Realtek/CS35L41 quirk, so this replaces the old binary module patch.

default_version=7.1.2
version=${1:-${default_version}}
base_url=${KERNEL_PPA_BASE_URL:-https://kernel.ubuntu.com/~kernel-ppa/mainline}
arch=${ARCH:-amd64}
workdir=${WORKDIR:-}
keep_downloads=${KEEP_DOWNLOADS:-0}

usage() {
	cat <<EOF_HELP
Usage:
  sudo $0 [kernel-version]

Defaults:
  kernel-version=${default_version}
  KERNEL_PPA_BASE_URL=${base_url}
  ARCH=${arch}

Examples:
  sudo $0
  sudo $0 7.1.2

This installs Ubuntu Mainline Kernel .deb packages from:
  ${base_url}/v<kernel-version>/${arch}/
EOF_HELP
}

if [[ ${version} == --help || ${version} == -h ]]; then
	usage
	exit 0
fi

if [[ ${EUID} -ne 0 ]]; then
	printf 'Run this as root:\n  sudo %q %q\n' "$0" "${version}" >&2
	exit 1
fi

case "$(uname -m)" in
	x86_64) expected_arch=amd64 ;;
	aarch64|arm64) expected_arch=arm64 ;;
	*) expected_arch='' ;;
esac

if [[ -n "${expected_arch}" && "${arch}" != "${expected_arch}" ]]; then
	printf 'Refusing to install %s packages on %s. Set ARCH=%s if this is intentional.\n' \
		"${arch}" "$(uname -m)" "${expected_arch}" >&2
	exit 1
fi

for tool in awk curl dpkg sed sha256sum sort; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		printf 'Missing required tool: %s\n' "${tool}" >&2
		exit 1
	fi
done

release_url="${base_url}/v${version}/${arch}/"
if [[ -z "${workdir}" ]]; then
	workdir=$(mktemp -d)
	cleanup() {
		if [[ ${keep_downloads} != 1 ]]; then
			rm -rf "${workdir}"
		else
			printf 'Keeping downloaded packages in: %s\n' "${workdir}"
		fi
	}
	trap cleanup EXIT
else
	mkdir -p "${workdir}"
fi

printf 'Fetching Ubuntu Mainline Kernel package index:\n  %s\n' "${release_url}"
index_file="${workdir}/index.html"
curl -fsSL "${release_url}" -o "${index_file}"

mapfile -t packages < <(
	sed -n 's/.*href="\([^"]*\.deb\)".*/\1/p' "${index_file}" |
		awk -v arch="${arch}" '
			/linux-headers-[0-9].*_all[.]deb$/ { print }
			$0 ~ "linux-headers-[0-9].*-generic_.*_" arch "[.]deb$" { print }
			$0 ~ "linux-image-unsigned-[0-9].*-generic_.*_" arch "[.]deb$" { print }
			$0 ~ "linux-modules-[0-9].*-generic_.*_" arch "[.]deb$" { print }
		' |
		sort -u
)

if [[ ${#packages[@]} -lt 4 ]]; then
	printf 'Could not find the expected mainline kernel packages at %s\n' "${release_url}" >&2
	printf 'Found %s matching package(s):\n' "${#packages[@]}" >&2
	printf '  %s\n' "${packages[@]:-none}" >&2
	exit 1
fi

printf 'Downloading %s package(s)...\n' "${#packages[@]}"
for package in "${packages[@]}"; do
	curl -fL --retry 3 --retry-delay 2 -o "${workdir}/${package}" "${release_url}${package}"
done

if curl -fsSL "${release_url}CHECKSUMS" -o "${workdir}/CHECKSUMS"; then
	printf 'Verifying package checksums...\n'
	: >"${workdir}/CHECKSUMS.selected"
	for package in "${packages[@]}"; do
		if ! awk -v package="${package}" '$2 == package || $2 == "*" package { print; found=1 } END { exit found ? 0 : 1 }' \
			"${workdir}/CHECKSUMS" >>"${workdir}/CHECKSUMS.selected"; then
			printf 'Checksum entry not found for %s\n' "${package}" >&2
			exit 1
		fi
	done
	(
		cd "${workdir}"
		sha256sum -c CHECKSUMS.selected
	)
else
	printf 'WARNING: CHECKSUMS not available; skipping checksum verification.\n' >&2
fi

printf 'Installing Ubuntu Mainline Kernel %s packages...\n' "${version}"
dpkg -i "${packages[@]/#/${workdir}/}"

cat <<EOF_DONE

Installed Ubuntu Mainline Kernel ${version}.
Reboot and choose the new kernel if GRUB does not select it automatically, then check:
  uname -r
  journalctl -k -b --no-pager | grep -Ei 'UM3405|cs35l41|CSC3551|ALC294|snd_hda_codec_alc269'

If speakers are detected but quiet, run:
  sudo ./install-um3405ga-cs35l41-tuning.sh install
EOF_DONE
