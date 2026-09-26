# elspi-base-reuse.sh -- build the stock Raspberry Pi OS base (stages 0-2)
# once and reuse it, on a builder whose pi-gen work volume survives.
#
# SOURCED, NEVER EXECUTED, and sourcing it only DEFINES functions:
#   - elspi.conf calls elspi_base_prepare  (decide, and set up the stage SKIPs)
#   - stage-elspi/prerun.sh calls elspi_base_record  (mark the base reusable)
#
# WHY. stage0-2 are pi-gen's stock Lite base and, with arm64 emulated under
# qemu, the dominant cost of a build. Nothing elspi changes between builds
# touches them, so on a self-hosted runner with a persistent work volume they
# are built once and reused. On a builder that starts empty -- GitHub's hosted
# runners, a first local build -- there is no work dir to reuse, every run is
# FULL, and the image is what it was before this file existed.
#
# WHY THE DECISION IS MADE HERE, from files. Nothing a runner exports reaches
# build.sh: build-docker.sh:140 forwards only GIT_HASH with -e, and :139
# mounts the chosen config ALONE at /config. What the container can see is
# its own copy of the repo, the config, and the work volume -- so the
# decision is made while build.sh sources the config (build.sh:169).
#
# THE MECHANISM IS UPSTREAM'S OWN, unedited. build.sh:101 tests a stage's
# SKIP file BEFORE its CLEAN block (:102-106) can delete that stage's rootfs,
# and :121-123 set PREV_ROOTFS_DIR for a skipped stage exactly as for a run
# one, from ROOTFS_DIR=${WORK_DIR}/<stage>/rootfs (:91-92). So with
# stage0-2/SKIP present, stage-elspi's copy_previous (scripts/common:34-41)
# copies the kept ${WORK_DIR}/stage2/rootfs.
#
# REUSE REQUIRES ALL OF:
#   - ${WORK_DIR}/stage2/rootfs exists;
#   - ${WORK_DIR}/stage2/.elspi-base-fingerprint (NEXT TO the rootfs, never
#     in it, or it would ship) equals a hash computed now over every input
#     that shapes stages 0-2 -- see _elspi_base_manifest;
#   - that file is under 7 days old, so Debian and Raspberry Pi archive
#     updates reach the base within a week with no cleanup timer.
# The fingerprint is written ONLY by elspi_base_record, i.e. only after
# stage2 has completed in a FULL run, and NEVER on a REUSE run: a rewrite
# would refresh its mtime and the 7-day bound would never expire. A FULL run
# deletes it before stage0 starts, so a base build that dies part way is
# never marked reusable.
#
# ALWAYS, in build.sh's shell: CLEAN=1, so stage-elspi and export-image
# rebuild from a fresh copy of stage2's rootfs rather than stacking on the
# last run's (stage-elspi/prerun.sh copies only when its rootfs is ABSENT);
# and deploy/ is emptied, because build-docker.sh:154 copies the whole deploy
# volume out and a leftover image fails image.yml's "exactly one image" gate.
#
# NOTHING HAPPENS ON THE HOST. build-docker.sh:52 also sources the config,
# under `set -eu`, with no BASE_DIR; elspi.conf does not even source this file
# there, and elspi_base_prepare checks again (_elspi_base_in_build_sh).

_ELSPI_BASE_MAX_AGE_S=$((7 * 86400))

# True only in build.sh's own shell, while it sources the config: BASE_DIR is
# set (build.sh:147/:156) AND the outermost script on the source stack is
# ${BASE_DIR}/build.sh, resolved the way build.sh:147 resolves itself. The
# second test is what keeps a BASE_DIR that happens to be exported in an
# operator's shell from turning a host-side source into one that writes files.
_elspi_base_in_build_sh() {
	[ -n "${BASE_DIR:-}" ] || return 1
	local outer="${BASH_SOURCE[$((${#BASH_SOURCE[@]} - 1))]}"
	local outer_abs
	outer_abs="$(cd "$(dirname "${outer}")" 2>/dev/null && pwd)/$(basename "${outer}")"
	[ "${outer_abs}" = "${BASE_DIR}/build.sh" ]
}

# build.sh:180-190 derive WORK_DIR AFTER the config is sourced, so it is not
# set yet here; derive it the same way.
_elspi_base_workdir() {
	printf '%s' "${WORK_DIR:-${BASE_DIR}/work/${IMG_NAME:-raspios-${RELEASE:-trixie}-arm64}}"
}

