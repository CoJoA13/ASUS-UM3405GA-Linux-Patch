#!/usr/bin/env bash
set -uo pipefail

# Read-only report on the UM3405GA audio stack: which kernel is running, whether
# its Realtek quirk table knows this machine, which driver claimed the codec,
# and what the CS35L41 amps loaded. Nothing here changes the system.

target_ssid=${TARGET_SSID:-104319f4}
donor_ssid=${DONOR_SSID:-10431c03}
firmware_dir=${FIRMWARE_DIR:-/lib/firmware/cirrus}
modules_dir=${MODULES_DIR:-/lib/modules}
quirk_major=7
quirk_minor=2

kernel=$(uname -r)
problems=0
notes=()

section() {
	printf '\n== %s ==\n' "$1"
}

note() {
	notes+=("$1")
	problems=$((problems + 1))
}

# 1043:19f4 and 1043:1c03 as stored little-endian in struct snd_pci_quirk.
scan_module_for_quirk() {
	local module=$1
	local pattern=$2
	local tmp raw count

	tmp=$(mktemp -d) || return 2
	raw="${tmp}/module.ko"

	case "${module}" in
		*.zst) zstd -q -dc "${module}" >"${raw}" 2>/dev/null || { rm -rf "${tmp}"; return 2; } ;;
		*.xz) xz -dc "${module}" >"${raw}" 2>/dev/null || { rm -rf "${tmp}"; return 2; } ;;
		*.gz) gzip -dc "${module}" >"${raw}" 2>/dev/null || { rm -rf "${tmp}"; return 2; } ;;
		*) raw="${module}" ;;
	esac

	count=$(PATTERN="${pattern}" perl -0777 -ne '
		my $p = $ENV{"PATTERN"};
		$p =~ s/\\x([0-9a-fA-F]{2})/chr(hex($1))/ge;
		my $c = () = /\Q$p\E/g;
		print "$c\n";
	' "${raw}" 2>/dev/null)

	rm -rf "${tmp}"
	[[ -n "${count}" ]] || return 2
	printf '%s\n' "${count}"
}

printf 'UM3405GA sound check\n'
printf 'Kernel: %s\n' "${kernel}"

section 'Realtek quirk table'
kernel_major=${kernel%%.*}
kernel_minor=${kernel#*.}
kernel_minor=${kernel_minor%%[.-]*}
if [[ ${kernel_major} =~ ^[0-9]+$ && ${kernel_minor} =~ ^[0-9]+$ ]] &&
	{ ((kernel_major > quirk_major)) ||
		((kernel_major == quirk_major && kernel_minor >= quirk_minor)); }; then
	printf 'Kernel version carries the upstream quirk (Linux %s.%s or newer).\n' \
		"${quirk_major}" "${quirk_minor}"
else
	printf 'Kernel version predates the upstream quirk (added in Linux %s.%s-rc1).\n' \
		"${quirk_major}" "${quirk_minor}"
fi

module=''
for candidate in \
	"${modules_dir}/${kernel}/kernel/sound/hda/codecs/realtek/snd-hda-codec-alc269.ko" \
	"${modules_dir}/${kernel}/kernel/sound/pci/hda/snd-hda-codec-realtek.ko"; do
	for suffix in .zst .xz .gz ''; do
		if [[ -f "${candidate}${suffix}" ]]; then
			module="${candidate}${suffix}"
			break 2
		fi
	done
done

if [[ -z "${module}" ]]; then
	printf 'Could not find the Realtek HDA codec module for %s.\n' "${kernel}"
	note "Realtek codec module missing for ${kernel}"
elif ! command -v perl >/dev/null 2>&1; then
	printf 'perl not available; skipping the quirk table scan.\n'
else
	printf 'Module: %s\n' "${module}"
	um3405=$(scan_module_for_quirk "${module}" '\x43\x10\xf4\x19')
	um3406=$(scan_module_for_quirk "${module}" '\x43\x10\x03\x1c')
	if [[ -z "${um3405}" ]]; then
		printf 'Could not read the quirk table (missing decompressor?).\n'
	elif [[ "${um3405}" != "0" ]]; then
		printf 'UM3405GA quirk 1043:19f4: PRESENT\n'
	else
		printf 'UM3405GA quirk 1043:19f4: MISSING (UM3406HA 1043:1c03 entries: %s)\n' "${um3406:-?}"
		note 'Running kernel has no 1043:19f4 quirk; install a 7.2 kernel or run patch-um3405ga-sound.sh'
	fi
fi

section 'HDA codecs'
found_codec=0
for dev in /sys/bus/hdaudio/devices/*; do
	[[ -e "${dev}/chip_name" ]] || continue
	found_codec=1
	chip=$(cat "${dev}/chip_name" 2>/dev/null)
	subsystem=$(cat "${dev}/subsystem_id" 2>/dev/null)
	driver=$(readlink -f "${dev}/driver" 2>/dev/null)
	printf '%s: %s subsystem=%s driver=%s\n' \
		"$(basename "${dev}")" "${chip:-?}" "${subsystem:-?}" "${driver##*/}"

	case "${chip}" in
		*ALC294*)
			case "${subsystem}" in
				*"${target_ssid}"*) ;;
				*)
					note "ALC294 reports subsystem ${subsystem}, not 0x${target_ssid}; the quirk and firmware IDs in these scripts will not match this machine"
					;;
			esac
			case "${driver}" in
				*snd_hda_codec_generic*)
					note 'ALC294 is bound to snd_hda_codec_generic; run rebind-um3405ga-sound.sh'
					;;
			esac
			;;
	esac
