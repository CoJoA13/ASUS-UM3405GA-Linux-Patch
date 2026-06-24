#!/usr/bin/env bash
set -euo pipefail

device='hdaudioC1D0'
generic_driver='/sys/bus/hdaudio/drivers/snd_hda_codec_generic'
realtek_driver='/sys/bus/hdaudio/drivers/snd_hda_codec_alc269'
device_path="/sys/bus/hdaudio/devices/${device}"

if [[ ${EUID} -ne 0 ]]; then
	printf 'Run this as root:\n  sudo %q\n' "$0" >&2
	exit 1
fi

if [[ ! -e "${device_path}" ]]; then
	printf 'Missing HDA codec device: %s\n' "${device_path}" >&2
	exit 1
fi

modprobe snd_hda_codec_alc269

if [[ ! -e "${realtek_driver}/bind" ]]; then
	printf 'Realtek HDA codec driver did not register: %s\n' "${realtek_driver}" >&2
	exit 1
fi

if [[ -e "${realtek_driver}/${device}" ]]; then
	printf 'Current driver: '
	readlink -f "${device_path}/driver"
	exit 0
fi

if [[ -e "${generic_driver}/${device}" ]]; then
	printf '%s\n' "${device}" >"${generic_driver}/unbind"
fi

if ! printf '%s\n' "${device}" >"${realtek_driver}/bind"; then
	printf 'Realtek bind failed; restoring generic driver if possible.\n' >&2
	if [[ -e "${generic_driver}/bind" ]]; then
		printf '%s\n' "${device}" >"${generic_driver}/bind" || true
	fi
	exit 1
fi

printf 'Current driver: '
readlink -f "${device_path}/driver"
printf '\nRecent HDA logs:\n'
journalctl -k -b --no-pager | grep -Ei 'alc269|realtek|generic|cs35|csc3551|hdaudioC1D0' | tail -n 40
