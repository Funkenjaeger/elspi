#!/bin/bash
# PHASE 2 -- RESTORE. Refuses to invent data.
#
#   02-restore.sh --config-backup <dir|tarball> [--firmware <flashed.json>] [--dry-run]
#
# Checklist item 14, and the one contract docs/design/seam.md says must not be softened:
#
#   "Provisioning must RESTORE the commissioned config from backup, never
#    generate it -- and must fail loudly rather than silently coming up with
#    defaults if no backup is available."
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
# WHY IT CANNOT FETCH THE BACKUP ITSELF. It would have to know where dserver
# is, and item 13 forbids anything machine-specific in this repo. You bring the
# backup to the Pi; this phase refuses to proceed without it.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

BACKUP=""
FIRMWARE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--config-backup) BACKUP="${2:-}"; shift 2 ;;
		--firmware)      FIRMWARE="${2:-}"; shift 2 ;;
		--dry-run)       DRY_RUN=1; shift ;;
		*) die "unknown argument: $1" ;;
	esac
done

phase "Phase 2: RESTORE the commissioned config"

need_root
resolve_service_user
resolve_paths

# --- THE CONTRACT -----------------------------------------------------------
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

  Bring the most recent capture to this Pi and pass it:
      --config-backup /path/to/elspi-reflex-config-YYYY-MM-DD
  On dserver these live in ~/backups/elspi/ . CHECK THE DATE -- a stale
  capture restores stale geometry, which is the failure this text exists for."
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

# --- GATE ON THE CONTENT, NOT THE PATH --------------------------------------
# An empty or wrong directory that restored "successfully" is the failure mode
# this whole phase exists to prevent, and it is indistinguishable from success
# unless something looks inside.
[ -s "${SRC}/Els-0.yaml" ] \
	|| die "no non-empty Els-0.yaml in ${SRC} -- that is the commissioned ELS
  geometry, and a capture without it is not a restore point. REFUSING."

NYAML="$(find "${SRC}" -maxdepth 1 -name '*.yaml' | wc -l)"
[ "${NYAML}" -ge 15 ] \
	|| die "only ${NYAML} yaml file(s) in ${SRC}; the live machine carried 19 at
  last count. This looks like a partial capture. REFUSING rather than
  restoring a subset over a machine that needs all of it."
ok "${NYAML} yaml files, Els-0.yaml present and non-empty"

# --- SHOW THE HUMAN WHAT IS ABOUT TO LAND -----------------------------------
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

# --- restore ----------------------------------------------------------------
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

# --- firmware manifest: SOFT, and says so -----------------------------------
# docs/design/seam.md: "~/firmware/flashed.json if available (soft -- its loss costs
# knowledge, not function)".
if [ -n "${FIRMWARE}" ]; then
	if [ -s "${FIRMWARE}" ]; then
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
ok "restore complete -- from ${SRC}"
say "the values printed above are what this machine will use. If they are not"
say "what you expect, stop now: nothing else in provisioning will notice."
