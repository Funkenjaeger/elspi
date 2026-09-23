#!/bin/bash
# PHASE 2 -- RESTORE. Refuses to invent data.
#
#   02-restore.sh --config-backup <dir|tarball> [--firmware <flashed.json>] [--dry-run]
#   02-restore.sh --fresh [--firmware <flashed.json>] [--dry-run]
#
# Checklist item 14, and the one contract docs/design/seam.md says must not be softened:
#
#   "Provisioning must RESTORE the commissioned config from backup, never
#    generate it -- and must fail loudly rather than silently coming up with
#    defaults if no backup is available."
#
# --- --fresh: first commissioning, named on purpose ------------------------
# A brand-new machine has no backup. --fresh says so as a deliberate, loud
# choice rather than a guess: it is mutually exclusive with --config-backup,
# it skips everything below -- no files are written into CONFIG_DIR, nothing
# is generated, the application's own defaults apply -- and it refuses if
# CONFIG_DIR already holds anything, because a fresh provision must never
# mask existing commissioned data. It prints the UNCOMMISSIONED banner at the
# start of this phase and again in its final summary. First-commissioning
# users who DO have commissioned values to bring onto the machine should use
# the USB import on the reflex Setup screen, not this flag -- see
# docs/provisioning.md.
#
# WHAT IS AT STAKE. /var/lib/reflex-config is not configuration-as-code. It is
# COMMISSIONED MACHINE DATA measured off the physical lathe -- axis geometry,
# servo polarity, backlash calibration, Z scale counts/mm. Nothing can
# regenerate it. A provisioning run that "helpfully" comes up in a default
# state produces a lathe that looks fine, moves, and is wrong.
#
# THE FAILURE THIS GUARDS IS NOT HYPOTHETICAL. On 2026-09-07 the only backup
# was 16 days old and 13 of its 19 files had drifted -- els_backlash_steps 435
# where the machine had 450, els_cal_last_measured_steps 363 against 375, and
# three ElsAdvancedBar files that had since been deleted. Restoring it would
# have written August geometry onto the machine and looked like a success. So
# this phase also REPORTS what it restored, loudly, with the values that matter
# printed for a human to recognise -- because "the restore worked" and "the
# restore put the right numbers on the lathe" are different claims and only the
# first one is checkable here.
#
# WHY IT CANNOT FETCH THE BACKUP ITSELF. It would have to know where the
# backup host is, and item 13 forbids anything machine-specific in this repo.
# You bring the backup to the Pi; this phase refuses to proceed without it.
#
# --- THE CONTENT BAR: the public minimum, and a site's stricter one --------
# PUBLIC MINIMUM: a non-empty Els-0.yaml, i.e. at least ONE yaml file. That is
# what reflex itself requires, derived from the application at the newest
# full release (v1.1.0), not from any one machine:
#
#   * NO settings file is needed to START. Every persisted object is a
#     SavingDispatcher (ui/reflex/dispatchers/saving_dispatcher.py), whose
#     read_settings() (:55-62) calls save_settings() -- i.e. WRITES DEFAULTS
#     -- when its <Class>-<id>.yaml is absent (read_settings(), :101-103,
#     returns None for a missing file).
#   * Axes are the same, louder: with no Axis-*.yaml, BoardDispatcher.
#     _create_axes() (ui/reflex/dispatchers/board.py:72-119) builds four
#     IDENTITY axes and saves them.
#   * Els-0.yaml is the ELS dispatcher's file (ui/reflex/app.py:258,
#     ElsDispatcher(id_override="0"); dispatchers/els.py:128) and carries the
#     commissioned backlash and calibration. It is the one file whose absence
#     turns "restore" into "run on defaults", so it is the floor.
#
# So beyond Els-0.yaml, a missing file means the app silently writes its
# default -- the very failure this phase exists for. A site that knows how
# many files ITS machine carries should therefore raise the bar:
# ELSPI_RESTORE_MIN_YAML=<n> (in the environment, or in the site hooks
# directory's site.env, which provision.sh loads). It may only RAISE it: a
# value below the public minimum is refused. Missing Axis-*.yaml is also
# reported by name, whatever the bar.
#
# ROOT IS NEEDED ONLY TO WRITE. Every content gate below runs before
# need_root, so a refusal is the SAME refusal for any caller, and
# deltas/tests/test-restore-contract.sh can observe it unprivileged.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

