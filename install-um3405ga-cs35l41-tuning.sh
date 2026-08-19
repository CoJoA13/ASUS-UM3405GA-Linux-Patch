#!/usr/bin/env bash
set -euo pipefail

# Install CS35L41 speaker-protection firmware aliases for the ASUS UM3405GA by
# reusing the generic WMFW plus the closely related UM3406HA tuning coefficients
# shipped by linux-firmware.
#
# The codec quirk makes the amps bind, but linux-firmware ships no UM3405GA
# (104319f4) coefficient files. The CS35L41 HDA driver only requests
# board-specific .bin coefficients after a board-specific .wmfw matches, so both
# filenames have to exist before the borrowed tuning is used. linux-firmware
# ships one real WMFW under several names, so either the generic
# cs35l41-dsp1-spk-prot.wmfw or the donor's own is what gets aliased.
#
# Which names the driver asks for depends on the speaker-ID GPIO it reads at
# probe time, so the requested IDs are taken from the kernel log when possible.

firmware_dir=${FIRMWARE_DIR:-/lib/firmware/cirrus}
donor_ssid=${DONOR_SSID:-10431c03}
target_ssid=${TARGET_SSID:-}
target_spkid=${TARGET_SPKID:-}
donor_spkid=${DONOR_SPKID:-}
fallback_ssid=104319f4
reload=${RELOAD:-0}
amps=(l0 r0)
stamp=$(date +%Y%m%d%H%M%S)

usage() {
	cat <<EOF
Usage:
  sudo $0 install
  sudo $0 restore

Environment overrides:
  FIRMWARE_DIR=${firmware_dir}
  DONOR_SSID=${donor_ssid}
  DONOR_SPKID=<n>        (default: the donor file matching the target speaker ID)
  TARGET_SSID=<hex>      (default: read from the kernel log, else ${fallback_ssid})
  TARGET_SPKID=<n|none>  (default: read from the kernel log, else every variant)
  RELOAD=1               (reload the DSP live instead of asking for a reboot)
  CARD=<alsa card number>
EOF
}

action=${1:-install}
case "${action}" in
	install|restore) ;;
	--help|-h)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
esac

if [[ ${EUID} -ne 0 ]]; then
	printf 'Run this as root:\n  sudo %q %s\n' "$0" "${action}" >&2
	exit 1
fi

if [[ ! -d "${firmware_dir}" ]]; then
	printf 'Missing firmware directory: %s\n' "${firmware_dir}" >&2
	exit 1
fi

# The driver logs "CS35L41 Bound - SSID: 104319f4, ..., SPKID: 1" for each amp.
# A negative SPKID means the machine has no speaker-ID GPIO, in which case the
# requested filenames carry no spkid component at all.
bound_line() {
	journalctl -k -b --no-pager 2>/dev/null | grep -F 'CS35L41 Bound' | tail -n 1
}

detect_ids() {
	local line ssid spkid

	line=$(bound_line) || return 1
	[[ -n "${line}" ]] || return 1

	ssid=$(printf '%s\n' "${line}" | sed -n 's/.*SSID: \([0-9a-fA-F]\{1,\}\).*/\1/p')
	spkid=$(printf '%s\n' "${line}" | sed -n 's/.*SPKID: \(-\{0,1\}[0-9]\{1,\}\).*/\1/p')
	[[ -n "${ssid}" && -n "${spkid}" ]] || return 1

	if ((spkid < 0)); then
		spkid=none
	fi

	printf '%s %s\n' "${ssid}" "${spkid}"
}

# Firmware may be shipped uncompressed or compressed; the loader tries each
# suffix, so an alias has to keep the suffix its donor file uses.
resolve_file() {
	local base=$1
	local suffix

	for suffix in .zst .xz ''; do
		if [[ -f "${base}${suffix}" ]]; then
			printf '%s\n' "${base}${suffix}"
			return 0
		fi
	done

	return 1
}

base_name() {
	local ssid=$1 spkid=$2 amp=$3 kind=$4

	if [[ "${spkid}" == "none" ]]; then
		printf '%s/cs35l41-dsp1-spk-prot-%s-%s.%s\n' "${firmware_dir}" "${ssid}" "${amp}" "${kind}"
	else
		printf '%s/cs35l41-dsp1-spk-prot-%s-spkid%s-%s.%s\n' \
			"${firmware_dir}" "${ssid}" "${spkid}" "${amp}" "${kind}"
	fi
}