done

if [[ "${found_codec}" == "0" ]]; then
	printf 'No HDA codec devices found under /sys/bus/hdaudio/devices.\n'
	for codec in /proc/asound/card*/codec#*; do
		[[ -e "${codec}" ]] || continue
		printf '%s: %s / %s\n' "${codec}" \
			"$(sed -n 's/^Codec: //p' "${codec}" | head -1)" \
			"$(sed -n 's/^Subsystem Id: //p' "${codec}" | head -1)"
	done
fi

section 'CS35L41 amplifiers'
if journalctl -k -b --no-pager >/dev/null 2>&1; then
	bound=$(journalctl -k -b --no-pager 2>/dev/null | grep -F 'CS35L41 Bound' | tail -4)
	if [[ -n "${bound}" ]]; then
		printf '%s\n' "${bound}" | sed 's/^.*cs35l41-hda/cs35l41-hda/'
	else
		printf 'No "CS35L41 Bound" lines in this boot; the amps never bound.\n'
		note 'CS35L41 amps did not bind this boot'
	fi

	if journalctl -k -b --no-pager 2>/dev/null | grep -qF 'Falling back to default firmware'; then
		printf 'DSP firmware: generic fallback in use (speakers will be quiet).\n'
		note 'CS35L41 fell back to generic firmware; run install-um3405ga-cs35l41-tuning.sh install'
	elif journalctl -k -b --no-pager 2>/dev/null | grep -qF 'Firmware Loaded'; then
		printf 'DSP firmware: board tuning loaded.\n'
	fi
else
	printf 'Kernel log not readable; re-run as root for amplifier details.\n'
fi

section 'CS35L41 firmware files'
if [[ -d "${firmware_dir}" ]]; then
	for ssid in "${target_ssid}" "${donor_ssid}"; do
		mapfile -t matches < <(find "${firmware_dir}" -maxdepth 1 \
			-name "cs35l41-dsp1-spk-prot-${ssid}*" -printf '%f\n' 2>/dev/null | sort)
		if [[ ${#matches[@]} -gt 0 ]]; then
			printf '%s:\n' "${ssid}"
			printf '  %s\n' "${matches[@]}"
		else
			printf '%s: none installed\n' "${ssid}"
		fi
	done
else
	printf 'Missing firmware directory: %s\n' "${firmware_dir}"
fi

section 'Summary'
if [[ "${problems}" == "0" ]]; then
	printf 'No problems detected.\n'
else
	printf '%s issue(s):\n' "${problems}"
	printf '  - %s\n' "${notes[@]}"
fi
