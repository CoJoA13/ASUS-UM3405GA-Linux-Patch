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
report_file=${REPORT_FILE:-}
report_tmp=''
report_tmpdir=''
pause=${PAUSE:-auto}
exit_status=0

usage() {
	cat <<EOF
Usage:
  $0 [--pause|--no-pause]

Writes the report to the terminal and to a file. Double-clicking this script
from a file manager also works: the window is held open until you press Enter.

Environment overrides:
  REPORT_FILE=<path>   (default: ./um3405ga-sound-report.txt, or \$HOME if unwritable)
  PAUSE=auto|1|0
  TARGET_SSID=${target_ssid}
  DONOR_SSID=${donor_ssid}
  FIRMWARE_DIR=${firmware_dir}
  MODULES_DIR=${modules_dir}
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--pause) pause=1 ;;
		--no-pause) pause=0 ;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 2
			;;
	esac
	shift
done

# A double-clicked script gets a terminal that closes the instant it exits, so
# hold the window open unless this was started from a shell prompt. A launcher
# shell (`sh -c /path/to/script`, which is how several file managers and
# x-terminal-emulator start things) looks like a shell parent but closes just
# the same, so it is told apart by the -c in its command line.
should_pause() {
	local comm arg

	[[ -t 1 ]] || return 1

	comm=$(ps -o comm= -p "${PPID}" 2>/dev/null)
	# Unknown parent: never risk holding open a window nobody is watching.
	[[ -n "${comm}" ]] || return 1

	case "${comm}" in
		*sh|sudo|doas|tmux*|screen) ;;
		*) return 0 ;;
	esac

	if [[ -r "/proc/${PPID}/cmdline" ]]; then
		while IFS= read -r -d '' arg; do
			# -c, and combined invocations such as `bash -lc` or `sh -ic`.
			[[ "${arg}" =~ ^-[^-]*c ]] && return 0
		done <"/proc/${PPID}/cmdline"
	fi

	return 1
}

if [[ "${pause}" == "auto" ]]; then
	if should_pause; then
		pause=1
	else
		pause=0
	fi
fi

# The report name is predictable and this script may be run with sudo from a
# directory other users can write to. Refuse anything that is not a plain file,
# then write to a mktemp sibling and rename it into place: rename(2) replaces a
# symlink rather than following it, so there is no window in which the report
# can be redirected through one.
prepare_report_file() {
	local path=$1
	local dir tmpdir

	if [[ -L "${path}" || ( -e "${path}" && ! -f "${path}" ) ]]; then
		printf 'Refusing to write the report to %s: not a regular file.\n' "${path}" >&2
		return 1
	fi

	# Build the report inside a private 0700 directory beside the destination,
	# so no other user can swap the path out from under the write, the chmod or
	# the rename. Same directory keeps the final rename on one filesystem.
	dir=$(dirname -- "${path}")
	tmpdir=$(mktemp -d -- "${dir}/.um3405ga-report.XXXXXX" 2>/dev/null) || return 1
	printf '%s\n' "${tmpdir}/report"
}

if [[ -n "${report_file}" ]]; then
	report_tmp=$(prepare_report_file "${report_file}") || report_file=''
else
	report_file="${PWD}/um3405ga-sound-report.txt"
	if ! report_tmp=$(prepare_report_file "${report_file}"); then
		report_file="${HOME:-/tmp}/um3405ga-sound-report.txt"
		report_tmp=$(prepare_report_file "${report_file}") || report_file=''
	fi
fi

if [[ -n "${report_tmp}" ]]; then
	report_tmpdir=$(dirname -- "${report_tmp}")
	trap '[[ -n "${report_tmpdir}" ]] && rm -rf -- "${report_tmpdir}"' EXIT
else
	printf 'Could not create a report file; printing to the terminal only.\n' >&2
	exit_status=1
fi

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