# Everything that shapes stages 0-2, one line each, in a fixed order. The
# fingerprint is the sha256 of this text. Returns non-zero, and the caller
# builds FULL, if any input cannot be read.
#
#   - every file under stage0/ stage1/ stage2/ scripts/, plus build.sh, the
#     Dockerfile (the debootstrap and qemu the base is built with), elspi.conf
#     and this file: path, content hash, and the executable bit, because
#     build.sh:67 and :107 SKIP a script without it. Sorted with LC_ALL=C.
#     stage0-2's own SKIP and SKIP_IMAGES are left out: this file and
#     elspi.conf create them, and hashing them would flip the result.
#   - ARCH (a constant in build.sh:180) and RELEASE.
#   - the stage 0-2 settings build.sh exports (:205-224), as the config has
#     set them so far. FIRST_USER_PASS is deliberately NOT here: elspi.conf
#     makes it random per build (so it would force FULL every time), and
#     stage-elspi/05-service-user replaces it with a bare '!' in every image.
#   - the CONTENT of every config on the source stack (/config, and ci.conf
#     when ci-test.conf sources it), ${BASE_DIR}/config if build.sh:158-161
#     sourced one, and ELSPI_SITE_CONF -- anything set after this point by a
#     config that sources elspi.conf is covered by that config's content.
_elspi_base_manifest() {
	local p f h x n=0
	for p in stage0 stage1 stage2 scripts build.sh Dockerfile elspi.conf elspi-base-reuse.sh; do
		[ -e "${BASE_DIR}/${p}" ] || { echo "elspi base: missing input ${BASE_DIR}/${p}" >&2; return 1; }
	done

	echo "ARCH=$(sed -n 's/^export ARCH=//p' "${BASE_DIR}/build.sh")"
	echo "RELEASE=${RELEASE:-}"
	for p in TARGET_HOSTNAME FIRST_USER_NAME DISABLE_FIRST_BOOT_USER_RENAME \
		PASSWORDLESS_SUDO WPA_COUNTRY ENABLE_SSH PUBKEY_ONLY_SSH \
		PUBKEY_SSH_FIRST_USER LOCALE_DEFAULT KEYBOARD_KEYMAP KEYBOARD_LAYOUT \
		TIMEZONE_DEFAULT ENABLE_CLOUD_INIT; do
		printf '%s=%s\n' "${p}" "${!p:-}"
	done

	while IFS= read -r -d '' f; do
		case "${f}" in
			stage[012]/SKIP|stage[012]/SKIP_IMAGES) continue ;;
		esac
		if [ -L "${BASE_DIR}/${f}" ]; then
			printf 'L %s -> %s\n' "${f}" "$(readlink "${BASE_DIR}/${f}")"
		else
			h="$(sha256sum < "${BASE_DIR}/${f}")" || return 1
			h="${h%% *}"
			[ "${#h}" -eq 64 ] || return 1
			x=-
			[ -x "${BASE_DIR}/${f}" ] && x=x
			printf 'F %s %s %s\n' "${x}" "${h}" "${f}"
		fi
		n=$((n + 1))
	done < <(cd "${BASE_DIR}" && find stage0 stage1 stage2 scripts build.sh Dockerfile \
		elspi.conf elspi-base-reuse.sh \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
	[ "${n}" -gt 0 ] || return 1

	for f in "${BASH_SOURCE[@]}" "${BASE_DIR}/config" "${ELSPI_SITE_CONF:-}"; do
		[ -n "${f}" ] && [ -f "${f}" ] || continue
		h="$(sha256sum < "${f}")" || return 1
		echo "C ${h%% *}"
	done
}

