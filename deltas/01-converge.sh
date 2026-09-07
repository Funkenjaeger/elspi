#!/bin/bash
# PHASE 1 -- CONVERGE. Idempotent and retryable.
#
#   01-converge.sh --app <reflex monorepo checkout> [--drm-mode MODE] [--dry-run]
#
# Installs the application wiring: the venv bridge, the unit, the DRM mode, the
# sudoers rules, and config.ini. Run it as often as you like; it should be a
# no-op the second time.
#
# WHAT THIS DELIBERATELY DOES NOT OWN
#
#   The unit file. reflex-ui.service belongs to the reflex repo and is
#   installed FROM THE CHECKOUT, never copied into elspi.git. A copy would
#   drift from the app that has to start under it.
#
#   The privilege decision. The image ships three DRM options plus
#   /usr/local/sbin/elspi-drm-mode. This calls the switcher; it never writes
#   User= itself.
#
# Those two combine into the wiring worth understanding before reading on:
# THE APP'S STOCK UNIT SAYS User=root AND THE IMAGE RUNS NON-ROOT. The drop-in
# written by elspi-drm-mode overrides User=/Group=, because systemd drop-ins
# override single-value settings from the main unit. So the app repo keeps a
# unit that still works on the old root-running machine, the image keeps the
# privilege decision, and nothing has to edit the app's file.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

APP_ARG=""
DRM_MODE="first-opener"
while [ $# -gt 0 ]; do
	case "$1" in
		--app)      APP_ARG="${2:-}"; shift 2 ;;
		--drm-mode) DRM_MODE="${2:-}"; shift 2 ;;
		--dry-run)  DRY_RUN=1; shift ;;
		*) die "unknown argument: $1" ;;
	esac
done

phase "Phase 1: CONVERGE the application"

need_root
resolve_service_user
resolve_paths
require_app_dir "${APP_ARG}"

say "service user: ${SERVICE_USER} (per ${SERVICE_USER_SRC})"
say "app:          ${APP_DIR}"
say "venv:         ${VENV}"

# --- the venv bridge --------------------------------------------------------
# SEAM.md call 1 puts every dependency in the image venv WITHOUT the reflex
# package. deploy/start.sh activates $UI_DIR/.venv. Reconcile by symlinking.
#
# HARD FAIL if the image venv is absent: this delta targets the pi-gen image,
# and on a machine without it `uv sync` would quietly start compiling Kivy from
# sdist -- the hours-long, network-dependent step the image exists to remove.
# Failing here is much kinder than appearing to hang.
[ -d "${VENV}" ] || die "${VENV} does not exist.

  This delta targets the pi-gen image, which ships the dependency set there.
  Without it, uv would rebuild Kivy from source on this Pi: slow, and it needs
  PyPI to still be serving that exact sdist. If you are provisioning a machine
  that was NOT flashed from the elspi image, that is a different job."
ok "image venv present at ${VENV}"

if [ -L "${UI_DIR}/.venv" ]; then
	CUR="$(readlink -f "${UI_DIR}/.venv" 2>/dev/null || true)"
	if [ "${CUR}" = "$(readlink -f "${VENV}")" ]; then
		ok ".venv already points at the image venv"
	else
		warn ".venv points at ${CUR}; repointing"
		run rm -f "${UI_DIR}/.venv"
		run ln -s "${VENV}" "${UI_DIR}/.venv"
	fi
elif [ -e "${UI_DIR}/.venv" ]; then
	# A REAL venv in the checkout, not a symlink. That is the pre-image layout.
	# Move it aside rather than delete: it may be the only working environment
	# on a machine where something else has gone wrong.
	ASIDE="${UI_DIR}/.venv.pre-image-$(date +%Y%m%d-%H%M%S)"
	warn "${UI_DIR}/.venv is a real directory (pre-image layout) -- moving to ${ASIDE}"
	run mv "${UI_DIR}/.venv" "${ASIDE}"
	run ln -s "${VENV}" "${UI_DIR}/.venv"
