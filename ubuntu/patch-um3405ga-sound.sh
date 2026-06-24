#!/usr/bin/env bash
set -euo pipefail

# Local workaround for Linux kernels that predate upstream commit
# f61bc797ac00 ("ALSA: hda/realtek: Add CS35L41 I2C quirk for ASUS UM3405GA").
#
# The upstream fix adds 1043:19f4 with the same fixup as the already-present
# ASUS UM3406HA 1043:1c03 entry. For installed binary modules, replace that
# one subsystem ID in snd-hda-codec-alc269.ko.zst and rebuild module metadata.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
old_id=$'\x43\x10\x03\x1c' # 1043:1c03, ASUS UM3406HA
new_id=$'\x43\x10\xf4\x19' # 1043:19f4, ASUS UM3405GA
module_relpath='kernel/sound/hda/codecs/realtek/snd-hda-codec-alc269.ko.zst'
modprobe_conf='/etc/modprobe.d/um3405ga-sound.conf'
softdep_line='softdep snd_hda_intel pre: snd_hda_codec_alc269 snd_hda_scodec_cs35l41_i2c'
rebind_src="${repo_root}/shared/rebind-um3405ga-sound.sh"
rebind_dst='/usr/local/sbin/um3405ga-sound-rebind'
service_file='/etc/systemd/system/um3405ga-sound-rebind.service'

if [[ ${EUID} -ne 0 ]]; then
	printf 'Run this as root:\n  sudo %q\n' "$0" >&2
	exit 1
fi

for tool in perl zstd depmod; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf 'Missing required tool: %s\n' "$tool" >&2
		exit 1
	fi
done

count_bytes() {
	local pattern=$1
	local file=$2
	PATTERN="$pattern" perl -0777 -ne '
		my $pattern = $ENV{"PATTERN"};
		my $count = () = /\Q$pattern\E/g;
		print "$count\n";
	' "$file"
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
	' "$file"
}

refresh_kernel_metadata() {
	local kernel=$1

	depmod "$kernel"
	if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-${kernel}" ]]; then
		update-initramfs -u -k "$kernel"
	fi
}

patch_kernel() {
	local kernel=$1
	local module="/lib/modules/${kernel}/${module_relpath}"
	local tmpdir old_count new_count backup sig_state install_reason

	if [[ ! -f "${module}" ]]; then
		printf 'Skipping %s: module not found\n' "$kernel"
		return 0
	fi

	tmpdir=$(mktemp -d)
	trap 'rm -rf "${tmpdir}"' RETURN

	zstd -q -dc "${module}" >"${tmpdir}/snd-hda-codec-alc269.ko"

	old_count=$(count_bytes "$old_id" "${tmpdir}/snd-hda-codec-alc269.ko")
	new_count=$(count_bytes "$new_id" "${tmpdir}/snd-hda-codec-alc269.ko")
	install_reason=''

	if [[ "${new_count}" == "1" ]]; then
		printf '%s: UM3405GA quirk is already present\n' "$kernel"
		sig_state=$(strip_module_signature "${tmpdir}/snd-hda-codec-alc269.ko")
		if [[ "${sig_state}" == "stripped" ]]; then
			install_reason='stripped stale module signature'
		fi
	elif [[ "${old_count}" == "1" ]]; then
		PATTERN_OLD="$old_id" PATTERN_NEW="$new_id" perl -0777 -pi -e '
			my $old = $ENV{"PATTERN_OLD"};
			my $new = $ENV{"PATTERN_NEW"};
			s/\Q$old\E/$new/g;
		' "${tmpdir}/snd-hda-codec-alc269.ko"

		old_count=$(count_bytes "$old_id" "${tmpdir}/snd-hda-codec-alc269.ko")
		new_count=$(count_bytes "$new_id" "${tmpdir}/snd-hda-codec-alc269.ko")

		if [[ "${old_count}" != "0" || "${new_count}" != "1" ]]; then
			printf 'Patch verification failed for %s: old=%s new=%s\n' "$kernel" "$old_count" "$new_count" >&2
			return 1
		fi

		sig_state=$(strip_module_signature "${tmpdir}/snd-hda-codec-alc269.ko")
		if [[ "${sig_state}" == "stripped" ]]; then
			install_reason='patched quirk and stripped stale module signature'
		else
			install_reason='patched quirk'
		fi
	else
		printf 'Refusing to patch %s: expected one UM3406HA entry, found %s\n' "$kernel" "$old_count" >&2
		return 1
	fi

	if [[ -z "${install_reason}" ]]; then
		printf 'Skipping %s: no module changes needed\n' "$kernel"
		refresh_kernel_metadata "$kernel"
		return 0
	fi

	backup="${module}.bak-um3405ga-$(date +%Y%m%d%H%M%S)"
	cp -a "${module}" "${backup}"
	zstd -q -19 -f "${tmpdir}/snd-hda-codec-alc269.ko" -o "${tmpdir}/snd-hda-codec-alc269.ko.zst"
	install -m 0644 "${tmpdir}/snd-hda-codec-alc269.ko.zst" "${module}"

	refresh_kernel_metadata "$kernel"

	printf 'Updated %s: %s\n  backup: %s\n' "$kernel" "$install_reason" "$backup"
}