donor_spkids() {
	find "${firmware_dir}" -maxdepth 1 -name "cs35l41-dsp1-spk-prot-${donor_ssid}-spkid*-${amps[0]}.bin*" \
		-printf '%f\n' 2>/dev/null |
		sed -n 's/.*-spkid\([0-9]\{1,\}\)-.*/\1/p' |
		sort -un
}

pick_donor_spkid() {
	local wanted=$1
	local -a available=()

	mapfile -t available < <(donor_spkids)
	if [[ ${#available[@]} -eq 0 ]]; then
		return 1
	fi

	if [[ -n "${donor_spkid}" ]]; then
		printf '%s\n' "${donor_spkid}"
		return 0
	fi

	local candidate
	for candidate in "${available[@]}"; do
		if [[ "${candidate}" == "${wanted}" ]]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done

	printf '%s\n' "${available[0]}"
}

install_alias() {
	local src=$1 dst=$2 label=$3
	local backup

	if [[ -e "${dst}" ]] && ! cmp -s "${src}" "${dst}"; then
		backup="${dst}.bak-um3405ga-${stamp}"
		cp -a "${dst}" "${backup}"
		printf 'Backed up existing %s:\n  %s\n' "${label}" "${backup}"
	fi

	install -m 0644 "${src}" "${dst}"
	printf 'Installed %s:\n  %s -> %s\n' "${label}" "${src}" "${dst}"
}

# An alias whose name differs only in case cannot be requested by anything, so
# it is dead weight that also makes the firmware listing look installed. These
# are files this script created, and they are renamed rather than deleted.
disable_wrong_case() {
	local file base prefix="cs35l41-dsp1-spk-prot-${target_ssid}"

	while read -r file; do
		base=${file##*/}
		[[ "${base:0:${#prefix}}" == "${prefix}" ]] && continue
		mv "${file}" "${file}.disabled-um3405ga-${stamp}"
		printf 'Disabled an alias the driver can never request (wrong case):\n  %s\n' "${file}"
	done < <(find "${firmware_dir}" -maxdepth 1 \
		-iname "${prefix}-*" \
		! -name '*.bak-um3405ga-*' ! -name '*.disabled-um3405ga-*' | sort)
}

install_variant() {
	local spkid=$1
	local amp donor coeff_src wmfw_src coeff_dst wmfw_dst suffix

	donor=$(pick_donor_spkid "${spkid}") || {
		printf 'No %s coefficient files found in %s\n' "${donor_ssid}" "${firmware_dir}" >&2
		exit 1
	}

	# linux-firmware ships one real WMFW and gives it a name per board, so a
	# release may carry cs35l41-dsp1-spk-prot-<ssid>.wmfw without the bare
	# generic name. The donor's own WMFW is that same firmware, so take it when
	# the generic name is absent rather than refusing to install at all.
	wmfw_src=$(resolve_file "${firmware_dir}/cs35l41-dsp1-spk-prot.wmfw") ||
		wmfw_src=$(resolve_file "${firmware_dir}/cs35l41-dsp1-spk-prot-${donor_ssid}.wmfw") || {
		printf 'No WMFW to alias: neither %s/cs35l41-dsp1-spk-prot.wmfw nor the %s variant exists.\n' \
			"${firmware_dir}" "${donor_ssid}" >&2
		printf 'Install the linux-firmware package that ships cirrus/cs35l41-dsp1-spk-prot*.wmfw.\n' >&2
		exit 1
	}

	for amp in "${amps[@]}"; do
		coeff_src=$(resolve_file "$(base_name "${donor_ssid}" "${donor}" "${amp}" bin)") || {
			printf 'Missing donor coefficients for %s spkid%s:\n  %s\n' \
				"${amp}" "${donor}" "$(base_name "${donor_ssid}" "${donor}" "${amp}" bin)" >&2
			exit 1
		}

		suffix=${coeff_src##*.bin}
		coeff_dst="$(base_name "${target_ssid}" "${spkid}" "${amp}" bin)${suffix}"
		suffix=${wmfw_src##*.wmfw}
		wmfw_dst="$(base_name "${target_ssid}" "${spkid}" "${amp}" wmfw)${suffix}"

		install_alias "${wmfw_src}" "${wmfw_dst}" "${amp} WMFW alias"
		install_alias "${coeff_src}" "${coeff_dst}" "${amp} coefficient alias (donor spkid${donor})"
	done
}

restore_target() {
	local file disabled found=0

	while read -r file; do
		[[ -n "${file}" ]] || continue
		found=1
		disabled="${file}.disabled-um3405ga-${stamp}"
		mv "${file}" "${disabled}"
		printf 'Disabled:\n  %s\n' "${disabled}"
	done < <(find "${firmware_dir}" -maxdepth 1 \
		-iname "cs35l41-dsp1-spk-prot-${target_ssid}-*" \
		! -name '*.bak-um3405ga-*' ! -name '*.disabled-um3405ga-*' | sort)

	if [[ "${found}" == "0" ]]; then
		printf 'No %s firmware aliases to disable in %s\n' "${target_ssid}" "${firmware_dir}"
	fi
}

find_alc294_card() {
	local codec card

	if [[ -n "${CARD:-}" ]]; then
		printf '%s\n' "${CARD}"
		return 0
	fi

	for codec in /proc/asound/card*/codec#*; do
		[[ -e "${codec}" ]] || continue
		if grep -q '^Codec: Realtek ALC294$' "${codec}" &&
			grep -qi "^Subsystem Id: 0x${target_ssid}\$" "${codec}"; then
			card=${codec#/proc/asound/card}
			card=${card%%/*}
			printf '%s\n' "${card}"
			return 0
		fi
	done

	return 1
}

reload_firmware() {
	local card=$1
	local ctrl failed=0
	local controls=(
		'L0 DSP1 Firmware Load'
		'R0 DSP1 Firmware Load'
	)

	if ! command -v amixer >/dev/null 2>&1; then
		printf 'amixer not found; reboot to load the new tuning.\n'
		return 0
	fi

	printf 'Reloading CS35L41 DSP firmware on ALSA card %s...\n' "${card}"
	for ctrl in "${controls[@]}"; do
		if ! amixer -q -c "${card}" cset "iface=CARD,name=${ctrl}" off; then
			failed=1
		fi
	done

	sleep 1

	for ctrl in "${controls[@]}"; do
		if ! amixer -q -c "${card}" cset "iface=CARD,name=${ctrl}" on; then
			failed=1
		fi
	done

	if [[ "${failed}" == "1" ]]; then
		printf 'Live DSP reload did not fully complete. Reboot before testing speaker volume.\n' >&2
		return 1
	fi
}

detected=''
if [[ -z "${target_ssid}" || -z "${target_spkid}" ]]; then
	detected=$(detect_ids || true)
fi

if [[ -n "${detected}" ]]; then
	read -r detected_ssid detected_spkid <<<"${detected}"
	target_ssid=${target_ssid:-${detected_ssid}}
	target_spkid=${target_spkid:-${detected_spkid}}
	printf 'Kernel log reports SSID %s, speaker ID %s.\n' "${detected_ssid}" "${detected_spkid}"
else
	target_ssid=${target_ssid:-${fallback_ssid}}
fi

# cs35l41_request_firmware_file() lowercases the whole filename before asking
# for it, but the kernel log prints the SSID upper case ("SSID: 104319F4").
# Passing the logged spelling through installs 104319F4 aliases that nothing
# will ever request: the files are present, the driver still falls back to the
# generic firmware, and the speaker stays quiet with no error anywhere.
target_ssid=${target_ssid,,}
donor_ssid=${donor_ssid,,}

declare -a variants=()
if [[ -n "${target_spkid}" ]]; then
	variants=("${target_spkid}")
else
	# Without a reading from the driver, cover every name it could ask for.
	mapfile -t variants < <(donor_spkids)
	variants+=(none)
	printf 'Could not read the speaker ID from the kernel log; installing every variant (%s).\n' \
		"${variants[*]}"
fi

case "${action}" in
	install)
		disable_wrong_case
		for variant in "${variants[@]}"; do
			install_variant "${variant}"
		done
		;;
	restore)
		restore_target
		;;
esac

# Toggling DSP firmware load at runtime pokes the amps over I2C while the audio
# stack is live. A reboot applies the same files with none of that risk, so the
# live reload is opt-in.
if [[ "${reload}" == "1" ]]; then
	if card=$(find_alc294_card); then
		reload_firmware "${card}" || true
	else
		printf 'Could not auto-detect the UM3405GA ALC294 ALSA card; reboot to load the tuning.\n'
	fi
else
	printf '\nReboot to load the tuning (or re-run with RELOAD=1 to reload the DSP now).\n'
fi

printf '\nStart at a low volume, then check the CS35L41 firmware log with:\n'
printf '  journalctl -k -b --no-pager | grep -Ei %q\n' "${target_ssid}|${donor_ssid}|falling back|Firmware Loaded|cs35l41"
