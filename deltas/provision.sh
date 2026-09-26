#!/bin/bash
# Run the three delta phases in order.
#
#   provision.sh --app <checkout> (--config-backup <dir|tarball> | --fresh)
#                [--firmware F] [--drm-mode MODE] [--site-hooks DIR]
#                [--dry-run] [--skip-interactive]
#
# This is a CONVENIENCE, not a merge. The phases keep their own contracts and
# their own exit codes, and a failure stops everything after it -- the ordering
# is load-bearing:
#
#   converge before restore, because restore needs the service user's
#   ownership to be settled;
#   restore before the app is ever STARTED, because starting first means coming
#   up on whatever /var/lib/reflex-config happens to hold -- which after a
#   fresh flash is nothing;
#   interactive last, because it is the only phase that cannot run unattended
#   and there is no reason to make a human wait on the other two.
#
# The app is NOT started by any of this. Starting it is a deliberate act after
# a human has looked at the restored values -- see the end of phase 2.
#
# --- FIRST COMMISSIONING: --fresh -------------------------------------------
# A brand-new machine has no backup to restore. --fresh names that on
# purpose, as a deliberate, loud choice rather than a guess:
#
#   * mutually exclusive with --config-backup -- naming both dies naming both;
#   * skips phase 2's restore entirely: no files are written into CONFIG_DIR,
#     nothing is generated, the application's own defaults apply;
#   * refuses if CONFIG_DIR already holds anything, so a fresh provision can
#     never mask existing commissioned data -- use --config-backup, or move
#     the directory aside first;
#   * says so LOUDLY: an UNCOMMISSIONED banner at the start of phase 2 and
#     again in its final summary, because axis geometry, servo polarity,
#     backlash calibration and Z scale counts/mm are commissioned machine
#     data that nothing here can generate, and every one of them must be
#     measured off the physical lathe before this machine is trusted.
#
# With NEITHER flag, provisioning refuses exactly as it always has -- see
# 02-restore.sh's contract. --fresh is a deliberate choice, never a default.
#
# --- SITE HOOKS -------------------------------------------------------------
# --site-hooks DIR is the seam for everything that is true of ONE estate and
# not of the image. Nothing machine-specific lives in this repo (item 13), so
# a step that names a particular network, collector or backup host cannot be a
# phase -- but it still has to run in the same order, with the same helpers,
# right after the phases. It runs as a hook out of a directory OUTSIDE this
# tree.
#
# Every executable DIR/*.sh runs, in sorted filename order, as root, each with
# DELTAS_DIR, SERVICE_USER, HOME_DIR, APP_DIR, CONFIG_DIR and DRY_RUN
# exported. DELTAS_DIR is there so a hook can `. "${DELTAS_DIR}/lib.sh"` and
# get say/ok/warn/die/run/assert -- the point being that a hook should look
# like a phase and honour --dry-run through the same `run` wrapper.
#
# A hook that exits non-zero STOPS provisioning, named. Hooks run last on
# purpose: a site step that fails must not be able to leave a half-converged
# machine behind it.
#
# DIR/site.env is the other half: SETTINGS the phases read, as opposed to steps
# that run after them -- ELSPI_<NAME>=<value> lines, parsed as data (never
# sourced) and exported before phase 1. ELSPI_RESTORE_MIN_YAML there raises
# phase 2's content bar above the public minimum. See lib.sh load_site_env.
#
# The contract is in deltas/README.md. This repo ships no hooks.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

APP="" ; BACKUP="" ; FRESH=0 ; FIRMWARE="" ; DRM_MODE="first-opener"
SKIP_INTERACTIVE=0 ; PASS_DRY="" ; SITE_HOOKS=""