install_driver_ordering() {
	local initramfs_modules='/etc/initramfs-tools/modules'
	local changed_initramfs=0

	if [[ -f "${modprobe_conf}" ]] && grep -Fxq "${softdep_line}" "${modprobe_conf}"; then
		printf 'Driver ordering config already present: %s\n' "${modprobe_conf}"
	else
		cat >"${modprobe_conf}" <<EOF
# Ensure the Realtek codec driver is registered before snd_hda_intel probes
# the UM3405GA ALC294 codec. Otherwise snd_hda_codec_generic can claim it first.
${softdep_line}
EOF
		printf 'Installed driver ordering config: %s\n' "${modprobe_conf}"
	fi

	if [[ -f "${initramfs_modules}" ]]; then
		for module in snd_hda_codec_alc269 snd_hda_scodec_cs35l41_i2c; do
			if ! grep -Eq "^[[:space:]]*${module}([[:space:]]+|$)" "${initramfs_modules}"; then
				printf '%s\n' "${module}" >>"${initramfs_modules}"
				changed_initramfs=1
			fi
		done

		if [[ "${changed_initramfs}" == "1" ]]; then
			printf 'Added Realtek/Cirrus modules to %s\n' "${initramfs_modules}"
		else
			printf 'Initramfs module hints already present: %s\n' "${initramfs_modules}"
		fi
	fi
}

install_rebind_service() {
	if [[ ! -f "${rebind_src}" ]]; then
		printf 'Missing helper script: %s\n' "${rebind_src}" >&2
		return 1
	fi

	install -m 0755 "${rebind_src}" "${rebind_dst}"

	cat >"${service_file}" <<EOF
[Unit]
Description=Bind UM3405GA ALC294 codec to Realtek HDA driver
After=systemd-udev-settle.service systemd-modules-load.service
Wants=systemd-udev-settle.service
ConditionPathExists=/sys/bus/hdaudio/devices/hdaudioC1D0

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 50); do [ -e /sys/bus/hdaudio/devices/hdaudioC1D0 ] && exit 0; sleep 0.1; done; exit 1'
ExecStart=${rebind_dst}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable um3405ga-sound-rebind.service
	printf 'Installed and enabled rebind service: %s\n' "${service_file}"
}

if [[ $# -gt 0 ]]; then
	kernels=("$@")
else
	mapfile -t kernels < <(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V)
fi

install_driver_ordering
install_rebind_service

for kernel in "${kernels[@]}"; do
	patch_kernel "$kernel"
done

printf '\nDone. Reboot, then check:\n'
printf '  uname -r\n'
printf '  systemctl status um3405ga-sound-rebind.service --no-pager\n'
printf '  readlink -f /sys/bus/hdaudio/devices/hdaudioC1D0/driver\n'
printf '  journalctl -k -b | grep -Ei "UM3405|cs35l41|CSC3551|ALC294"\n'
printf '  modprobe snd_hda_codec_alc269\n'
printf '  speaker-test -Dhw:1,0 -c2 -t wav\n'