run_report() {
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
		klog=$(journalctl -k -b --no-pager 2>/dev/null)

		bound=$(printf '%s\n' "${klog}" | grep -F 'CS35L41 Bound' | tail -4)
		if [[ -n "${bound}" ]]; then
			printf '%s\n' "${bound}" | sed 's/^.*cs35l41-hda/cs35l41-hda/'
		else
			printf 'No "CS35L41 Bound" lines in this boot; the amps never bound.\n'
			note 'CS35L41 amps did not bind this boot'
		fi

		# Matched in-shell rather than through `| grep -q`: grep exits on the
		# first hit, the writer takes SIGPIPE, and pipefail then reports 141 for a
		# pipeline that did match, silently dropping these findings.
		if [[ "${klog}" == *'Falling back to default firmware'* ]]; then
			printf 'DSP firmware: generic fallback in use (speakers will be quiet).\n'
			note 'CS35L41 fell back to generic firmware; the board tuning was not requested or not found'
		elif [[ "${klog}" == *'Firmware Loaded'* ]]; then
			printf 'DSP firmware: board tuning loaded.\n'
		fi

		# Coefficient blocks are matched to the algorithms in the loaded .wmfw.
		# Mismatches are logged rather than fatal, so these lines are what says
		# whether borrowed tuning actually applied.
		detail=$(printf '%s\n' "${klog}" |
			grep -iE 'cs35l41|cs_dsp|Firmware Loaded|Falling back|for algorithm|coefficient version|Bypassing Firmware|Cannot Run Firmware|Unable to find firmware' |
			tail -25)
		if [[ -n "${detail}" ]]; then
			printf '\nAmplifier/DSP log lines (last 25):\n'
			printf '%s\n' "${detail}" | sed 's/^.*\] //'
		fi

		alg_reject_re='No [^ ]+ for algorithm'
		if [[ "${klog}" =~ ${alg_reject_re} ]]; then
			note 'DSP rejected coefficient blocks (algorithm not in the loaded firmware); the borrowed tuning is not fully applied'
		fi
	else
		printf 'Kernel log not readable; re-run as root for amplifier details.\n'
	fi

	section 'ALSA amplifier controls'
	if command -v amixer >/dev/null 2>&1; then
		ctl_card=${CARD:-}
		if [[ -z "${ctl_card}" ]]; then
			for codec in /proc/asound/card*/codec#*; do
				[[ -e "${codec}" ]] || continue
				if grep -q '^Codec: Realtek ALC294$' "${codec}"; then
					ctl_card=${codec#/proc/asound/card}
					ctl_card=${ctl_card%%/*}
					break
				fi
			done
		fi

		if [[ -n "${ctl_card}" ]]; then
			printf 'Card %s:\n' "${ctl_card}"
			amixer -c "${ctl_card}" contents 2>/dev/null |
				grep -A2 -iE "name='.*(DSP1 Firmware|Speaker|Gain|Boost|Master)" |
				grep -viE '^--$' | sed 's/^/  /' | head -60
		else
			printf 'No ALC294 card found; pass CARD=<n> to inspect a specific card.\n'
		fi
	else
		printf 'amixer not installed (apt install alsa-utils).\n'
	fi

	section 'Previous boots'
	# A hard reset leaves no clean shutdown, so an unexpectedly ended boot with
	# an oops or hung task in it is worth surfacing here.
	if journalctl -k -b -1 --no-pager >/dev/null 2>&1; then
		for prev in -1 -2; do
			# Anchored to real crash records: a bare "panic" also matches the
			# ordinary "Command line: ... panic=30" line that many systems log on
			# every clean boot.
			crash=$(journalctl -k -b "${prev}" --no-pager 2>/dev/null |
				grep -E 'Kernel panic - not syncing|Oops: |BUG: |general protection fault|watchdog: BUG: soft lockup|INFO: task .* blocked for more than' |
				tail -8)
			if [[ -n "${crash}" ]]; then
				printf 'boot %s: crash evidence found\n' "${prev}"
				printf '%s\n' "${crash}" | sed 's/^.*\] //' | sed 's/^/  /'
				note "kernel crash evidence in boot ${prev}"
			else
				printf 'boot %s: no oops/panic/hung-task recorded\n' "${prev}"
			fi
		done
		printf 'A hard lockup often leaves nothing on disk, so a clean previous boot\n'
		printf 'here does not rule one out.\n'
	else
		printf 'No earlier boots in the journal (persistent logging may be off:\n'
		printf 'enable it with "sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal").\n'
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
}

if [[ -n "${report_tmp}" ]] && ! exec {report_fd}>"${report_tmp}"; then
	printf 'Could not open %s for writing.\n' "${report_tmp}" >&2
	report_tmp=''
	exit_status=1
fi

if [[ -n "${report_tmp}" ]]; then
	# Write and set permissions through the descriptor opened above, never
	# through the pathname: rename permission on the temporary directory belongs
	# to its parent, so a shared working directory means the path can be moved
	# aside mid-run. A descriptor stays bound to the file that was opened.
	run_report | tee -- "/dev/fd/${report_fd}"
	tee_status=${PIPESTATUS[1]}

	# The report quotes the kernel log, which may be root-only, so keep it
	# private and hand it to whoever invoked sudo rather than world-readable.
	if [[ "${tee_status}" == "0" ]] &&
		chmod 0600 -- "/proc/self/fd/${report_fd}" 2>/dev/null &&
		{ [[ -z "${SUDO_UID:-}" ]] ||
			chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" -- \
				"/proc/self/fd/${report_fd}" 2>/dev/null; }; then
		# Remember which file the descriptor refers to, so success is only
		# claimed when the destination really is that file afterwards.
		# -L because stat does not dereference by default, and this path is a
		# symlink into the process's own descriptor table.
		report_inode=$(stat -L -c %i -- "/proc/self/fd/${report_fd}" 2>/dev/null)
		exec {report_fd}>&-
		if mv -fT -- "${report_tmp}" "${report_file}" 2>/dev/null &&
			[[ -n "${report_inode}" &&
				"$(stat -c %i -- "${report_file}" 2>/dev/null)" == "${report_inode}" ]]; then
			printf '\nSaved this report to:\n  %s\n' "${report_file}"
		else
			printf '\nFailed to move the report into place at %s.\n' "${report_file}" >&2
			printf 'The report above is complete.\n' >&2
			exit_status=1
		fi
	else
		exec {report_fd}>&-
		printf '\nFailed to save the report to %s (tee exited %s).\n' \
			"${report_file}" "${tee_status}" >&2
		printf 'The report above is complete.\n' >&2
		exit_status=1
	fi
else
	run_report
fi

if [[ "${pause}" == "1" ]]; then
	printf '\nPress Enter to close this window...'
	read -r || true
fi

exit "${exit_status}"
