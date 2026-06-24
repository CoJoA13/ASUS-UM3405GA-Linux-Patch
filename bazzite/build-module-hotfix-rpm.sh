#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
pkg_name='um3405ga-snd-hda-alc269-hotfix'
kernel=${1:-$(uname -r)}
module_relpath='kernel/sound/hda/codecs/realtek/snd-hda-codec-alc269.ko.zst'
module="/usr/lib/modules/${kernel}/${module_relpath}"
out_dir="${repo_root}/dist"
safe_kernel=${kernel//[^A-Za-z0-9_.]/_}
build_root=${RPMBUILD_DIR:-${TMPDIR:-/tmp}/um3405ga-rpmbuild}
topdir="${build_root}/${pkg_name}-${safe_kernel}"
old_id=$'\x43\x10\x03\x1c' # 1043:1c03, ASUS UM3406HA
new_id=$'\x43\x10\xf4\x19' # 1043:19f4, ASUS UM3405GA

usage() {
	cat <<EOF
Usage:
  $0 [kernel-release]

Builds a local RPM replacing:
  /usr/lib/modules/<kernel-release>/${module_relpath}

The RPM is only needed when the booted kernel lacks the UM3405GA quirk.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi

for tool in perl zstd rpmbuild install; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		printf 'Missing required tool: %s\n' "${tool}" >&2
		printf 'On Bazzite, install build tooling with:\n  sudo rpm-ostree install rpm-build\n  sudo reboot\n' >&2
		exit 1
	fi
done

if [[ ! -f "${module}" && -f "/lib/modules/${kernel}/${module_relpath}" ]]; then
	module="/lib/modules/${kernel}/${module_relpath}"
fi

if [[ ! -f "${module}" ]]; then
	printf 'Missing module for kernel %s:\n  %s\n' "${kernel}" "${module}" >&2
	exit 1
fi

count_bytes() {
	local pattern=$1
	local file=$2
	PATTERN="${pattern}" perl -0777 -ne '
		my $pattern = $ENV{"PATTERN"};
		my $count = () = /\Q$pattern\E/g;
		print "$count\n";
	' "${file}"
}

strip_module_signature() {
	local file=$1

	perl -0777 -e '
		use strict;
		use warnings;
		use bytes;

		my $file = shift @ARGV;
		my $magic = "~Module signature appended~\n";
		open my $fh, "+<:raw", $file or die "open $file: $!\n";
		local $/;
		my $data = <$fh>;

		my $magic_pos = rindex($data, $magic);
		if ($magic_pos < 0) {
			print "absent\n";
			exit 0;
		}

		my $sig_info_len = 12;
		my $sig_info_pos = $magic_pos - $sig_info_len;
		die "bad module signature layout\n" if $sig_info_pos < 0;

		my $sig_len = unpack("N", substr($data, $sig_info_pos + 8, 4));
		my $truncate_pos = $sig_info_pos - $sig_len;
		die "bad module signature length\n" if $truncate_pos <= 0 || $truncate_pos > length($data);

		truncate($fh, $truncate_pos) or die "truncate $file: $!\n";
		print "stripped\n";
	' "${file}"
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/um3405ga-module-hotfix.XXXXXX")
trap 'rm -rf "${tmpdir}"' EXIT

zstd -q -dc "${module}" >"${tmpdir}/snd-hda-codec-alc269.ko"

old_count=$(count_bytes "${old_id}" "${tmpdir}/snd-hda-codec-alc269.ko")
new_count=$(count_bytes "${new_id}" "${tmpdir}/snd-hda-codec-alc269.ko")

if [[ "${new_count}" == "1" ]]; then
	printf 'Kernel %s already contains the UM3405GA quirk; no module hotfix RPM is needed.\n' "${kernel}"
	exit 0
fi

if [[ "${old_count}" != "1" ]]; then
	printf 'Refusing to patch %s: expected one UM3406HA entry, found %s\n' "${kernel}" "${old_count}" >&2
	exit 1
fi

PATTERN_OLD="${old_id}" PATTERN_NEW="${new_id}" perl -0777 -pi -e '
	my $old = $ENV{"PATTERN_OLD"};
	my $new = $ENV{"PATTERN_NEW"};
	s/\Q$old\E/$new/g;
' "${tmpdir}/snd-hda-codec-alc269.ko"

old_count=$(count_bytes "${old_id}" "${tmpdir}/snd-hda-codec-alc269.ko")
new_count=$(count_bytes "${new_id}" "${tmpdir}/snd-hda-codec-alc269.ko")

if [[ "${old_count}" != "0" || "${new_count}" != "1" ]]; then
	printf 'Patch verification failed for %s: old=%s new=%s\n' "${kernel}" "${old_count}" "${new_count}" >&2
	exit 1
fi

sig_state=$(strip_module_signature "${tmpdir}/snd-hda-codec-alc269.ko")
zstd -q -19 -f "${tmpdir}/snd-hda-codec-alc269.ko" -o "${tmpdir}/snd-hda-codec-alc269.ko.zst"

rm -rf "${topdir}"
mkdir -p "${topdir}/SOURCES" "${topdir}/SPECS" "${out_dir}"
install -m 0644 "${tmpdir}/snd-hda-codec-alc269.ko.zst" "${topdir}/SOURCES/snd-hda-codec-alc269.ko.zst"

spec="${topdir}/SPECS/${pkg_name}.spec"
cat >"${spec}" <<EOF_SPEC
Name: ${pkg_name}
Version: 1
Release: 1.${safe_kernel}%{?dist}
Summary: UM3405GA snd-hda-codec-alc269 module hotfix for ${kernel}
License: MIT

Source0: snd-hda-codec-alc269.ko.zst

%description
Replaces the Bazzite kernel module snd-hda-codec-alc269.ko.zst for kernel
${kernel} with a local hotfix that changes ASUS subsystem ID 1043:1c03 to
1043:19f4. This is temporary until the shipped kernel contains upstream commit
f61bc797ac0075dbaac5e44238674858e9dbe399.

%prep

%build

%install
mkdir -p %{buildroot}/usr/lib/modules/${kernel}/kernel/sound/hda/codecs/realtek
install -m 0644 %{SOURCE0} %{buildroot}/usr/lib/modules/${kernel}/${module_relpath}

%files
/usr/lib/modules/${kernel}/${module_relpath}
EOF_SPEC

rpmbuild -bb --define "_topdir ${topdir}" "${spec}"
find "${topdir}/RPMS" -type f -name "${pkg_name}-*.rpm" -exec cp -v {} "${out_dir}/" \;

printf '\nPatched kernel: %s\n' "${kernel}"
printf 'Module signature state before recompressing: %s\n' "${sig_state}"
printf 'Built RPM(s):\n'
find "${out_dir}" -maxdepth 1 -type f -name "${pkg_name}-*.rpm" -printf '  %p\n' | sort