while [ $# -gt 0 ]; do
	case "$1" in
		--app)              APP="${2:-}"; shift 2 ;;
		--config-backup)    BACKUP="${2:-}"; shift 2 ;;
		--fresh)            FRESH=1; shift ;;
		--firmware)         FIRMWARE="${2:-}"; shift 2 ;;
		--drm-mode)         DRM_MODE="${2:-}"; shift 2 ;;
		# Checked HERE rather than at the hook phase, which is the last thing
		# that runs: a typo in this path must not be discovered after converge
		# and restore have already changed the machine.
		--site-hooks)       SITE_HOOKS="${2:-}"
		                    [ -n "${SITE_HOOKS}" ] || die "--site-hooks needs a directory"
		                    [ -d "${SITE_HOOKS}" ] || die "--site-hooks ${SITE_HOOKS} is not a directory that exists"
		                    shift 2 ;;
		--skip-interactive) SKIP_INTERACTIVE=1; shift ;;
		--dry-run)          DRY_RUN=1; PASS_DRY="--dry-run"; shift ;;
		-h|--help)          sed -n '2,60p' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

# A site's SETTINGS (not its hooks): <hooks dir>/site.env, exported before
# phase 1 so every phase sees them -- ELSPI_RESTORE_MIN_YAML is the one phase
# 2 reads. Loaded before need_root because it only reads, and so a malformed
# line is refused before anything is asked of root.
if [ -n "${SITE_HOOKS}" ]; then
	load_site_env "${SITE_HOOKS}"
fi

printf '\n\033[1melspi delta provisioning\033[0m\n'
[ "${DRY_RUN}" = "1" ] && say "DRY RUN -- nothing will be changed"

# Fail on missing arguments HERE, before phase 1 does half the work and phase 2
# then refuses. A run that converges and then cannot restore leaves a machine
# with an enabled unit and no commissioned data, which is the state most likely
# to get started by accident.
[ -n "${APP}" ] || die "--app is required"

# --fresh and --config-backup name mutually exclusive choices -- first
# commissioning versus recovery -- and naming both at once does not resolve
# which one is meant. Checked here, before phase 1, for the same reason the
# missing-argument check below is: a machine with an enabled unit and no
# commissioned config, and now also no clear intent, is not a state to leave
# phase 1 to discover.
if [ "${FRESH}" = "1" ] && [ -n "${BACKUP}" ]; then
	die "--fresh and --config-backup are mutually exclusive.

  --fresh names first commissioning: no backup exists yet, and none should be
  applied. --config-backup names recovery: a capture exists and should be
  restored. Naming both does not say which one you mean."
fi

if [ "${FRESH}" != "1" ]; then
	[ -n "${BACKUP}" ] || die "--config-backup is required (or pass --fresh for a brand-new machine).

  Checked up front on purpose: without it phase 2 would refuse anyway, but only
  AFTER phase 1 had enabled the service. A machine with an enabled unit and no
  commissioned config is the one most likely to get started by mistake."
	[ -e "${BACKUP}" ] || die "--config-backup ${BACKUP} does not exist"
fi

