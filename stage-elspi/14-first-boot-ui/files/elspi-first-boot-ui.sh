#!/bin/bash
# elspi-first-boot-ui -- the RUNTIME half of the hook for task 6aa73b01 item 1
# ("make a fresh elspi card boot straight into the UI: no SSH, no mandatory
# backup, SWD chapter documented").
#
# WHAT THIS ACTUALLY DOES TODAY: nothing visible. It looks for a reflex
# checkout at the path the image's own manifest declares
# (/etc/elspi-image.json .paths.app_root) and, finding none -- which is true
# of every image this repo has ever built, because docs/design/seam.md keeps
# the application checkout deltas-owned (see 11-manifest's
# delta_layer_owns declaration) -- logs a clear, named verdict and exits 0.
#
# THIS IS A NO-OP BY DESIGN, NOT A BUG. Baking a checkout into the image and
# converging it automatically here is a change to the RATIFIED image-vs-deltas
# seam, and that decision belongs to Evan, not to this build. See
# stage-elspi/14-first-boot-ui/README.md for the full reasoning and exactly
# what would need to change to turn this into something that starts
# reflex-ui unattended.
#
# CONTRACT (checked by both this script's own post-write gate in 00-run.sh and
# by tests/verify-image.sh):
#   - never fails the boot (the unit's ExecStart is '-'-prefixed; this script
#     also always exits 0);
#   - no interactive step of any kind -- no `read`, no prompt, ever;
#   - idempotent -- safe to run every boot;
#   - every branch gates on a signal that could have come out differently,
#     and says which signal it read.

set -uo pipefail

MANIFEST=/etc/elspi-image.json
STATE_DIR=/etc/elspi
VERDICT_FILE="${STATE_DIR}/first-boot-ui-verdict"

log() { echo "elspi-first-boot-ui: $*"; }

install -d -m 0755 "${STATE_DIR}" 2>/dev/null || true
record() { printf '%s\n' "$1" > "${VERDICT_FILE}" 2>/dev/null || true; }

if ! command -v python3 >/dev/null 2>&1 || [ ! -f "${MANIFEST}" ]; then
	log "verdict=UNKNOWN reason='cannot read ${MANIFEST} (missing, or no python3)'"
	record UNKNOWN
	exit 0
fi

APP_ROOT="$(python3 -c "import json; print(json.load(open('${MANIFEST}'))['paths']['app_root'])" 2>/dev/null || true)"
if [ -z "${APP_ROOT}" ]; then
	log "verdict=UNKNOWN reason='manifest has no paths.app_root'"
	record UNKNOWN
	exit 0
fi

# GATE: the one signal this whole script exists to read. A checkout baked
# into the image is what a future converge/start branch would need; its
# absence is not a failure, it is the current, ratified state of the seam.
if [ ! -d "${APP_ROOT}" ]; then
	log "verdict=NOOP reason='no checkout at ${APP_ROOT} -- expected today. The application is deltas-owned (docs/design/seam.md); nothing to converge or start.'"
	record NOOP
	exit 0
fi

# A checkout exists. No image this repo has built has ever produced one, so
# reaching here means the seam decision in task 6aa73b01 item 1 has been made
# and this script's converge/start branch still needs writing. Refuse loudly
# to the journal -- silently doing nothing with a checkout present would look
# identical to the expected NOOP case above, and the two are not the same
# finding.
log "verdict=UNIMPLEMENTED reason='a checkout exists at ${APP_ROOT} but the converge/start branch has not been written yet -- see task 6aa73b01 item 1 and stage-elspi/14-first-boot-ui/README.md'"
record UNIMPLEMENTED
exit 0
