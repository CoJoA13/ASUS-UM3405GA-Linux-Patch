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
detected_spkid=''
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
  REPORT_FILE=<path>   (default: ./um3405ga-sound-report.txt, falling back to
                       your home directory and then /tmp if that is unwritable)
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

# The report is created as the invoking user, never as root. When this runs
# under sudo the file work is dropped back to $SUDO_UID, so the kernel decides
# where the report may land: no ownership check of ours can be raced or fooled
# by a swapped path component, because root never creates the file at all. That
# also removes the need to chown it afterwards.
#
# A staging directory plus a rename still guards the non-privileged case: the
# destination name is predictable, and rename(2) replaces a symlink rather than
# writing through one.
as_user() {
	if [[ -n "${SUDO_UID:-}" ]] && command -v setpriv >/dev/null 2>&1; then
		# --init-groups, not --clear-groups: a home or project directory is
		# often writable through a supplementary group, and dropping those
		# would refuse a directory the invoking user can plainly write.
		setpriv --reuid="${SUDO_UID}" --regid="${SUDO_GID:-${SUDO_UID}}" \
			--init-groups -- "$@"
	else
		"$@"
	fi
}

# $HOME still names root's home under sudo, and root's home is exactly where
# the invoking user cannot write. Ask the password database instead.
invoking_home() {
	local home=''
	if [[ -n "${SUDO_UID:-}" ]] && command -v getent >/dev/null 2>&1; then
		home=$(getent passwd "${SUDO_UID}" 2>/dev/null |
			awk -F: 'NR == 1 { print $6 }')
	fi
	[[ -n "${home}" ]] || home=${HOME:-}
	printf '%s' "${home}"
}

# The staging write is bound to the inode this opens, not to its name. Another
# user who can rename the staging directory could otherwise leave a symlink
# where the write expects to reopen the file, and tee would follow it into
# whatever the invoking user owns. noclobber gives the create O_EXCL
# semantics, which refuses an existing name of any kind, and tee then writes
# through the descriptor. umask makes it 0600 from the start: the report
# quotes the kernel log, which may be root-only.
stage_report() {
	as_user "${BASH:-/bin/bash}" -c '
		set -o noclobber
		umask 077
		exec 3>"$1" || exit 1
		exec tee --output-error=warn-nopipe -- /dev/fd/3
	' um3405ga-report "$1"
}

prepare_report_file() {
	local path=$1
	local dir tmpdir

	report_tmp=''

	if [[ -n "${SUDO_UID:-}" ]] && ! command -v setpriv >/dev/null 2>&1; then
		printf 'Refusing to write a report under sudo without setpriv to drop privileges.\n' >&2
		return 1
	fi

	if [[ -L "${path}" || ( -e "${path}" && ! -f "${path}" ) ]]; then
		printf 'Refusing to write the report to %s: not a regular file.\n' "${path}" >&2
		return 1
	fi

	dir=$(dirname -- "${path}")
	tmpdir=$(as_user mktemp -d -- "${dir}/.um3405ga-report.XXXXXX" 2>/dev/null) || return 1

	report_tmp="${tmpdir}/report"
	report_tmpdir="${tmpdir}"
}

# Called directly, not through command substitution: the descriptor it opens
# has to survive into this shell.
if [[ -n "${report_file}" ]]; then
	prepare_report_file "${report_file}" || report_file=''
else
	report_file="${PWD}/um3405ga-sound-report.txt"
	if ! prepare_report_file "${report_file}"; then
		for report_dir in "$(invoking_home)" /tmp; do
			[[ -n "${report_dir}" ]] || continue
			report_file="${report_dir}/um3405ga-sound-report.txt"
			prepare_report_file "${report_file}" && break
			report_file=''
		done
	fi
fi

if [[ -n "${report_tmp}" ]]; then
	trap '[[ -n "${report_tmpdir}" ]] && as_user rm -rf -- "${report_tmpdir}"' EXIT
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

