#!/bin/bash
# elspi-first-boot-ui -- a fresh elspi card boots straight into the UI.
#
# WHAT THIS DOES, ONCE, on the first boot after the seed
# (elspi-first-boot-seed.service) and after Plymouth has let go of DRM master:
#
#   1. finds the reflex checkout the image baked in (/etc/elspi-image.json
#      .paths.app_root; stage-elspi/10a-app-checkout put it there);
#   2. asks /usr/local/lib/elspi/commissioning-guard whether that release
#      carries reflex's COMMISSIONING GUARD -- the UNCOMMISSIONED strip and the
#      write gate behind it. No guard, no start: starting a release without it
#      would come up on silent defaults, which docs/design/seam.md's 2026-09-21
#      amendment forbids by name;
#   3. runs the image's own copy of the delta layer's CONVERGE phase
#      (/usr/local/lib/elspi/deltas/01-converge.sh --app <checkout>) --
#      OFFLINE (UV_OFFLINE=1): stage-elspi/10b-app-install already installed
#      the app into the venv at build time and proved an offline re-sync
#      succeeds, so first boot needs no network at all, exactly like recovery;
#   4. starts reflex-ui.service, which converge has just enabled.
#
# It never RESTORES anything and never writes /var/lib/reflex-config. With that
# directory empty -- true of every fresh card -- the application itself shows
# UNCOMMISSIONED on the home screen and saves nothing until a backup is
# restored (USB import on the Setup screen, or deltas/provision.sh
# --config-backup) or the operator dismisses the warning to commission by hand.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   * run phase 2 (restore) or phase 3 (interactive). Restore is an action a
#     human takes with a capture in hand; phase 3 needs a terminal.
#   * run more than once. Success writes /etc/elspi/first-boot-ui-done; every
#     later boot is systemd starting the ENABLED reflex-ui.service by itself,
#     and this hook only says so. A human who later stops or disables the UI
#     is never overruled by it.
#   * touch a card somebody already provisioned. If reflex-ui.service is
#     already enabled when this runs, it records that and does nothing else.
#
# CONTRACT (checked by stage-elspi/14-first-boot-ui/00-run.sh, by
# tests/verify-image.sh against the rootfs, and by tests/test-first-boot-ui.sh
# against this script itself):
#   - never fails the boot (the unit's ExecStart is '-'-prefixed, and this
#     script always exits 0);
#   - no interactive step of any kind -- no `read`, no prompt, ever;
#   - every branch gates on a signal that could have come out differently,
#     logs one `verdict=` line naming it, and records the verdict in
#     /etc/elspi/first-boot-ui-verdict.
#
# ELSPI_FBUI_TEST_ROOT is FOR tests/test-first-boot-ui.sh ONLY: it prefixes
# every FILE path this script reads or writes. Commands (systemctl, timeout)
# are found on PATH, which is how the test substitutes shims. On a card it is
# unset and every path is the real one.

set -uo pipefail

R="${ELSPI_FBUI_TEST_ROOT:-}"
MANIFEST="${R}/etc/elspi-image.json"
STATE_DIR="${R}/etc/elspi"
VERDICT_FILE="${STATE_DIR}/first-boot-ui-verdict"
DONE_MARKER="${STATE_DIR}/first-boot-ui-done"
LIBDIR="${R}/usr/local/lib/elspi"
GUARD="${LIBDIR}/commissioning-guard"
CONVERGE="${LIBDIR}/deltas/01-converge.sh"
UNIT=reflex-ui.service

# Converge on a Pi 5 takes well under a minute (an offline uv sync that finds
# everything installed, a handful of installs and checks). The bound exists so
# a hung step cannot hold this oneshot forever; it is not a performance target.
CONVERGE_TIMEOUT="${ELSPI_FBUI_CONVERGE_TIMEOUT:-900}"
# How long to watch for the started unit to report active before saying so.
START_WAIT="${ELSPI_FBUI_START_WAIT:-60}"

log() { echo "elspi-first-boot-ui: $*"; }

install -d -m 0755 "${STATE_DIR}" 2>/dev/null || true
record() { printf '%s\n' "$1" > "${VERDICT_FILE}" 2>/dev/null || true; }
finish() { # finish <VERDICT> <reason>
	log "verdict=$1 reason='$2'"
	record "$1"
	exit 0
}

# --- already done on an earlier boot -----------------------------------------
# Checked FIRST, before anything else is read: after first boot this hook's
# only job is to say it has nothing to do. The verdict file is left as the
# first boot wrote it -- that is the record worth keeping.
if [ -e "${DONE_MARKER}" ]; then
	log "verdict=DONE_EARLIER reason='first boot already converged and started the UI ($(cat "${DONE_MARKER}" 2>/dev/null || echo 'no detail')); reflex-ui.service is enabled and systemd starts it on every boot. Nothing to do.'"
	exit 0
fi

# --- where is the app? -------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "${MANIFEST}" ]; then
	finish UNKNOWN "cannot read ${MANIFEST} (missing, or no python3)"
fi
APP_ROOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["app_root"])' "${MANIFEST}" 2>/dev/null || true)"
[ -n "${APP_ROOT}" ] || finish UNKNOWN "manifest has no paths.app_root"
APP="${R}${APP_ROOT}"

# An image built before 2026-09-21 carried no checkout. Not a failure: there
# is simply nothing to start, and provisioning by hand is the path.
[ -d "${APP}" ] || finish NOOP "no checkout at ${APP_ROOT} -- an image built before the app was baked in; provision by hand (docs/provisioning.md)"

