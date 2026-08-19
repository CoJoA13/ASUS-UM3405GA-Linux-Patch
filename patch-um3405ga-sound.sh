#!/usr/bin/env bash
set -euo pipefail

# Local workaround for Linux kernels that predate upstream commit
# f61bc797ac00 ("ALSA: hda/realtek: Add CS35L41 I2C quirk for ASUS UM3405GA").
#
# The upstream fix adds 1043:19f4 with the same fixup as the already-present
# ASUS UM3406HA 1043:1c03 entry. Growing the quirk table in a compiled module is
# not practical, so this repoints that one subsystem ID in
# snd-hda-codec-alc269.ko.zst and rebuilds module metadata. The patched module
# therefore drives the UM3405GA instead of the UM3406HA.
#
# Kernels from Linux 7.2 onward carry the quirk already and are left untouched;
# prefer install-ubuntu-mainline-kernel.sh over this workaround.

old_id=$'\x43\x10\x03\x1c' # 1043:1c03, ASUS UM3406HA
new_id=$'\x43\x10\xf4\x19' # 1043:19f4, ASUS UM3405GA
# Linux 6.17 split the Realtek codec module out of snd-hda-codec-realtek; older
# kernels still use the old path, and distros compress modules differently.
module_relpaths=(
	'kernel/sound/hda/codecs/realtek/snd-hda-codec-alc269.ko'
	'kernel/sound/pci/hda/snd-hda-codec-realtek.ko'
)
modprobe_conf='/etc/modprobe.d/um3405ga-sound.conf'
softdep_line='softdep snd_hda_intel pre: snd_hda_codec_alc269 snd_hda_scodec_cs35l41_i2c'
rebind_src='./rebind-um3405ga-sound.sh'
rebind_dst='/usr/local/sbin/um3405ga-sound-rebind'
service_file='/etc/systemd/system/um3405ga-sound-rebind.service'

if [[ ${EUID} -ne 0 ]]; then
	printf 'Run this as root:\n  sudo %q\n' "$0" >&2
	exit 1
fi

for tool in perl depmod; do
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

find_module() {
	local kernel=$1
	local relpath suffix

	for relpath in "${module_relpaths[@]}"; do
		for suffix in .zst .xz .gz ''; do
			if [[ -f "/lib/modules/${kernel}/${relpath}${suffix}" ]]; then
				printf '%s\n' "/lib/modules/${kernel}/${relpath}${suffix}"
				return 0
			fi
		done
	done

	return 1
}

decompress_module() {
	local src=$1 dst=$2

	case "${src}" in
		*.zst) zstd -q -dc "${src}" >"${dst}" ;;
		*.xz) xz -dc "${src}" >"${dst}" ;;
		*.gz) gzip -dc "${src}" >"${dst}" ;;
		*) cp "${src}" "${dst}" ;;
	esac
}

compress_module() {
	local src=$1 dst=$2

	case "${dst}" in
		*.zst) zstd -q -19 -f "${src}" -o "${dst}" ;;
		*.xz) xz -c "${src}" >"${dst}" ;;
		*.gz) gzip -c "${src}" >"${dst}" ;;
		*) cp "${src}" "${dst}" ;;
	esac
}

patch_kernel() {
	local kernel=$1
	local module raw packed
	local tmpdir old_count new_count backup sig_state install_reason

	if ! module=$(find_module "${kernel}"); then
		printf 'Skipping %s: Realtek codec module not found\n' "$kernel"
		return 0
	fi

	tmpdir=$(mktemp -d)
	trap 'rm -rf "${tmpdir}"' RETURN
	raw="${tmpdir}/module.ko"
	packed="${tmpdir}/$(basename "${module}")"

	if ! decompress_module "${module}" "${raw}"; then
		printf 'Could not read %s\n' "${module}" >&2
		return 1
	fi

	old_count=$(count_bytes "$old_id" "${raw}")
	new_count=$(count_bytes "$new_id" "${raw}")
	install_reason=''

	if [[ "${new_count}" != "0" && "${old_count}" != "0" ]]; then
		# Both IDs present means this kernel ships the upstream quirk. Leave the
		# distro module (and its signature) alone.
		printf '%s: ships the upstream UM3405GA quirk; nothing to patch\n' "$kernel"
		return 0
	elif [[ "${new_count}" == "1" ]]; then
		printf '%s: UM3405GA quirk was already patched in\n' "$kernel"
		sig_state=$(strip_module_signature "${raw}")
		if [[ "${sig_state}" == "stripped" ]]; then
			install_reason='stripped stale module signature'
		fi
	elif [[ "${old_count}" == "1" ]]; then
		PATTERN_OLD="$old_id" PATTERN_NEW="$new_id" perl -0777 -pi -e '
			my $old = $ENV{"PATTERN_OLD"};
			my $new = $ENV{"PATTERN_NEW"};
			s/\Q$old\E/$new/g;
		' "${raw}"

		old_count=$(count_bytes "$old_id" "${raw}")
		new_count=$(count_bytes "$new_id" "${raw}")

		if [[ "${old_count}" != "0" || "${new_count}" != "1" ]]; then
			printf 'Patch verification failed for %s: old=%s new=%s\n' "$kernel" "$old_count" "$new_count" >&2
			return 1
		fi

		sig_state=$(strip_module_signature "${raw}")
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
	compress_module "${raw}" "${packed}"
	install -m 0644 "${packed}" "${module}"

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

	# No ConditionPathExists here: the codec is often not registered yet when the
	# unit starts, and a failed condition skips the unit outright instead of
	# letting it wait. The helper does the waiting itself.
	cat >"${service_file}" <<EOF
[Unit]
Description=Bind UM3405GA ALC294 codec to Realtek HDA driver
After=systemd-udev-settle.service systemd-modules-load.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=${rebind_dst} --wait
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
printf '  ./check-um3405ga-sound.sh\n'
printf '  systemctl status um3405ga-sound-rebind.service --no-pager\n'
