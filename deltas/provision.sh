#!/bin/bash
# Run the three delta phases in order.
#
#   provision.sh --app <checkout> --config-backup <dir|tarball> [--firmware F]
#                [--drm-mode MODE] [--dry-run] [--skip-interactive]
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

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

APP="" ; BACKUP="" ; FIRMWARE="" ; DRM_MODE="first-opener"
SKIP_INTERACTIVE=0 ; PASS_DRY=""

while [ $# -gt 0 ]; do
	case "$1" in
		--app)              APP="${2:-}"; shift 2 ;;
		--config-backup)    BACKUP="${2:-}"; shift 2 ;;
		--firmware)         FIRMWARE="${2:-}"; shift 2 ;;
		--drm-mode)         DRM_MODE="${2:-}"; shift 2 ;;
		--skip-interactive) SKIP_INTERACTIVE=1; shift ;;
		--dry-run)          DRY_RUN=1; PASS_DRY="--dry-run"; shift ;;
		-h|--help)          sed -n '2,20p' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

need_root

printf '\n\033[1melspi delta provisioning\033[0m\n'
[ "${DRY_RUN}" = "1" ] && say "DRY RUN -- nothing will be changed"

# Fail on missing arguments HERE, before phase 1 does half the work and phase 2
# then refuses. A run that converges and then cannot restore leaves a machine
# with an enabled unit and no commissioned data, which is the state most likely
# to get started by accident.
[ -n "${APP}" ]    || die "--app is required"
[ -n "${BACKUP}" ] || die "--config-backup is required.

  Checked up front on purpose: without it phase 2 would refuse anyway, but only
  AFTER phase 1 had enabled the service. A machine with an enabled unit and no
  commissioned config is the one most likely to get started by mistake."
[ -e "${BACKUP}" ] || die "--config-backup ${BACKUP} does not exist"

"${HERE}/01-converge.sh" --app "${APP}" --drm-mode "${DRM_MODE}" ${PASS_DRY} \
	|| die "phase 1 (converge) failed -- stopping. Nothing was restored."

"${HERE}/02-restore.sh" --config-backup "${BACKUP}" \
	${FIRMWARE:+--firmware "${FIRMWARE}"} ${PASS_DRY} \
	|| die "phase 2 (restore) failed -- stopping. The service is enabled but has
  no commissioned config. DO NOT START IT until this is resolved."

if [ "${SKIP_INTERACTIVE}" = "1" ]; then
	warn "phase 3 skipped by request. The account may still be LOCKED and this"
	warn "  machine may be outside the evidence perimeter (item 19)."
else
	# --app is passed to phase 3 the same way it is to phase 1. Phase 3 never
	# writes there -- it reports whether the firmware sources (<app>/fw since
	# the monorepo weld) landed. Passing it beats phase 3 guessing the path,
	# and beats hardcoding this machine's.
	"${HERE}/03-interactive.sh" --app "${APP}" ${PASS_DRY} \
		|| warn "phase 3 did not complete. Re-run it alone: ./03-interactive.sh --app ${APP}"
fi

phase "Provisioning finished"
say "The application is NOT running. Before starting it:"
say "  1. re-read the commissioned values phase 2 printed"
say "  2. systemctl start reflex-ui"
say "  3. watch it: journalctl -u reflex-ui -f"
say ""
say "If the UI does not appear, the DRM mode is the first suspect. The ladder,"
say "Plymouth first, is in FLASH-SESSION.md -- and elspi-drm-mode switches"
say "mechanism in one command without a reflash."