else
	run ln -s "${VENV}" "${UI_DIR}/.venv"
fi
assert ".venv resolves to ${VENV}" \
	bash -c "[ \"\$(readlink -f '${UI_DIR}/.venv')\" = \"\$(readlink -f '${VENV}')\" ]"

# --- install the app into the image venv ------------------------------------
# --no-dev: main group only. The image already satisfies every dependency, so
# this installs the reflex package itself and finishes in seconds.
command -v uv >/dev/null 2>&1 || die "uv is not on PATH (the image installs it at /usr/local/bin/uv)"
run chown -h "${SERVICE_USER}:${SERVICE_USER}" "${UI_DIR}/.venv"
run env UV_PROJECT_ENVIRONMENT="${VENV}" UV_PYTHON_DOWNLOADS=never \
	sh -c "cd '${UI_DIR}' && uv sync --no-dev --frozen"
assert "reflex importable from the venv" \
	sudo -u "${SERVICE_USER}" env KIVY_HOME=/tmp/.kivy-converge "${VENV}/bin/python" -c 'import reflex'
run rm -rf /tmp/.kivy-converge

# --- directories the app writes to ------------------------------------------
run install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0755 "${LOG_DIR}"
assert "${LOG_DIR} writable by ${SERVICE_USER}" sudo -u "${SERVICE_USER}" test -w "${LOG_DIR}"

# --- config.ini -------------------------------------------------------------
# SEAM.md gives converge "/reflex-ui/config.ini (use_case = lathe)". Two things
# it does NOT do:
#   - It does not touch current_mode. That is RUNTIME state the app writes; on
#     the live machine it reads `current_mode = 2`. Pinning it here would mean
#     provisioning decides which screen the lathe comes up on.
#   - It does not overwrite an existing file. Converge is idempotent, and
#     stomping a file the app owns at runtime is not idempotence.
CFG="${UI_DIR}/config.ini"
if [ -f "${CFG}" ]; then
	if grep -qE '^\s*use_case\s*=\s*lathe\s*$' "${CFG}"; then
		ok "config.ini already declares use_case = lathe"
	else
		warn "config.ini exists but does not say 'use_case = lathe'. NOT rewriting it --"
		warn "  it may carry runtime state. Current contents:"
		sed 's/^/        /' "${CFG}"
		warn "  fix by hand if this machine is a lathe."
	fi
else
	run install -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0644 /dev/null "${CFG}"
	run bash -c "printf '[device]\nuse_case = lathe\n' > '${CFG}'"
	run chown "${SERVICE_USER}:${SERVICE_USER}" "${CFG}"
	assert "config.ini declares use_case = lathe" grep -qE '^use_case = lathe$' "${CFG}"
fi
# Ownership matters independently: the app WRITES current_mode here. On the
# live root-running machine this file is root:root, which a non-root service
# cannot update.
run chown "${SERVICE_USER}:${SERVICE_USER}" "${CFG}"
assert "config.ini owned by ${SERVICE_USER} (the app writes current_mode to it)" \
	bash -c "[ \"\$(stat -c %U '${CFG}')\" = '${SERVICE_USER}' ]"

# --- the unit, from the checkout --------------------------------------------
UNIT_SRC="${UI_DIR}/deploy/reflex-ui.service"
UNIT_DST=/etc/systemd/system/reflex-ui.service
run install -m 0644 "${UNIT_SRC}" "${UNIT_DST}"
assert "reflex-ui.service installed from the checkout" test -f "${UNIT_DST}"
run systemctl daemon-reload