BACKUP=""
FRESH=0
FIRMWARE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--config-backup) BACKUP="${2:-}"; shift 2 ;;
		--fresh)         FRESH=1; shift ;;
		--firmware)      FIRMWARE="${2:-}"; shift 2 ;;
		--dry-run)       DRY_RUN=1; shift ;;
		*) die "unknown argument: $1" ;;
	esac
done

# say/ok/warn/die all print to the terminal; this one is loud on purpose and
# reused verbatim at the end of the fresh path, so both prints agree exactly.
uncommissioned_banner() {
	printf '\n'
	printf '  %s*** THIS MACHINE IS UNCOMMISSIONED ***%s\n' "${_c_red}" "${_c_off}"
	say "No commissioned config was restored. Axis geometry, servo polarity,"
	say "backlash calibration and Z scale counts/mm are the application's own"
	say "defaults, not this lathe's measured values, and MUST BE MEASURED before"
	say "this machine is trusted to cut anything."
	printf '\n'
}

if [ "${FRESH}" = "1" ] && [ -n "${BACKUP}" ]; then
	die "--fresh and --config-backup are mutually exclusive.

  --fresh names first commissioning: no backup exists yet, and none should be
  applied. --config-backup names recovery: a capture exists and should be
  restored. Naming both does not say which one you mean."
fi

phase "Phase 2: RESTORE the commissioned config"

# CONFIG_DIR is needed by both paths below and resolving it needs neither root
# nor a service user to exist yet, so it happens unconditionally, up front.
resolve_paths

if [ "${FRESH}" = "1" ]; then
	# --- FRESH: first commissioning, no restore attempted ---------------------
	# Nothing below writes anything, so nothing below needs root -- root is
	# required only where this script actually mutates something (the
	# recovery path, and the firmware manifest below).
	uncommissioned_banner

	# A fresh provision must never mask existing commissioned data -- from a
	# previous restore, a previous --fresh, or a hand-edit. Gate on the
	# content (any file at all), not on whether the path itself exists, the
	# same principle the recovery path below uses.
	if [ -d "${CONFIG_DIR}" ] && [ -n "$(ls -A "${CONFIG_DIR}" 2>/dev/null)" ]; then
		die "--fresh refused: ${CONFIG_DIR} already holds a file.

  A fresh provision must never mask existing commissioned data. If this is a
  recovery, use --config-backup instead. If this directory is stale, move it
  aside by hand and re-run --fresh."
	fi

	ok "${CONFIG_DIR} does not exist or is empty -- nothing restored, nothing written"
