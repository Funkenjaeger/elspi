#!/bin/bash
# elspi-first-boot-ui -- the RUNTIME half of the first-boot-into-the-UI hook
# (the goal: a fresh elspi card boots straight into the UI, with no SSH and
# no mandatory backup).
#
# WHAT THIS ACTUALLY DOES TODAY: nothing visible. It looks for a reflex
# checkout at the path the image's own manifest declares
# (/etc/elspi-image.json .paths.app_root). Since the 2026-09-21 seam amendment
# the image DOES bake one there (stage-elspi/10a-app-checkout), so every card
# built since then finds it -- and this script's converge/start branch has not
# been written yet. It therefore logs verdict=UNIMPLEMENTED, names that
# branch as the missing piece, and exits 0. Images built before 2026-09-21
# carried no checkout and log verdict=NOOP instead.
#
# THIS IS A NO-OP BY DESIGN, NOT A BUG. Starting the application unattended
# is a separate decision from baking it in -- the manifest declares
# baked_app.started_on_first_boot=false, and starting reflex-ui stays a
# deliberate step of provisioning (docs/provisioning.md). See
# stage-elspi/14-first-boot-ui/README.md for what would need to change to turn
# this into something that starts reflex-ui unattended.
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
# absence (an image built before 2026-09-21) is not a failure.
if [ ! -d "${APP_ROOT}" ]; then
	log "verdict=NOOP reason='no checkout at ${APP_ROOT} -- an image built before the app was baked in; nothing to converge or start.'"
	record NOOP
	exit 0
fi

# A checkout exists -- every image built since 2026-09-21 -- and this
# script's converge/start branch still needs writing. Say so loudly in the
# journal: silently doing nothing with a checkout present would look identical
# to the NOOP case above, and the two are not the same finding.
log "verdict=UNIMPLEMENTED reason='a checkout exists at ${APP_ROOT} but the converge/start branch has not been written yet -- see stage-elspi/14-first-boot-ui/README.md in the elspi repository'"
record UNIMPLEMENTED
exit 0