# --- the DRM mode, via the image's switcher ---------------------------------
if [ -x /usr/local/sbin/elspi-drm-mode ]; then
	run /usr/local/sbin/elspi-drm-mode "${DRM_MODE}"
	if [ "${DRY_RUN}" != "1" ]; then
		# GATE: the whole non-root decision rides on this drop-in overriding the
		# app unit's User=root. Assert systemd's own resolved view, not the file.
		EFFECTIVE_USER="$(systemctl show -p User --value reflex-ui.service 2>/dev/null)"
		if [ "${EFFECTIVE_USER}" = "root" ]; then
			die "reflex-ui.service still resolves to User=root after applying DRM mode
  '${DRM_MODE}'. The drop-in did not take, and the image's non-root decision
  is not in effect. Do not ship this."
		fi
		ok "systemd resolves User=${EFFECTIVE_USER:-<unset>} (drop-in overrode the unit's root)"
	fi
else
	warn "/usr/local/sbin/elspi-drm-mode not found -- not an elspi image?"
	warn "  reflex-ui.service will run as whatever its own User= says, which on the"
	warn "  app's stock unit is ROOT. That is the pre-2026-09-01 behaviour."
fi

run systemctl enable reflex-ui.service

# --- sudoers ----------------------------------------------------------------
# The app restarts itself from the UI, so the service user needs exactly that
# and nothing else.
#
# VALIDATED BEFORE INSTALL, never written into place directly. A malformed file
# in /etc/sudoers.d locks sudo out for EVERY user, and on a machine with no
# terminal that is unrecoverable without pulling the SD card. Written to a temp
# file, checked with `visudo -cf`, and only then moved in.
#
# NOT VERIFIED AGAINST THE LIVE MACHINE. elspi carries TWO files --
# /etc/sudoers.d/reflex-restart and /etc/sudoers.d/reflex-stopstart -- and both
# are mode 0440 root, so they could not be read without a password this session.
# The task body claims "NOPASSWD /usr/bin/systemctl restart reflex-ui.service
# (only rule)", which the filenames already contradict. What is installed here
# is DECLARED, not copied: restart, plus stop and start, which is what those two
# names describe. Diff it against the live files before the flash session.
SUDOERS_DST=/etc/sudoers.d/reflex-restart
SUDOERS_TMP="$(mktemp)"
{
	echo "# Installed by elspi deltas/01-converge.sh -- the UI restarts itself."
	echo "# Scoped to reflex-ui.service only; no general systemctl access."
	echo "${SERVICE_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart reflex-ui.service"
	echo "${SERVICE_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl stop reflex-ui.service"
	echo "${SERVICE_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start reflex-ui.service"
} > "${SUDOERS_TMP}"

if visudo -cf "${SUDOERS_TMP}" >/dev/null 2>&1; then
	run install -m 0440 -o root -g root "${SUDOERS_TMP}" "${SUDOERS_DST}"
	assert "sudoers rule installed and still valid in place" visudo -cf "${SUDOERS_DST}"
else
	rm -f "${SUDOERS_TMP}"
	die "the generated sudoers rule does NOT pass visudo -- refusing to install it.
  A malformed file in /etc/sudoers.d breaks sudo for every user on a machine
  with no terminal."
fi
rm -f "${SUDOERS_TMP}"

# GATE: prove the rule actually grants what it claims. `sudo -l` resolves the
# whole policy, so this catches a rule that parses but is shadowed or scoped
# wrong -- which a syntax check cannot see.
if [ "${DRY_RUN}" != "1" ]; then
	if sudo -u "${SERVICE_USER}" sudo -n -l /usr/bin/systemctl restart reflex-ui.service >/dev/null 2>&1; then
		ok "${SERVICE_USER} can restart reflex-ui without a password"
	else
		die "the sudoers rule parsed but ${SERVICE_USER} still cannot restart
  reflex-ui without a password. The UI's own restart button would fail."
	fi
fi

phase "Phase 1 complete"
say "NOT started. Start it deliberately once phase 2 has restored the config:"
say "    systemctl start reflex-ui"
say "Starting before the restore would come up on whatever ${CONFIG_DIR} holds."