else
	# --- THE BAR (see the header) ---------------------------------------------
	RESTORE_MIN_PUBLIC=1
	RESTORE_MIN="${ELSPI_RESTORE_MIN_YAML:-${RESTORE_MIN_PUBLIC}}"
	case "${RESTORE_MIN}" in
		''|*[!0-9]*) die "ELSPI_RESTORE_MIN_YAML='${ELSPI_RESTORE_MIN_YAML}' is not a whole number. REFUSING rather than guessing a bar." ;;
	esac
	RESTORE_MIN=$((10#${RESTORE_MIN}))
	[ "${RESTORE_MIN}" -ge "${RESTORE_MIN_PUBLIC}" ] \
		|| die "ELSPI_RESTORE_MIN_YAML=${RESTORE_MIN} is below the public minimum (${RESTORE_MIN_PUBLIC}: Els-0.yaml).
  A site may raise the bar, never lower it. REFUSING."
	if [ -n "${ELSPI_RESTORE_MIN_YAML:-}" ]; then
		RESTORE_BAR_SRC="ELSPI_RESTORE_MIN_YAML (a site's bar)"
	else
		RESTORE_BAR_SRC="the public minimum: Els-0.yaml"
	fi

	# --- THE CONTRACT ---------------------------------------------------------
	# Absent backup is a HARD FAIL. Not a warning, not "continuing with defaults",
	# not an empty directory created for later. The message says what to do,
	# because the person reading it is standing at a lathe.
	if [ -z "${BACKUP}" ]; then
		printf '\n'
		die "--config-backup was not given.

  REFUSING TO PROVISION. ${CONFIG_DIR} holds commissioned machine data
  measured off the physical lathe -- backlash, axis geometry, calibration.
  Nothing can regenerate it, so coming up with defaults would produce a
  machine that runs and is silently wrong.

  Bring the most recent capture of ${CONFIG_DIR} -- from wherever your
  backups of it are kept -- to this Pi and pass it:
      --config-backup /path/to/reflex-config-capture
  CHECK ITS DATE -- a stale capture restores stale geometry, which is the
  failure this text exists for."
	fi

	[ -e "${BACKUP}" ] || die "--config-backup ${BACKUP} does not exist"

	# Accept a directory or a tarball; normalise to a directory.
	SRC=""
	TMP=""
	cleanup() { [ -n "${TMP}" ] && rm -rf "${TMP}"; }
	trap cleanup EXIT INT TERM

	if [ -d "${BACKUP}" ]; then
		SRC="${BACKUP}"
		say "source: directory ${SRC}"
	else
		TMP="$(mktemp -d)"
		tar -C "${TMP}" -xf "${BACKUP}" || die "could not unpack ${BACKUP}"
		# A tarball may or may not have a single top-level directory.
		if [ "$(find "${TMP}" -mindepth 1 -maxdepth 1 -type d | wc -l)" = "1" ] \
		   && [ "$(find "${TMP}" -mindepth 1 -maxdepth 1 | wc -l)" = "1" ]; then
			SRC="$(find "${TMP}" -mindepth 1 -maxdepth 1 -type d)"
		else
			SRC="${TMP}"
		fi
		say "source: tarball ${BACKUP} -> ${SRC}"
	fi

	# --- GATE ON THE CONTENT, NOT THE PATH ------------------------------------
	# An empty or wrong directory that restored "successfully" is the failure mode
	# this whole phase exists to prevent, and it is indistinguishable from success
	# unless something looks inside.
	[ -s "${SRC}/Els-0.yaml" ] \
		|| die "no non-empty Els-0.yaml in ${SRC} -- that is the commissioned ELS
  geometry, and a capture without it is not a restore point. REFUSING."

	NYAML="$(find "${SRC}" -maxdepth 1 -name '*.yaml' | wc -l)"
	[ "${NYAML}" -ge "${RESTORE_MIN}" ] \
		|| die "only ${NYAML} yaml file(s) in ${SRC}; the bar is ${RESTORE_MIN}, set by
  ${RESTORE_BAR_SRC}. This looks like a partial capture. REFUSING rather than
  restoring a subset over a machine that needs all of it -- every file left
  out comes back as the application's DEFAULT the first time it starts."
	ok "${NYAML} yaml files (bar: ${RESTORE_MIN}, ${RESTORE_BAR_SRC}), Els-0.yaml present and non-empty"

	# Reported, not refused, at the public minimum: with no Axis-*.yaml the
	# application builds four IDENTITY axes on first start (reflex
	# ui/reflex/dispatchers/board.py:_create_axes) -- geometry that looks
	# plausible and is not this machine's.
	if [ -z "$(find "${SRC}" -maxdepth 1 -name 'Axis-*.yaml' -print -quit)" ]; then
		warn "no Axis-*.yaml in ${SRC}: the application will create four DEFAULT
        (identity) axes on first start. If this machine was commissioned, the
        capture is incomplete -- check it before starting reflex-ui."
	fi

	# --- SHOW THE HUMAN WHAT IS ABOUT TO LAND ---------------------------------
	# The checkable claim is "these files were copied". The claim that MATTERS is
	# "these are the right numbers", and only a human who knows the machine can
	# make it. So print the values rather than assert on them.
	printf '\n  the commissioned values in this capture:\n'
	if [ -r "${SRC}/Els-0.yaml" ]; then
		grep -E '^(els_backlash_steps|els_cal_last_measured_steps|els_cal_ceiling_steps|els_cal_drift_notice_steps):' \
			"${SRC}/Els-0.yaml" 2>/dev/null | sed 's/^/      /'
	fi
	if [ -d "${SRC}/diag" ]; then
		say "  diag/ present ($(find "${SRC}/diag" -type f | wc -l) file(s))"
	fi
	printf '\n'

	# --- restore ---------------------------------------------------------------
	# Root from here on, and only from here on: everything above only READ.
	need_root
	resolve_service_user

	# Existing config is MOVED ASIDE, never overwritten in place. If this run is
	# wrong, the previous state is still on the disk.
	if [ -d "${CONFIG_DIR}" ] && [ -n "$(ls -A "${CONFIG_DIR}" 2>/dev/null)" ]; then
		ASIDE="${CONFIG_DIR}.pre-restore-$(date +%Y%m%d-%H%M%S)"
		warn "${CONFIG_DIR} is not empty -- moving it to ${ASIDE}"
		run mv "${CONFIG_DIR}" "${ASIDE}"
	fi

	run install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0755 "${CONFIG_DIR}"
	run cp -a "${SRC}/." "${CONFIG_DIR}/"
	run chown -R "${SERVICE_USER}:${SERVICE_USER}" "${CONFIG_DIR}"

	# --- POST-WRITE CHECKS ------------------------------------------------------
	assert "${CONFIG_DIR}/Els-0.yaml restored and non-empty" test -s "${CONFIG_DIR}/Els-0.yaml"
	assert "${CONFIG_DIR} owned by ${SERVICE_USER}" \
		bash -c "[ \"\$(stat -c %U '${CONFIG_DIR}')\" = '${SERVICE_USER}' ]"

	# The app WRITES here at runtime (current_mode, calibration). Read-only would
	# look fine until the first write.
	assert "${CONFIG_DIR} is writable by ${SERVICE_USER}" \
		sudo -u "${SERVICE_USER}" test -w "${CONFIG_DIR}"

	if [ "${DRY_RUN}" != "1" ]; then
		RESTORED="$(find "${CONFIG_DIR}" -maxdepth 1 -name '*.yaml' | wc -l)"
		[ "${RESTORED}" -eq "${NYAML}" ] \
			|| die "restored ${RESTORED} yaml files but the source had ${NYAML}"
		ok "${RESTORED} yaml files restored, count matches the source"
	fi
fi

# --- firmware manifest: SOFT, and says so -----------------------------------
# docs/design/seam.md: "~/firmware/flashed.json if available (soft -- its loss costs
# knowledge, not function)".
# need_root/resolve_service_user are called again here (harmless if already
# done above) because --fresh with no firmware never calls them at all, and
# this is the one place that writes regardless of which path was taken.
if [ -n "${FIRMWARE}" ]; then
	if [ -s "${FIRMWARE}" ]; then
		need_root
		resolve_service_user
		HOME_DIR="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
		run install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0755 "${HOME_DIR}/firmware"
		run install -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0644 \
			"${FIRMWARE}" "${HOME_DIR}/firmware/flashed.json"
		assert "flashed.json restored" test -s "${HOME_DIR}/firmware/flashed.json"
	else
		warn "--firmware ${FIRMWARE} is missing or empty; skipping (soft by design)"
	fi
else
	warn "no --firmware given. flashed.json records WHAT IS ON THE STM32; without
        it that is unknown until something re-reads the board. Soft by design."
fi

printf '\n'
if [ "${FRESH}" = "1" ]; then
	uncommissioned_banner
else
	ok "restore complete -- from ${SRC}"
	say "the values printed above are what this machine will use. If they are not"
	say "what you expect, stop now: nothing else in provisioning will notice."
fi