elspi_base_prepare() {
	_elspi_base_in_build_sh || return 0

	local work fp_file manifest fp="" stored mode=FULL reason age_s days s
	local deploy="${DEPLOY_DIR:-${BASE_DIR}/deploy}"
	work="$(_elspi_base_workdir)"
	fp_file="${work}/stage2/.elspi-base-fingerprint"

	# deploy/ first: it is emptied on every run, REUSE or FULL. Its CONTENTS,
	# not the directory, which is a Docker volume mount point (Dockerfile:16).
	if [ -d "${deploy}" ]; then
		find "${deploy}" -mindepth 1 -delete
		if [ -n "$(find "${deploy}" -mindepth 1 -print -quit)" ]; then
			echo "FATAL: could not empty ${deploy}; a leftover image would be copied out with the new one"
			exit 1
		fi
	fi

	if manifest="$(_elspi_base_manifest)"; then
		fp="$(printf '%s\n' "${manifest}" | sha256sum)"
		fp="${fp%% *}"
	fi

	if [ "${#fp}" -ne 64 ]; then
		fp=""
		reason="could not compute the stage0-2 fingerprint"
	elif [ ! -d "${work}/stage2/rootfs" ]; then
		reason="no stage2 rootfs in ${work}"
	elif [ ! -f "${fp_file}" ]; then
		reason="stage2 rootfs has no fingerprint: never recorded, or its FULL run did not finish"
	elif ! stored="$(cat "${fp_file}")" || [ "${stored}" != "${fp}" ]; then
		# An unreadable file counts as a mismatch, never as a match.
		reason="fingerprint mismatch: stage0-2 inputs changed"
	else
		age_s=$(($(date +%s) - $(stat -c %Y "${fp_file}")))
		days="$(awk -v s="${age_s}" 'BEGIN { printf "%.1f", s / 86400 }')"
		if [ "${age_s}" -lt 0 ]; then
			reason="fingerprint is dated in the future"
		elif [ "${age_s}" -ge "${_ELSPI_BASE_MAX_AGE_S}" ]; then
			reason="fingerprint ${days} days old, limit 7"
		else
			mode=REUSE
			reason="fingerprint match, ${days} days old"
		fi
	fi

	if [ "${mode}" = REUSE ]; then
		for s in stage0 stage1 stage2; do
			touch "${BASE_DIR}/${s}/SKIP"
			[ -f "${BASE_DIR}/${s}/SKIP" ] || { echo "FATAL: could not create ${BASE_DIR}/${s}/SKIP"; exit 1; }
		done
	else
		# The old fingerprint goes BEFORE stage0 starts: from here until
		# elspi_base_record runs, this base is not known to be complete.
		rm -f "${fp_file}"
		[ ! -e "${fp_file}" ] || { echo "FATAL: could not remove ${fp_file}"; exit 1; }
		for s in stage0 stage1 stage2; do
			rm -f "${BASE_DIR}/${s}/SKIP"
			[ ! -e "${BASE_DIR}/${s}/SKIP" ] || { echo "FATAL: could not remove ${BASE_DIR}/${s}/SKIP"; exit 1; }
		done
	fi

	CLEAN=1
	ELSPI_BASE_MODE="${mode}"
	ELSPI_BASE_FINGERPRINT="${fp}"
	ELSPI_BASE_FP_FILE="${fp_file}"
	# Exported: stage-elspi/prerun.sh is a CHILD of build.sh and reads them.
	export CLEAN ELSPI_BASE_MODE ELSPI_BASE_FINGERPRINT ELSPI_BASE_FP_FILE
	echo "elspi base: ${mode} (${reason})${fp:+ fingerprint ${fp:0:12}}"
}

# Called from stage-elspi/prerun.sh. Reaching that prerun means build.sh
# (`#!/bin/bash -e`) has come through stage0-2 without an error, so in a FULL
# run this is the first point at which the new base is known to be complete.
elspi_base_record() {
	case "${ELSPI_BASE_MODE:-}" in
		REUSE)
			echo "elspi base: REUSE run, fingerprint left untouched (a rewrite would restart its 7-day clock)"
			return 0 ;;
		FULL) ;;
		*)
			echo "elspi base: no base mode set (the config did not run elspi_base_prepare); not recorded"
			return 0 ;;
	esac
	if [ -z "${ELSPI_BASE_FINGERPRINT:-}" ] || [ -z "${ELSPI_BASE_FP_FILE:-}" ]; then
		echo "elspi base: FULL run without a fingerprint; base not marked reusable"
		return 0
	fi
	printf '%s\n' "${ELSPI_BASE_FINGERPRINT}" > "${ELSPI_BASE_FP_FILE}.tmp"
	mv -f "${ELSPI_BASE_FP_FILE}.tmp" "${ELSPI_BASE_FP_FILE}"
	if [ "$(cat "${ELSPI_BASE_FP_FILE}")" != "${ELSPI_BASE_FINGERPRINT}" ]; then
		echo "FATAL: post-write check failed for ${ELSPI_BASE_FP_FILE}"
		exit 1
	fi
	echo "elspi base: stage0-2 complete, fingerprint ${ELSPI_BASE_FINGERPRINT:0:12} recorded (reusable for 7 days)"
}