# --fresh ON A CARD THAT ALREADY HOLDS CONFIG, refused HERE rather than in
# phase 2. 02-restore.sh --fresh refuses a non-empty CONFIG_DIR too, and stays
# the authority on that rule; this is the same read, taken before phase 1 has
# re-converged the machine as root. Since 2026-09-26 it is the COMMON case, not
# a corner: a fresh card converges and starts the UI at first boot
# (stage-elspi/14-first-boot-ui), and the running app writes its own
# commissioning ledger into CONFIG_DIR at startup -- so by the time anyone runs
# provision.sh --fresh, first commissioning has already begun on the
# touchscreen. A pure read (resolve_paths reads the image manifest), so it sits
# ahead of need_root with the other argument gates.
if [ "${FRESH}" = "1" ]; then
	resolve_paths
	if [ -d "${CONFIG_DIR}" ] && [ -n "$(ls -A "${CONFIG_DIR}" 2>/dev/null)" ]; then
		die "--fresh refused: ${CONFIG_DIR} already holds config.

  --fresh names FIRST commissioning, and this machine is past it: something
  has already written to ${CONFIG_DIR}. On a card that booted straight into
  the UI (images since 2026-09-26) that is the application itself -- first
  boot already converged it, and commissioning continues on the touchscreen
  (Setup, or the UNCOMMISSIONED strip's restore). Nothing here would add to
  that. To restore a capture instead, use --config-backup (it moves the
  current directory aside first). Checked BEFORE phase 1, so nothing on this
  machine was changed."
	fi
fi

# PURE VALIDATION FIRST -- every check above only READS the arguments already
# parsed; nothing above writes. need_root moves to here, after all of them, so
# a non-root caller gets refused for the SAME reason any caller would be (a
# missing --app, mutually-exclusive flags, a missing backup) instead of a root
# refusal that masks which of those is actually wrong -- matching the rule
# deltas/02-restore.sh states at :72. load_site_env (above, :100-102) was
# already before need_root even before this change, for the same reason.
need_root

"${HERE}/01-converge.sh" --app "${APP}" --drm-mode "${DRM_MODE}" ${PASS_DRY} \
	|| die "phase 1 (converge) failed -- stopping. Nothing was restored."

# --- A UI ALREADY ON THE SCREEN IS STOPPED BEFORE PHASE 2 --------------------
# The ordering this script's header calls load-bearing -- restore before the
# app is ever STARTED -- no longer holds by itself: since 2026-09-26 a fresh
# card converges and starts reflex-ui at first boot, UNCOMMISSIONED
# (stage-elspi/14-first-boot-ui). Restoring underneath a running app is not
# harmless. The app latched "uncommissioned" when it started and keeps its
# in-memory DEFAULTS; if the operator has dismissed the UNCOMMISSIONED
# warning, its write gate is open, and its next save writes those defaults
# over the geometry phase 2 just restored. So it is stopped first, said out
# loud, and the stop is gated on systemd's own answer. It is NOT restarted
# here: starting it stays the deliberate step at the end of this script.
UI_WAS_RUNNING=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet reflex-ui.service 2>/dev/null; then
	UI_WAS_RUNNING=1
	warn "reflex-ui is RUNNING (a card that booted straight into the UI starts it at"
	warn "  first boot). Stopping it before phase 2, so nothing the app holds in memory"
	warn "  can be written over what phase 2 puts in place."
	run systemctl stop reflex-ui.service
	if [ "${DRY_RUN}" != "1" ]; then
		if systemctl is-active --quiet reflex-ui.service 2>/dev/null; then
			die "reflex-ui is still active after 'systemctl stop'. Refusing to run phase 2
  underneath a running application. Stop it by hand and re-run."
		fi
		ok "reflex-ui stopped (systemd reports it inactive)"
	fi
fi

if [ "${FRESH}" = "1" ]; then
	"${HERE}/02-restore.sh" --fresh \
		${FIRMWARE:+--firmware "${FIRMWARE}"} ${PASS_DRY} \
		|| die "phase 2 (fresh commissioning) failed -- stopping. The service is
  enabled but has no commissioned config. DO NOT START IT until this is resolved."
else
	"${HERE}/02-restore.sh" --config-backup "${BACKUP}" \
		${FIRMWARE:+--firmware "${FIRMWARE}"} ${PASS_DRY} \
		|| die "phase 2 (restore) failed -- stopping. The service is enabled but has
  no commissioned config. DO NOT START IT until this is resolved."
fi

if [ "${SKIP_INTERACTIVE}" = "1" ]; then
	warn "phase 3 skipped by request. The account may still be LOCKED, and"
	warn "  nothing that phase asks a human for has been set."
else
	# --app is passed to phase 3 the same way it is to phase 1. Phase 3 never
	# writes there -- it reports whether the firmware sources (<app>/fw since
	# the monorepo weld) landed. Passing it beats phase 3 guessing the path,
	# and beats hardcoding this machine's.
	"${HERE}/03-interactive.sh" --app "${APP}" ${PASS_DRY} \
		|| warn "phase 3 did not complete. Re-run it alone: ./03-interactive.sh --app ${APP}"
fi

# --- site hooks -------------------------------------------------------------
# Runs whether or not phase 3 was skipped: --skip-interactive is about not
# blocking on a human, and a site step may well have nothing to ask.
if [ -z "${SITE_HOOKS}" ]; then
	say "no site hooks (none given)"
else
	# --maxdepth 1, not recursive: a hooks directory sitting beside the
	# payload directory its hooks install from is the normal shape, and those
	# payloads are not hooks. Sorted under LC_ALL=C so the order is the
	# filename order a human reading `ls` sees, on every machine.
	SITE_HOOK_LIST=()
	while IFS= read -r _h; do
		[ -x "${_h}" ] && SITE_HOOK_LIST+=("${_h}")
	done < <(find "${SITE_HOOKS}" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)

	phase "Site hooks (${#SITE_HOOK_LIST[@]})"

	if [ "${#SITE_HOOK_LIST[@]}" -eq 0 ]; then
		# Said out loud rather than passed over. A hooks directory that
		# matched nothing is usually a lost executable bit, and a silent
		# no-op there looks exactly like a hook that ran and found nothing
		# to do.
		warn "${SITE_HOOKS} holds no executable *.sh -- nothing ran."
		warn "  A lost executable bit looks identical to a hook with nothing"
		warn "  to do. Check: ls -l ${SITE_HOOKS}"
	else
		# The environment every hook gets, and the only environment it may
		# assume. Resolved here rather than in each hook so a hook cannot
		# disagree with the phases about who the service user is.
		resolve_service_user            # SERVICE_USER
		resolve_paths                   # CONFIG_DIR (and VENV, LOG_DIR, APP_ROOT)
		HOME_DIR="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
		if [ -d "${APP}" ]; then APP_DIR="$(cd "${APP}" && pwd)"; else APP_DIR="${APP}"; fi
		DELTAS_DIR="${HERE}"
		export DELTAS_DIR SERVICE_USER HOME_DIR APP_DIR CONFIG_DIR DRY_RUN

		[ "${DRY_RUN}" = "1" ] && say "DRY RUN -- DRY_RUN=1 is exported; each hook is responsible for honouring it"

		for _h in "${SITE_HOOK_LIST[@]}"; do
			if [ "${DRY_RUN}" = "1" ]; then
				say "would run (with DRY_RUN=1): ${_h}"
			else
				say "running: ${_h}"
			fi
			# A failing hook stops everything after it, named. Hooks are last,
			# so nothing is left half-done by the stop itself.
			"${_h}" || die "site hook FAILED: ${_h}
  Provisioning stopped. The phases completed; this hook did not."
		done
		ok "all ${#SITE_HOOK_LIST[@]} site hook(s) completed"
	fi
fi

phase "Provisioning finished"
if [ "${FRESH}" = "1" ]; then
	warn "UNCOMMISSIONED: no config was restored. See phase 2's banner above --"
	warn "  axis geometry, servo polarity, backlash and Z scale must be measured"
	warn "  before this machine is trusted."
fi
if [ "${UI_WAS_RUNNING}" = "1" ]; then
	warn "reflex-ui was running when provisioning began and was STOPPED before phase 2."
	warn "  It is enabled, so it will also start on the next boot."
fi
say "The application is NOT running. Before starting it:"
say "  1. re-read the commissioned values phase 2 printed"
say "  2. systemctl start reflex-ui"
say "  3. watch it: journalctl -u reflex-ui -f"
say ""
say "If the UI does not appear, the DRM mode is the first suspect. The ladder,"
say "Plymouth first, is in docs/provisioning.md -- and elspi-drm-mode switches"
say "mechanism in one command without a reflash."
