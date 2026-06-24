#!/usr/bin/env bash
set -euo pipefail

# Install CS35L41 speaker-protection firmware aliases for the ASUS UM3405GA by
# reusing the generic WMFW plus the closely related UM3406HA tuning coefficients
# shipped by linux-firmware.
#
# The codec quirk makes the amps bind, but current firmware packages do not
# ship UM3405GA-specific 104319f4 coefficient files. The 7.0 CS35L41 HDA driver
# only requests board-specific .bin coefficients after it finds a matching
# board-specific .wmfw, so create both filenames the driver will request and let
# the firmware loader use the existing compressed .zst blobs.

firmware_dir=${FIRMWARE_DIR:-/lib/firmware/cirrus}
donor_ssid=${DONOR_SSID:-10431c03}
donor_spkid=${DONOR_SPKID:-0}
target_ssid=${TARGET_SSID:-104319f4}
target_spkid=${TARGET_SPKID:-1}
stamp=$(date +%Y%m%d%H%M%S)

usage() {
	cat <<EOF
Usage:
  sudo $0 install
  sudo $0 restore

Environment overrides:
  FIRMWARE_DIR=${firmware_dir}
  DONOR_SSID=${donor_ssid}
  DONOR_SPKID=${donor_spkid}
  TARGET_SSID=${target_ssid}
  TARGET_SPKID=${target_spkid}
  CARD=<alsa card number>
EOF
}

action=${1:-install}
case "${action}" in
	install|restore|--help|-h) ;;
	*)
		usage >&2
		exit 2
		;;
esac

if [[ "${action}" == "--help" || "${action}" == "-h" ]]; then
	usage
	exit 0
fi

if [[ ${EUID} -ne 0 ]]; then
	printf 'Run this as root:\n  sudo %q install\n' "$0" >&2
	exit 1
fi

coeff_file() {
	local ssid=$1
	local spkid=$2
	local amp=$3

	printf '%s/cs35l41-dsp1-spk-prot-%s-spkid%s-%s.bin.zst\n' \
		"${firmware_dir}" "${ssid}" "${spkid}" "${amp}"
}

wmfw_file() {
	local ssid=$1
	local spkid=$2
	local amp=$3

	printf '%s/cs35l41-dsp1-spk-prot-%s-spkid%s-%s.wmfw.zst\n' \
		"${firmware_dir}" "${ssid}" "${spkid}" "${amp}"
}

install_alias() {
	local src=$1
	local dst=$2
	local label=$3
	local backup

	if [[ ! -f "${src}" ]]; then
		printf 'Missing source for %s:\n  %s\n' "${label}" "${src}" >&2
		exit 1
	fi

	if [[ -e "${dst}" ]] && ! cmp -s "${src}" "${dst}"; then
		backup="${dst}.bak-um3405ga-${stamp}"
		cp -a "${dst}" "${backup}"
		printf 'Backed up existing %s:\n  %s\n' "${label}" "${backup}"
	fi

	install -m 0644 "${src}" "${dst}"
	printf 'Installed %s:\n  %s -> %s\n' "${label}" "${src}" "${dst}"
}

install_one() {
	local amp=$1
	local coeff_src coeff_dst wmfw_src wmfw_dst

	coeff_src=$(coeff_file "${donor_ssid}" "${donor_spkid}" "${amp}")
	coeff_dst=$(coeff_file "${target_ssid}" "${target_spkid}" "${amp}")
	wmfw_src="${firmware_dir}/cs35l41-dsp1-spk-prot.wmfw.zst"
	wmfw_dst=$(wmfw_file "${target_ssid}" "${target_spkid}" "${amp}")

	install_alias "${wmfw_src}" "${wmfw_dst}" "${amp} WMFW alias"
	install_alias "${coeff_src}" "${coeff_dst}" "${amp} coefficient alias"
}

restore_one() {
	local amp=$1
	local dst disabled kind

	for kind in coeff wmfw; do
		case "${kind}" in
			coeff) dst=$(coeff_file "${target_ssid}" "${target_spkid}" "${amp}") ;;
			wmfw) dst=$(wmfw_file "${target_ssid}" "${target_spkid}" "${amp}") ;;
		esac
		disabled="${dst}.disabled-um3405ga-${stamp}"

		if [[ ! -e "${dst}" ]]; then
			printf 'No %s target to disable for %s:\n  %s\n' "${kind}" "${amp}" "${dst}"
			continue
		fi

		mv "${dst}" "${disabled}"
		printf 'Disabled %s %s target:\n  %s\n' "${amp}" "${kind}" "${disabled}"
	done
}

find_alc294_card() {
	local codec card

	if [[ -n "${CARD:-}" ]]; then
		printf '%s\n' "${CARD}"
		return 0
	fi

	for codec in /proc/asound/card*/codec#0; do
		[[ -e "${codec}" ]] || continue
		if grep -q '^Codec: Realtek ALC294$' "${codec}" &&
			grep -qi '^Subsystem Id: 0x104319f4$' "${codec}"; then
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

if [[ ! -d "${firmware_dir}" ]]; then
	printf 'Missing firmware directory: %s\n' "${firmware_dir}" >&2
	exit 1
fi

case "${action}" in
	install)
		install_one l0
		install_one r0
		;;
	restore)
		restore_one l0
		restore_one r0
		;;
esac

if card=$(find_alc294_card); then
	reload_firmware "${card}" || true
else
	printf 'Could not auto-detect the UM3405GA ALC294 ALSA card; reboot to load the tuning.\n'
fi

printf '\nCheck the CS35L41 firmware log with:\n'
printf '  journalctl -k -b --no-pager | grep -Ei %q\n' '104319f4|10431c03|falling back|Firmware Loaded|cs35l41'