# --- the safety gate: does this release carry the commissioning guard? -------
[ -x "${GUARD}" ] || finish UNKNOWN "${GUARD#"${R}"} is missing -- the image did not install the guard check, so the app is NOT started"
GUARD_ANSWER="$("${GUARD}" "${APP}" 2>/dev/null)"
case "${GUARD_ANSWER}" in
	yes) log "commissioning guard: present in the baked release (it will show UNCOMMISSIONED until a restore or a deliberate dismissal)" ;;
	no)  finish REFUSED_NO_GUARD "the release at ${APP_ROOT} predates reflex's commissioning guard (v1.2.0-rc.5); started unattended it would run on silent defaults, which docs/design/seam.md (amendment 2026-09-21) forbids. NOT started -- provision by hand (docs/provisioning.md)" ;;
	*)   finish UNKNOWN "commissioning-guard could not judge ${APP_ROOT} (answer '${GUARD_ANSWER}'); NOT started" ;;
esac

# --- a card somebody already provisioned is left alone ----------------------
if systemctl is-enabled --quiet "${UNIT}" 2>/dev/null; then
	printf 'already-enabled %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" > "${DONE_MARKER}" 2>/dev/null || true
	finish ALREADY_PROVISIONED "${UNIT} was already enabled before this hook ran -- somebody provisioned this card; it is theirs, and systemd starts the enabled unit by itself"
fi

# --- converge, offline -------------------------------------------------------
[ -x "${CONVERGE}" ] || finish UNKNOWN "${CONVERGE#"${R}"} is missing or not executable -- the image did not bake the delta layer in; NOT started"

# A private uv cache on tmpfs: converge's `uv sync --frozen` must find
# everything already installed (10b-app-install proved that at build time
# with an empty cache and the network off), so the cache stays empty; and a
# system service has no HOME worth writing into anyway.
UV_TMP="$(mktemp -d "${R}/run/elspi-first-boot-ui-uv.XXXXXX" 2>/dev/null || mktemp -d)"
log "running converge (offline): ${CONVERGE#"${R}"} --app ${APP_ROOT}"
env UV_OFFLINE=1 UV_CACHE_DIR="${UV_TMP}" UV_PYTHON_DOWNLOADS=never \
	timeout "${CONVERGE_TIMEOUT}" "${CONVERGE}" --app "${APP_ROOT}" 2>&1 \
	| sed 's/^/elspi-first-boot-ui: converge: /'
CONVERGE_RC="${PIPESTATUS[0]}"
rm -rf "${UV_TMP}" 2>/dev/null || true

if [ "${CONVERGE_RC}" -ne 0 ]; then
	# Converge enables the unit part-way through; a converge that then failed
	# must not leave a unit the NEXT boot would start half-wired. It was not
	# enabled when this hook began (checked above), so disabling it restores
	# exactly the state found. No DONE marker: the next boot tries again
	# (converge is idempotent and retryable by contract).
	if systemctl is-enabled --quiet "${UNIT}" 2>/dev/null; then
		systemctl disable "${UNIT}" >/dev/null 2>&1 || true
		log "converge failed after enabling ${UNIT}; disabled it again so the next boot does not start a half-converged app"
	fi
	[ "${CONVERGE_RC}" -eq 124 ] && finish CONVERGE_FAILED "converge did not finish within ${CONVERGE_TIMEOUT}s; NOT started (read the converge: lines above; retried next boot)"
	finish CONVERGE_FAILED "converge exited ${CONVERGE_RC}; NOT started (read the converge: lines above; retried next boot)"
fi

# The gate converge's success is supposed to imply, read back from systemd.
if ! systemctl is-enabled --quiet "${UNIT}" 2>/dev/null; then
	finish CONVERGE_FAILED "converge exited 0 but ${UNIT} is not enabled -- NOT started"
fi

# --- what the UI will find ---------------------------------------------------
# Informational only: the application decides commissioned vs. not, once, at
# startup (commissioning_state.latch). This line exists so the journal says
# which screen to expect.
CONFIG_DIR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["config_dir"])' "${MANIFEST}" 2>/dev/null || true)"
NYAML="$(find "${R}${CONFIG_DIR:-/var/lib/reflex-config}" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l)"
if [ "${NYAML}" -eq 0 ]; then
	log "${CONFIG_DIR:-/var/lib/reflex-config} holds no settings: the UI will come up UNCOMMISSIONED, on the application's defaults, and save nothing until a restore or a deliberate dismissal"
else
	log "${CONFIG_DIR:-/var/lib/reflex-config} already holds ${NYAML} settings file(s); the application judges them itself at startup"
fi

# --- start --------------------------------------------------------------------
# --no-block: queue the start and return. This unit is a oneshot still in its
# own ExecStart; waiting synchronously on another unit's job from here is the
# shape of a boot-time deadlock, and there is no reason to risk it.
systemctl start --no-block "${UNIT}" >/dev/null 2>&1 \
	|| finish START_FAILED "systemctl start --no-block ${UNIT} was refused; converge succeeded and the unit is enabled, so the next boot starts it"
printf 'converged-and-started %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" > "${DONE_MARKER}" 2>/dev/null || true

STATE=unknown
for _ in $(seq 1 "${START_WAIT}"); do
	STATE="$(systemctl is-active "${UNIT}" 2>/dev/null || true)"
	[ "${STATE}" = "active" ] && break
	sleep 1
done
if [ "${STATE}" = "active" ]; then
	finish STARTED "converged ${APP_ROOT} offline and started ${UNIT}; it is enabled, so every later boot starts it too"
fi
finish START_UNCONFIRMED "converged and queued ${UNIT}, but systemd reported '${STATE}' after ${START_WAIT}s -- read: journalctl -u ${UNIT} -b"
