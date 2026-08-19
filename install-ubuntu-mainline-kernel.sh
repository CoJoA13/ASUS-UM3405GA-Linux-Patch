#!/usr/bin/env bash
set -euo pipefail

# Install an Ubuntu Mainline Kernel build that already contains the upstream
# UM3405GA Realtek/CS35L41 quirk from commit f61bc797ac00.
#
# The quirk first appears in Linux 7.2-rc1. Every 7.1.x stable release predates
# it, so those kernels still need the legacy binary module patch in
# patch-um3405ga-sound.sh.

quirk_major=7
quirk_minor=2
quirk_bytes='\x43\x10\xf4\x19' # 1043:19f4 as stored in struct snd_pci_quirk

default_version=7.2-rc5
version=${1:-${default_version}}
base_url=${KERNEL_PPA_BASE_URL:-https://kernel.ubuntu.com/~kernel-ppa/mainline}
arch=${ARCH:-amd64}
workdir=${WORKDIR:-}
keep_downloads=${KEEP_DOWNLOADS:-0}
verify_quirk=${VERIFY_QUIRK:-1}

usage() {
	cat <<EOF_HELP
Usage:
  sudo $0 [kernel-version|latest]

Defaults:
  kernel-version=${default_version}
  KERNEL_PPA_BASE_URL=${base_url}
  ARCH=${arch}
  VERIFY_QUIRK=${verify_quirk}   (set to 0 to skip the UM3405GA quirk check)

Examples:
  sudo $0
  sudo $0 latest
  sudo $0 7.2-rc5

"latest" picks the newest published mainline build that both contains the
UM3405GA quirk (Linux ${quirk_major}.${quirk_minor} or newer) and has ${arch} packages available.

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

if [[ "${verify_quirk}" == "1" ]]; then
	for tool in dpkg-deb perl tar; do
		if ! command -v "${tool}" >/dev/null 2>&1; then
			printf 'Missing %s; set VERIFY_QUIRK=0 to install without the quirk check.\n' "${tool}" >&2
			exit 1
		fi
	done
fi

# Mainline builds label release candidates "7.2-rc5"; dpkg orders those
# correctly only when the suffix is written "7.2~rc5".
deb_version() {
	printf '%s\n' "${1/-rc/\~rc}"
}

# The quirk landed in the 7.2 merge window, so any 7.2 release (including its
# release candidates) carries it and anything older does not.
version_has_quirk() {
	local ver=${1#v} major minor

	major=${ver%%.*}
	minor=${ver#*.}
	minor=${minor%%[.-]*}

	[[ ${major} =~ ^[0-9]+$ && ${minor} =~ ^[0-9]+$ ]] || return 1
	((major > quirk_major)) && return 0
	((major == quirk_major && minor >= quirk_minor))
}

arch_packages() {
	local release_url=$1

	curl -fsSL "${release_url}" 2>/dev/null |
		sed -n 's/.*href="\([^"]*\.deb\)".*/\1/p' |
		awk -v arch="${arch}" '
			/linux-headers-[0-9].*_all[.]deb$/ { print }
			$0 ~ "linux-headers-[0-9].*-generic_.*_" arch "[.]deb$" { print }
			$0 ~ "linux-image-unsigned-[0-9].*-generic_.*_" arch "[.]deb$" { print }
			$0 ~ "linux-modules-[0-9].*-generic_.*_" arch "[.]deb$" { print }
		' |
		sort -u
}

resolve_latest() {
	local index candidate ver count

	index=$(curl -fsSL "${base_url}/") || {
		printf 'Could not fetch the mainline index: %s\n' "${base_url}/" >&2
		return 1
	}

	while read -r candidate; do
		[[ -n "${candidate}" ]] || continue
		printf 'Checking v%s for %s packages...\n' "${candidate}" "${arch}" >&2
		count=$(arch_packages "${base_url}/v${candidate}/${arch}/" | wc -l)
		if [[ "${count}" -ge 4 ]]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done < <(
		printf '%s\n' "${index}" |
			sed -n 's/.*href="v\([^"/]*\)\/".*/\1/p' |
			while read -r ver; do
				version_has_quirk "${ver}" && printf '%s\t%s\n' "$(deb_version "${ver}")" "${ver}"
			done |
			sort -Vr -k1,1 |
			cut -f2
	)

	printf 'No mainline build newer than %s.%s has %s packages yet.\n' \
		"${quirk_major}" "${quirk_minor}" "${arch}" >&2
	return 1
}

# Read the alc269 quirk table straight out of the downloaded module package, so
# a kernel that would leave the speakers silent is never installed by mistake.
# Prints "present", "absent" or "unknown".
quirk_state_in_deb() {
	local deb=$1
	local tmpdir module raw decompressed
	local -a modules=()

	tmpdir=$(mktemp -d)
	trap 'rm -rf "${tmpdir}"' RETURN

	dpkg-deb --fsys-tarfile "${deb}" |
		tar -x -C "${tmpdir}" --wildcards --wildcards-match-slash \
			'*snd-hda-codec-alc269.ko*' '*snd-hda-codec-realtek.ko*' 2>/dev/null || true

	mapfile -t modules < <(find "${tmpdir}" -type f \
		\( -name 'snd-hda-codec-alc269.ko*' -o -name 'snd-hda-codec-realtek.ko*' \) | sort)

	if [[ ${#modules[@]} -eq 0 ]]; then
		printf 'unknown\n'
		return 0
	fi

	for module in "${modules[@]}"; do
		raw="${tmpdir}/module.ko"
		decompressed=1
		case "${module}" in
			*.zst) zstd -q -dc "${module}" >"${raw}" 2>/dev/null || decompressed=0 ;;
			*.xz) xz -dc "${module}" >"${raw}" 2>/dev/null || decompressed=0 ;;
			*.gz) gzip -dc "${module}" >"${raw}" 2>/dev/null || decompressed=0 ;;
			*) raw="${module}" ;;
		esac

		if [[ "${decompressed}" == "0" ]]; then
			printf 'unknown\n'
			return 0
		fi

		if PATTERN="${quirk_bytes}" perl -0777 -ne '
			my $pattern = $ENV{"PATTERN"};
			$pattern =~ s/\\x([0-9a-fA-F]{2})/chr(hex($1))/ge;
			exit(index($_, $pattern) >= 0 ? 0 : 1);
		' "${raw}"; then
			printf 'present\n'
			return 0
		fi
	done

	printf 'absent\n'
}

if [[ "${version}" == latest ]]; then
	version=$(resolve_latest)
	printf 'Selected latest mainline build with the UM3405GA quirk: %s\n' "${version}"
fi

version=${version#v}

if ! version_has_quirk "${version}"; then
	cat >&2 <<EOF_OLD
Refusing to install Linux ${version}: the UM3405GA quirk (1043:19f4) first
appears in Linux ${quirk_major}.${quirk_minor}-rc1, so this kernel would leave the internal
speakers silent.

Install a ${quirk_major}.${quirk_minor} build instead:
  sudo $0 latest

Or stay on this kernel and use the legacy binary module patch:
  sudo ./patch-um3405ga-sound.sh
EOF_OLD
	exit 1
fi

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
mapfile -t packages < <(arch_packages "${release_url}")

if [[ ${#packages[@]} -lt 4 ]]; then
	printf 'Could not find the expected mainline kernel packages at %s\n' "${release_url}" >&2
	printf 'Found %s matching package(s):\n' "${#packages[@]}" >&2
	printf '  %s\n' "${packages[@]:-none}" >&2
	printf 'Some mainline versions never finish building. Try:\n  sudo %q latest\n' "$0" >&2
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
		# CHECKSUMS carries a SHA1 section as well as a SHA256 one; feeding the
		# SHA1 lines to sha256sum makes verification fail on good downloads.
		if ! awk -v package="${package}" '
			length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && ($2 == package || $2 == "*" package) {
				print
				found = 1
			}
			END { exit found ? 0 : 1 }
		' "${workdir}/CHECKSUMS" >>"${workdir}/CHECKSUMS.selected"; then
			printf 'SHA256 checksum entry not found for %s\n' "${package}" >&2
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

if [[ "${verify_quirk}" == "1" ]]; then
	modules_deb=''
	for package in "${packages[@]}"; do
		case "${package}" in
			linux-modules-*) modules_deb="${workdir}/${package}" ;;
		esac
	done

	if [[ -z "${modules_deb}" ]]; then
		printf 'WARNING: no linux-modules package found; skipping the quirk check.\n' >&2
	else
		case "$(quirk_state_in_deb "${modules_deb}")" in
			present)
				printf 'Confirmed the UM3405GA quirk (1043:19f4) is present in Linux %s.\n' \
					"${version}"
				;;
			absent)
				printf 'Refusing to install Linux %s: its alc269 quirk table has no 1043:19f4 entry.\n' \
					"${version}" >&2
				printf 'Set VERIFY_QUIRK=0 to install anyway.\n' >&2
				exit 1
				;;
			*)
				printf 'WARNING: could not read the alc269 quirk table; skipping the quirk check.\n' >&2
				;;
		esac
	fi
fi

printf 'Installing Ubuntu Mainline Kernel %s packages...\n' "${version}"
dpkg -i "${packages[@]/#/${workdir}/}"

if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
	cat >&2 <<'EOF_SB'

WARNING: Secure Boot is enabled and mainline builds ship an unsigned kernel
image, so this kernel will not boot until Secure Boot is disabled in the UEFI
setup or the image is signed and enrolled with a MOK.
EOF_SB
fi

cat <<EOF_DONE

Installed Ubuntu Mainline Kernel ${version}.
Reboot and choose the new kernel if GRUB does not select it automatically, then check:
  uname -r
  ./check-um3405ga-sound.sh

If speakers are detected but quiet, run:
  sudo ./install-um3405ga-cs35l41-tuning.sh install
EOF_DONE
