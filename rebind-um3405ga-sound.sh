#!/usr/bin/env bash
set -euo pipefail

# Move the ALC294 codec from snd_hda_codec_generic to the Realtek driver, so the
# quirk table (and with it the CS35L41 speaker binding) actually applies.
#
# The codec's hdaudio device name depends on the card index, so it is discovered
# by codec vendor ID rather than assumed to be hdaudioC1D0.

alc294_vendor_id=0x10ec0294
generic_driver='/sys/bus/hdaudio/drivers/snd_hda_codec_generic'
realtek_driver='/sys/bus/hdaudio/drivers/snd_hda_codec_alc269'
wait_seconds=${WAIT_SECONDS:-10}
wait_for_device=0

usage() {
	cat <<EOF
Usage:
  sudo $0 [--wait]

Options:
  --wait   Poll for up to ${wait_seconds}s until the ALC294 codec appears (used by the
           systemd unit, which can start before the HDA device is registered).

Environment overrides:
  DEVICE=<hdaudio device name, e.g. hdaudioC1D0>
  WAIT_SECONDS=${wait_seconds}
EOF
}

case "${1:-}" in
	--wait) wait_for_device=1 ;;
	--help|-h)
		usage
		exit 0
		;;
	'') ;;
	*)
		usage >&2
		exit 2
		;;
esac

if [[ ${EUID} -ne 0 ]]; then
	printf 'Run this as root:\n  sudo %q\n' "$0" >&2
	exit 1
fi

find_alc294_device() {
	local dev vendor

	if [[ -n "${DEVICE:-}" ]]; then
		[[ -e "/sys/bus/hdaudio/devices/${DEVICE}" ]] || return 1
		printf '%s\n' "${DEVICE}"
		return 0
	fi

	for dev in /sys/bus/hdaudio/devices/*; do
		[[ -e "${dev}/vendor_id" ]] || continue
		vendor=$(cat "${dev}/vendor_id" 2>/dev/null)
		if [[ "${vendor,,}" == "${alc294_vendor_id}" ]]; then
			basename "${dev}"
			return 0
		fi
	done

	return 1
}

device=''
if [[ "${wait_for_device}" == "1" ]]; then
	for _ in $(seq 1 $((wait_seconds * 10))); do
		if device=$(find_alc294_device); then
			break
		fi
		sleep 0.1
	done
else
	device=$(find_alc294_device) || true
fi

if [[ -z "${device}" ]]; then
	printf 'No ALC294 (%s) codec found under /sys/bus/hdaudio/devices\n' "${alc294_vendor_id}" >&2
	exit 1
fi

device_path="/sys/bus/hdaudio/devices/${device}"
printf 'ALC294 codec: %s (subsystem %s)\n' \
	"${device}" "$(cat "${device_path}/subsystem_id" 2>/dev/null || printf '?')"

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
journalctl -k -b --no-pager | grep -Ei "alc269|realtek|generic|cs35|csc3551|${device}" | tail -n 40
