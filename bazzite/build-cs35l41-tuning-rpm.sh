#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
pkg_name='um3405ga-cs35l41-tuning'
build_root=${RPMBUILD_DIR:-${TMPDIR:-/tmp}/um3405ga-rpmbuild}
topdir="${build_root}/${pkg_name}"
out_dir="${repo_root}/dist"
donor_ssid=${DONOR_SSID:-10431c03}
donor_spkid=${DONOR_SPKID:-0}
target_ssid=${TARGET_SSID:-104319f4}
target_spkid=${TARGET_SPKID:-1}

if [[ -n "${FIRMWARE_DIR:-}" ]]; then
	firmware_dir=${FIRMWARE_DIR}
elif [[ -d /usr/lib/firmware/cirrus ]]; then
	firmware_dir=/usr/lib/firmware/cirrus
else
	firmware_dir=/lib/firmware/cirrus
fi

usage() {
	cat <<EOF
Usage:
  $0

Environment overrides:
  FIRMWARE_DIR=${firmware_dir}
  DONOR_SSID=${donor_ssid}
  DONOR_SPKID=${donor_spkid}
  TARGET_SSID=${target_ssid}
  TARGET_SPKID=${target_spkid}
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi

for tool in rpmbuild install; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		printf 'Missing required tool: %s\n' "${tool}" >&2
		printf 'On Bazzite, install build tooling with:\n  sudo rpm-ostree install rpm-build\n  sudo reboot\n' >&2
		exit 1
	fi
done

coeff_file() {
	local ssid=$1
	local spkid=$2
	local amp=$3

	printf '%s/cs35l41-dsp1-spk-prot-%s-spkid%s-%s.bin.zst\n' \
		"${firmware_dir}" "${ssid}" "${spkid}" "${amp}"
}

wmfw_source="${firmware_dir}/cs35l41-dsp1-spk-prot.wmfw.zst"
coeff_l0=$(coeff_file "${donor_ssid}" "${donor_spkid}" l0)
coeff_r0=$(coeff_file "${donor_ssid}" "${donor_spkid}" r0)

for source in "${wmfw_source}" "${coeff_l0}" "${coeff_r0}"; do
	if [[ ! -f "${source}" ]]; then
		printf 'Missing firmware source: %s\n' "${source}" >&2
		printf 'Install/update linux-firmware, or set FIRMWARE_DIR to a directory containing the Cirrus firmware.\n' >&2
		exit 1
	fi
done

rm -rf "${topdir}"
mkdir -p "${topdir}/SOURCES" "${topdir}/SPECS" "${out_dir}"
install -m 0644 "${wmfw_source}" "${topdir}/SOURCES/cs35l41-dsp1-spk-prot.wmfw.zst"
install -m 0644 "${coeff_l0}" "${topdir}/SOURCES/cs35l41-dsp1-spk-prot-${donor_ssid}-spkid${donor_spkid}-l0.bin.zst"
install -m 0644 "${coeff_r0}" "${topdir}/SOURCES/cs35l41-dsp1-spk-prot-${donor_ssid}-spkid${donor_spkid}-r0.bin.zst"

spec="${topdir}/SPECS/${pkg_name}.spec"
cat >"${spec}" <<EOF_SPEC
Name: ${pkg_name}
Version: 1
Release: 1%{?dist}
Summary: UM3405GA CS35L41 speaker tuning aliases
License: MIT
BuildArch: noarch
Source0: cs35l41-dsp1-spk-prot.wmfw.zst
Source1: cs35l41-dsp1-spk-prot-${donor_ssid}-spkid${donor_spkid}-l0.bin.zst
Source2: cs35l41-dsp1-spk-prot-${donor_ssid}-spkid${donor_spkid}-r0.bin.zst

%description
Installs firmware aliases requested by the ASUS UM3405GA CS35L41 HDA driver
path. The package aliases the generic CS35L41 WMFW and the related ASUS
UM3406HA coefficient files to target ${target_ssid}-spkid${target_spkid}.

%prep

%build

%install
mkdir -p %{buildroot}/usr/lib/firmware/cirrus
install -m 0644 %{SOURCE0} %{buildroot}/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-l0.wmfw.zst
install -m 0644 %{SOURCE0} %{buildroot}/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-r0.wmfw.zst
install -m 0644 %{SOURCE1} %{buildroot}/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-l0.bin.zst
install -m 0644 %{SOURCE2} %{buildroot}/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-r0.bin.zst

%files
/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-l0.wmfw.zst
/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-r0.wmfw.zst
/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-l0.bin.zst
/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-${target_ssid}-spkid${target_spkid}-r0.bin.zst
EOF_SPEC

rpmbuild -bb --define "_topdir ${topdir}" "${spec}"
find "${topdir}/RPMS" -type f -name "${pkg_name}-*.rpm" -exec cp -v {} "${out_dir}/" \;

printf '\nBuilt RPM(s):\n'
find "${out_dir}" -maxdepth 1 -type f -name "${pkg_name}-*.rpm" -printf '  %p\n' | sort