# The driver asks for a .wmfw and a .bin per amp, and it falls back to the
# generic firmware if either is missing. Listing the files is not enough:
# half a set looks installed and still leaves the speaker quiet.
check_tuning_set() {
	local ssid=$1 file name stem amp variant prefix want orphans=''
	local best=0 best_variant='' wanted_is=1
	shift
	local -A have_wmfw=() have_bin=() variants=()
	local -a amp_list=() wanted=()

	prefix="cs35l41-dsp1-spk-prot-${ssid}"
	if [[ -n "${detected_spkid}" ]]; then
		# Only these two names can be requested this boot: the speaker-ID
		# variant read from the GPIO, and the bare name the driver falls back
		# to. Files under any other variant are leftovers from an earlier
		# install -- worth listing, not worth calling a fault.
		wanted=("${prefix}-spkid${detected_spkid}" "${prefix}")
	fi

	for file in "$@"; do
		# linux-firmware ships these compressed on most distributions and the
		# installer keeps whatever compression the donor used, so .wmfw.zst
		# and .bin.xz are ordinary complete installs, not stray files.
		name=${file%.zst}
		name=${name%.xz}
		name=${name%.gz}
		case "${name}" in
			*.wmfw) have_wmfw["${name%.wmfw}"]=1 ;;
			*.bin) have_bin["${name%.bin}"]=1 ;;
		esac
	done

	for stem in "${!have_wmfw[@]}"; do
		if [[ -z "${have_bin[${stem}]:-}" ]]; then
			orphans+=" ${stem}.wmfw"
			continue
		fi
		# The driver requests one speaker-ID variant, so both amps have to be
		# complete within that same variant. An L0 pair from spkid0 and an R0
		# pair from spkid1 covers both amps on paper and satisfies neither
		# request.
		variant=${stem%-*}
		amp=${stem##*-}
		variants["${variant}"]+=" ${amp}"
	done

	for stem in "${!have_bin[@]}"; do
		[[ -n "${have_wmfw[${stem}]:-}" ]] || orphans+=" ${stem}.bin"
	done

	# Printed, not raised: whether an unpaired file matters depends entirely on
	# whether the driver asks for its variant, and the check below already
	# decides that.
	[[ -n "${orphans}" ]] &&
		printf '  incomplete, missing their pair:%s\n' "${orphans}"

	for variant in "${!variants[@]}"; do
		if [[ ${#wanted[@]} -gt 0 ]]; then
			wanted_is=0
			for want in "${wanted[@]}"; do
				[[ "${variant}" == "${want}" ]] && wanted_is=1
			done
			[[ "${wanted_is}" == "1" ]] || continue
		fi
		read -r -a amp_list <<<"${variants[${variant}]}"
		if [[ ${#amp_list[@]} -gt ${best} ]]; then
			best=${#amp_list[@]}
			best_variant=${variant}
		fi
	done

	if [[ "${best}" -ge 2 ]]; then
		return 0
	fi

	if [[ "${best}" == "0" ]]; then
		if [[ -n "${detected_spkid}" ]]; then
			note "No complete ${ssid} tuning pair (.wmfw plus .bin) is installed under the name this boot asks for (spkid${detected_spkid}, or the bare ${ssid}), so both amps fall back to the generic (quiet) firmware; reinstall with install-um3405ga-cs35l41-tuning.sh install"
		else
			note "No complete ${ssid} tuning pair (.wmfw plus .bin) is installed for either amp; reinstall with install-um3405ga-cs35l41-tuning.sh install"
		fi
	else
		note "${best_variant} covers only${variants[${best_variant}]}; the driver requests a single variant, so the other amp falls back to the generic (quiet) firmware -- reinstall with install-um3405ga-cs35l41-tuning.sh install"
	fi
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
			# The speaker ID is read from a GPIO at probe and decides which
			# firmware variant the driver asks for, so the inventory below can
			# tell the requested tuning from leftovers of another variant.
			spkid_re='SPKID: ([0-9]+)'
			[[ "${bound}" =~ ${spkid_re} ]] && detected_spkid=${BASH_REMATCH[1]}
		else
			printf 'No "CS35L41 Bound" lines in this boot; the amps never bound.\n'
			note 'CS35L41 amps did not bind this boot'
		fi

		# Matched in-shell rather than through `| grep -q`: grep exits on the
		# first hit, the writer takes SIGPIPE, and pipefail then reports 141 for a
		# pipeline that did match, silently dropping these findings.
		# Track each amp separately: they can end up in different states, and one
		# working amp must not mask one that fell back.
		#
		# State is the outcome of a whole load attempt, not the last marker seen.
		# cs35l41_fallback_firmware_file() warns "Falling back to default
		# firmware", then loads the generic firmware and the same path logs
		# "Firmware Loaded" on success -- so both lines appear for a fallen-back
		# amp, and reading only the last one would call generic firmware a win. A
		# later "Firmware Loaded" with no fallback before it is a genuine reload.
		declare -A amp_state=()
		declare -A amp_pending=()
		amp_marker_re='cs35l41-hda ([^ ]+): (Falling back to default firmware|Firmware Loaded|Unable to find firmware|Cannot Run Firmware|Bypassing Firmware)'
		while IFS= read -r line; do
			[[ "${line}" =~ ${amp_marker_re} ]] || continue
			amp_dev=${BASH_REMATCH[1]}
			case "${BASH_REMATCH[2]}" in
				'Falling back to default firmware')
					amp_pending["${amp_dev}"]=fallback
					amp_state["${amp_dev}"]=fallback
					;;
				'Firmware Loaded')
					if [[ "${amp_pending[${amp_dev}]:-}" == "fallback" ]]; then
						amp_state["${amp_dev}"]=fallback
					else
						amp_state["${amp_dev}"]=loaded
					fi
					amp_pending["${amp_dev}"]=''
					;;
				*)
					amp_state["${amp_dev}"]=failed
					amp_pending["${amp_dev}"]=''
					;;
			esac
		done < <(printf '%s\n' "${klog}" |
			grep -E 'Falling back to default firmware|Firmware Loaded|Unable to find firmware|Cannot Run Firmware|Bypassing Firmware')

		fallback_amps=''
		loaded_amps=''
		failed_amps=''
		for amp_dev in "${!amp_state[@]}"; do
			case "${amp_state[${amp_dev}]}" in
				fallback) fallback_amps+=" ${amp_dev}" ;;
				loaded) loaded_amps+=" ${amp_dev}" ;;
				*) failed_amps+=" ${amp_dev}" ;;
			esac
		done

		if [[ -n "${loaded_amps}" ]]; then
			printf 'DSP firmware: board tuning loaded on:%s\n' "${loaded_amps}"
		fi
		if [[ -n "${fallback_amps}" ]]; then
			printf 'DSP firmware: generic fallback in use on:%s\n' "${fallback_amps}"
			note 'At least one CS35L41 amp fell back to generic firmware; that speaker will be quiet'
		fi
		if [[ -n "${failed_amps}" ]]; then
			printf 'DSP firmware: did not start on:%s\n' "${failed_amps}"
			note 'At least one CS35L41 amp could not run its DSP firmware (see the log lines below)'
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
			note 'DSP rejected coefficient blocks during at least one firmware load this boot (algorithm not in the loaded firmware); reboot and re-check to see the current state'
		fi
	else
		printf 'Kernel log not readable; re-run as root for amplifier details.\n'
	fi

	section 'ALSA amplifier controls'
	if command -v amixer >/dev/null 2>&1; then
		ctl_card=${CARD:-}
		if [[ -z "${ctl_card}" ]]; then
			# Prefer the ALC294 whose subsystem is this machine's; fall back to any
			# ALC294 so a different subsystem ID still gets a report rather than an
			# empty section.
			for want_ssid in 1 0; do
				for codec in /proc/asound/card*/codec#*; do
					[[ -e "${codec}" ]] || continue
					grep -q '^Codec: Realtek ALC294$' "${codec}" || continue
					if [[ "${want_ssid}" == "1" ]] &&
						! grep -qi "^Subsystem Id: 0x${target_ssid}\$" "${codec}"; then
						continue
					fi
					ctl_card=${codec#/proc/asound/card}
					ctl_card=${ctl_card%%/*}
					break 2
				done
			done
		fi

		if [[ -n "${ctl_card}" ]]; then
			printf 'Card %s:\n' "${ctl_card}"
			# When the kernel log is unreadable these controls are the only evidence
			# that the amps came up, so an empty dump is a finding rather than a
			# blank section followed by "no problems detected".
			controls=$(amixer -c "${ctl_card}" contents 2>/dev/null |
				grep -A2 -iE "name='.*(DSP1 Firmware|Speaker|Gain|Boost|Master)" |
				grep -viE '^--$')
			if [[ -n "${controls}" ]]; then
				# Truncate what is printed, never what is parsed: the
				# firmware-load controls are indexed after the volume controls
				# on this card, so a capped dump could hide the very controls
				# the check below looks for and report the amps as absent.
				control_lines=$(printf '%s\n' "${controls}" | wc -l)
				printf '%s\n' "${controls}" | head -60 | sed 's/^/  /'
				if [[ "${control_lines}" -gt 60 ]]; then
					printf '  ... %s more line(s) not shown; all of them were checked\n' \
						"$((control_lines - 60))"
				fi
			else
				printf '  none (amixer failed, or the card exposes no matching controls)\n'
			fi

			# Only the CS35L41's own "L0/R0 DSP1 Firmware" controls show the amps
			# came up. Master/Speaker volume controls belong to the ALC294 and exist
			# whether or not the amps initialised, so they prove nothing here.
			#
			# Presence is not enough either: a "Firmware Load" control left off (an
			# interrupted live reload, say) still appears in the dump while the DSP
			# runs untuned, and the boot journal keeps its earlier "Firmware Loaded"
			# line either way. Read the values.
			# Track the amps individually: one amp failing to initialise leaves its
			# controls absent entirely, which a single "did we see any" flag would
			# read as success while that speaker has no DSP at all.
			fw_ctl_amps=''
			fw_ctl_off=''
			ctl_name=''
			ctl_name_re="name='([^']*DSP1 Firmware[^']*)'"
			while IFS= read -r ctl_line; do
				if [[ "${ctl_line}" =~ ${ctl_name_re} ]]; then
					ctl_name=${BASH_REMATCH[1]}
					if [[ "${ctl_name}" == *'Firmware Load'* ]]; then
						fw_ctl_amps+=" ${ctl_name%% *}"
					else
						ctl_name=''
					fi
					continue
				fi
				if [[ -n "${ctl_name}" && "${ctl_line}" =~ ^[[:space:]]*:[[:space:]]*values=(.*)$ ]]; then
					[[ "${BASH_REMATCH[1]}" == *off* ]] && fw_ctl_off+=" ${ctl_name}"
					ctl_name=''
				fi
			done <<<"${controls}"

			# This machine has two CS35L41 amps, so it should expose two of these.
			read -r -a fw_ctl_amp_list <<<"${fw_ctl_amps}"
			if [[ ${#fw_ctl_amp_list[@]} -eq 0 ]]; then
				note 'No CS35L41 "DSP1 Firmware Load" controls on the ALC294 card; the amplifiers did not initialise'
			elif [[ ${#fw_ctl_amp_list[@]} -lt 2 ]]; then
				printf '  only one amp exposes a firmware-load control:%s\n' "${fw_ctl_amps}"
				note "Only ${#fw_ctl_amp_list[@]} CS35L41 firmware-load control present (expected 2, one per amp); the other amp did not initialise"
			fi

			if [[ -n "${fw_ctl_off}" ]]; then
				printf '  DSP firmware load is currently OFF on:%s\n' "${fw_ctl_off}"
				note 'CS35L41 DSP firmware load is switched off; those amps are running untuned regardless of what the boot log says'
			fi
		else
			printf 'No ALC294 card found; pass CARD=<n> to inspect a specific card.\n'
			note 'No ALC294 codec found in /proc/asound'
		fi
	else
		printf 'amixer not installed (apt install alsa-utils).\n'
		note 'amixer is not installed, so the amplifiers were not checked at all; install alsa-utils and re-run before trusting this summary'
	fi

	section 'Previous boots'
	# A hard reset leaves no clean shutdown, so an unexpectedly ended boot with
	# an oops or hung task in it is worth surfacing here.
	if journalctl -k -b -1 --no-pager >/dev/null 2>&1; then
		for prev in -1 -2; do
			if ! journalctl -k -b "${prev}" --no-pager >/dev/null 2>&1; then
				printf 'boot %s: not in the journal\n' "${prev}"
				continue
			fi

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
			# Disabled and backup copies cannot satisfy the name the driver asks
			# for, so listing them would misreport the tuning as installed.
			mapfile -t matches < <(find "${firmware_dir}" -maxdepth 1 \
				-name "cs35l41-dsp1-spk-prot-${ssid}*" \
				! -name '*.bak-um3405ga-*' ! -name '*.disabled-um3405ga-*' \
				-printf '%f\n' 2>/dev/null | sort)
			if [[ ${#matches[@]} -gt 0 ]]; then
				printf '%s:\n' "${ssid}"
				printf '  %s\n' "${matches[@]}"
				[[ "${ssid}" == "${target_ssid}" ]] &&
					check_tuning_set "${ssid}" "${matches[@]}"
			else
				printf '%s: none installed\n' "${ssid}"
				if [[ "${ssid}" == "${target_ssid}" ]]; then
					note "No ${target_ssid} tuning files installed, so the amps can only fall back to the generic (quiet) firmware; run install-um3405ga-cs35l41-tuning.sh install"
				fi
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

if [[ -n "${report_tmp}" ]]; then
	# The staging write runs as the invoking user, so it is bounded by their
	# own permissions. --output-error=warn-nopipe keeps the file complete when
	# a downstream consumer such as head exits early.
	run_report | stage_report "${report_tmp}"
	tee_status=${PIPESTATUS[1]}

	# rename(2) still resolves the staging name, so confirm afterwards that
	# what landed at the destination is the regular file we wrote and not
	# something a third party swapped in. Claiming a save that did not happen
	# is worse than saying so.
	if [[ "${tee_status}" == "0" ]] &&
		as_user mv -fT -- "${report_tmp}" "${report_file}" 2>/dev/null &&
		[[ -f "${report_file}" && ! -L "${report_file}" ]]; then
		printf '\nSaved this report to:\n  %s\n' "${report_file}"
	else
		printf '\nFailed to save the report to %s (write exited %s).\n' \
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
