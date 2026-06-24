#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
pkg_name='um3405ga-support'
build_root=${RPMBUILD_DIR:-${TMPDIR:-/tmp}/um3405ga-rpmbuild}
topdir="${build_root}/${pkg_name}"
out_dir="${repo_root}/dist"
rebind_src="${repo_root}/shared/rebind-um3405ga-sound.sh"

usage() {
	cat <<EOF
Usage:
  $0

Builds ${pkg_name}, a noarch RPM containing:
  /usr/lib/modprobe.d/um3405ga-sound.conf
  /usr/lib/systemd/system/um3405ga-sound-rebind.service
  /usr/libexec/um3405ga-sound-rebind
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

if [[ ! -f "${rebind_src}" ]]; then
	printf 'Missing rebind helper: %s\n' "${rebind_src}" >&2
	exit 1
fi

rm -rf "${topdir}"
mkdir -p "${topdir}/SOURCES" "${topdir}/SPECS" "${out_dir}"
install -m 0755 "${rebind_src}" "${topdir}/SOURCES/um3405ga-sound-rebind"

spec="${topdir}/SPECS/${pkg_name}.spec"
cat >"${spec}" <<'EOF_SPEC'
Name: um3405ga-support
Version: 1
Release: 1%{?dist}
Summary: UM3405GA HDA driver ordering and rebind support
License: MIT
BuildArch: noarch
Source0: um3405ga-sound-rebind

%description
Installs the modprobe soft dependency, rebind helper, and systemd unit used to
bind the ASUS UM3405GA Realtek ALC294 codec to snd_hda_codec_alc269.

%prep

%build

%install
mkdir -p %{buildroot}/usr/libexec
mkdir -p %{buildroot}/usr/lib/modprobe.d
mkdir -p %{buildroot}/usr/lib/systemd/system

install -m 0755 %{SOURCE0} %{buildroot}/usr/libexec/um3405ga-sound-rebind

cat >%{buildroot}/usr/lib/modprobe.d/um3405ga-sound.conf <<'EOF_CONF'
# Ensure the Realtek codec driver is registered before snd_hda_intel probes
# the UM3405GA ALC294 codec. Otherwise snd_hda_codec_generic can claim it first.
softdep snd_hda_intel pre: snd_hda_codec_alc269 snd_hda_scodec_cs35l41_i2c
EOF_CONF

cat >%{buildroot}/usr/lib/systemd/system/um3405ga-sound-rebind.service <<'EOF_SERVICE'
[Unit]
Description=Bind UM3405GA ALC294 codec to Realtek HDA driver
After=systemd-udev-settle.service systemd-modules-load.service
Wants=systemd-udev-settle.service
ConditionPathExists=/sys/bus/hdaudio/devices/hdaudioC1D0

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'for i in $(seq 1 50); do [ -e /sys/bus/hdaudio/devices/hdaudioC1D0 ] && exit 0; sleep 0.1; done; exit 1'
ExecStart=/usr/libexec/um3405ga-sound-rebind
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

%files
/usr/libexec/um3405ga-sound-rebind
/usr/lib/modprobe.d/um3405ga-sound.conf
/usr/lib/systemd/system/um3405ga-sound-rebind.service
EOF_SPEC

rpmbuild -bb --define "_topdir ${topdir}" "${spec}"
find "${topdir}/RPMS" -type f -name "${pkg_name}-*.rpm" -exec cp -v {} "${out_dir}/" \;

printf '\nBuilt RPM(s):\n'
find "${out_dir}" -maxdepth 1 -type f -name "${pkg_name}-*.rpm" -printf '  %p\n' | sort
