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
#   The privilege decision. The image ships two DRM options -- first-opener
#   (the default, verified on hardware 2026-09-13) and cap-sys-admin (the
#   floor) -- plus /usr/local/sbin/elspi-drm-mode. This calls the switcher; it
#   never writes User= itself. --drm-mode is passed through WITHOUT a mode list
#   here on purpose: the switcher owns the list, so it is the only thing that
#   can reject a name, and it exits non-zero for one -- including
#   `logind-seat`, the third rung, deleted once first-opener was proven. A
#   rejected mode writes no drop-in, and the User=root gate a few lines below
#   is what then stops the run, because `run` does not abort on a non-zero
#   exit and this script is not `set -e`.
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
# docs/design/seam.md call 1 puts every dependency in the image venv WITHOUT the reflex
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
command -v git >/dev/null 2>&1 || die "git is not installed. The app half is a git checkout and the
  in-app updater runs git fetch/show/checkout; without git the first Setup -> Update
  refuses. Fix: apt-get install -y git   (found missing on the first real card, 2026-09-13)"
run chown -h "${SERVICE_USER}:${SERVICE_USER}" "${UI_DIR}/.venv"
run env UV_PROJECT_ENVIRONMENT="${VENV}" UV_PYTHON_DOWNLOADS=never \
	sh -c "cd '${UI_DIR}' && uv sync --no-dev --frozen"
# This script runs as root, so the sync above leaves what it installed
# root-owned -- and the in-app updater, running as the service user, has to
# `uv sync` into this same venv later (after flashing the firmware). Hand the
# whole venv back. -h: re-own symlinks themselves; bin/python points at the
# system interpreter. Found 2026-09-17, Open Loops 6aac9465.
run chown -R -h "${SERVICE_USER}:${SERVICE_USER}" "${VENV}"
assert "every directory in ${VENV} writable by ${SERVICE_USER}" \
	sudo -u "${SERVICE_USER}" sh -c "test -z \"\$(find '${VENV}' -type d ! -writable -print -quit)\""
assert "reflex importable from the venv" \
	sudo -u "${SERVICE_USER}" env KIVY_HOME=/tmp/.kivy-converge "${VENV}/bin/python" -c 'import reflex'
run rm -rf /tmp/.kivy-converge

# --- directories the app writes to ------------------------------------------
run install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0755 "${LOG_DIR}"
assert "${LOG_DIR} writable by ${SERVICE_USER}" sudo -u "${SERVICE_USER}" test -w "${LOG_DIR}"

# --- config.ini -------------------------------------------------------------
# docs/design/seam.md gives converge "/reflex-ui/config.ini (use_case = lathe)". Two things
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
# READ OFF THE LIVE MACHINE 2026-09-07, and it corrected this in the direction
# that matters. Two files, reproduced with their live names and contents:
#
#   /etc/sudoers.d/reflex-restart    NOPASSWD: systemctl restart reflex-ui.service
#   /etc/sudoers.d/reflex-stopstart  NOPASSWD: systemctl stop    reflex-ui.service
#
# An earlier draft here also granted `start`, reasoning from the second file's
# NAME. The live file called "stopstart" contains only STOP. Granting start
# would have handed a rebuilt machine a privilege the real one does not have --
# and quietly, since nothing would ever fail to reveal it. `start` is not needed
# anyway: the unit is enabled, so systemd starts it at boot, and the UI's own
# restart path uses `restart`.
#
# The task body's claim of "the only rule" was wrong in the other direction.
# Both halves came from reading the machine rather than the record.
#
# Two files rather than one merged file, deliberately: item 12 verifies a
# freshly-provisioned Pi by DIFFING it against the live elspi, and a
# reorganisation that is merely cosmetic would show up there as a difference to
# investigate.
sudoers_install() { # sudoers_install <basename> <rule line>
	local name="$1" rule="$2"
	local dst="/etc/sudoers.d/${name}" tmp
	tmp="$(mktemp)"
	{
		echo "# Installed by elspi deltas/01-converge.sh, matching the live machine."
		echo "# Scoped to reflex-ui.service only; no general systemctl access."
		echo "${rule}"
	} > "${tmp}"
	if visudo -cf "${tmp}" >/dev/null 2>&1; then
		run install -m 0440 -o root -g root "${tmp}" "${dst}"
		assert "${name} installed and still valid in place" visudo -cf "${dst}"
	else
		rm -f "${tmp}"
		die "the generated ${name} rule does NOT pass visudo -- refusing to install.
  A malformed file in /etc/sudoers.d breaks sudo for EVERY user, and on a
  machine with no terminal that is unrecoverable without pulling the SD card."
	fi
	rm -f "${tmp}"
}

sudoers_install reflex-restart \
	"${SERVICE_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart reflex-ui.service"
sudoers_install reflex-stopstart \
	"${SERVICE_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl stop reflex-ui.service"

# GATE: prove the rule actually grants what it claims, and no more.
#
# NOT `sudo -n -l <command>`. That asks whether the command is PERMITTED,
# and on this image the service user is also in the sudo group with
# (ALL:ALL) ALL by password -- so "restart ssh.service" is permitted, with a
# password, and the old negative check tripped on the first real card
# (2026-09-13). `-l` never needs a password either (listpw=any is satisfied by
# the one NOPASSWD entry), so `-n` did not narrow it. Two probes instead:
#   1. parse root's view of the policy for NOPASSWD grants and require every
#      one of them to be exactly one of the two lines installed above;
#   2. actually run a harmless command passwordless as the service user,
#      ignoring any cached credential (-k), and require it to be REFUSED.
if [ "${DRY_RUN}" != "1" ]; then
	GRANTS="$(sudo -l -U "${SERVICE_USER}" 2>/dev/null | grep -E 'NOPASSWD' | sed -E 's/^[[:space:]]+//')"
	RESTART_RE='^\(root\) NOPASSWD: /usr/bin/systemctl restart reflex-ui\.service$'
	STOP_RE='^\(root\) NOPASSWD: /usr/bin/systemctl stop reflex-ui\.service$'
	START_RE='^\(root\) NOPASSWD: /usr/bin/systemctl start reflex-ui\.service$'

	# POSITIVE: the thing the UI actually needs, as a NOPASSWD grant.
	if printf '%s\n' "${GRANTS}" | grep -Eq "${RESTART_RE}"; then
		ok "${SERVICE_USER} can restart reflex-ui without a password"
	else
		die "the sudoers rule parsed but sudo -l shows no NOPASSWD grant for
  restart reflex-ui.service. The UI's own restart button would fail.
  grants seen:
${GRANTS}"
	fi

	# NEGATIVE: the grant must be NARROW. Every NOPASSWD line must be one of
	# ours; anything else is a rule that quietly widened.
	OTHER="$(printf '%s\n' "${GRANTS}" | grep -Ev "${RESTART_RE}|${STOP_RE}|${START_RE}|^$" || true)"
	if [ -n "${OTHER}" ]; then
		die "${SERVICE_USER} has NOPASSWD grants beyond reflex-ui.service:
${OTHER}
  A blanket NOPASSWD systemctl is a root shell in three moves. Refusing."
	fi
	ok "the NOPASSWD grants do NOT extend beyond reflex-ui.service"

	# NEGATIVE, executed: an arbitrary command must be REFUSED passwordless.
	# /usr/bin/true is harmless; -k ignores the credential cache, which
	# timestamp_type=global would otherwise share from the operator's session.
	if sudo -u "${SERVICE_USER}" sudo -k -n /usr/bin/true >/dev/null 2>&1; then
		die "${SERVICE_USER} can run an ARBITRARY command without a password.
  Some rule grants blanket NOPASSWD (check /etc/sudoers.d). Refusing."
	fi
	ok "an arbitrary command is refused without a password"

	# `start` is deliberately absent (see above). If it ever appears, something
	# widened the rule beyond the live machine and this should say so.
	if printf '%s\n' "${GRANTS}" | grep -Eq "${START_RE}"; then
		warn "${SERVICE_USER} can also START reflex-ui without a password."
		warn "  The live machine grants only restart and stop. Not fatal, but this"
		warn "  is wider than elspi and item 12's diff will show it."
	else
		ok "start is not granted, matching the live machine"
	fi
fi

# --- polkit: NetworkManager for the SESSIONLESS service user ----------------
# THE DEFECT, found on the first real card 2026-09-13: the UI's Network screen
# runs `nmcli radio wifi on` at startup and got
#
#     Error: Not authorized to perform this operation.
#
# WHY, and why group membership is not the answer. reflex-ui runs as the
# service user under systemd with NO logind session, so polkit classifies the
# subject as neither "active" nor "inactive" and every NetworkManager action
# falls through to its "any" default -- "no" for
# org.freedesktop.NetworkManager.enable-disable-wifi. Debian's shipped
# /usr/share/polkit-1/rules.d/org.freedesktop.NetworkManager.rules covers only
# settings.modify.system, and only for a local ACTIVE session. Adding the user
# to netdev changes nothing: it is not a group problem.
#
# THE FILE IS A TEMPLATE. files/50-reflex-service-user.rules is the copy
# proven on the card, kept verbatim, and it names the pi-gen default user. The
# subject.user line is regenerated here from the user THIS machine declares
# (the image manifest, via resolve_service_user), because a rule naming a user
# that does not exist is inert and looks installed.
#
# stage-elspi/05-service-user installs the same template at build time. This
# is here as well so a card flashed from an OLDER image converges to the fix
# instead of needing it applied by hand.
POLKIT_SRC="${HERE}/files/50-reflex-service-user.rules"
POLKIT_DST=/etc/polkit-1/rules.d/50-reflex-service-user.rules

[ -f "${POLKIT_SRC}" ] || die "${POLKIT_SRC} is missing -- the polkit template ships in this repo"

# ASSERT THE ANCHOR BEFORE SUBSTITUTING. If the template's subject.user line
# ever changes shape, the sed below matches nothing, exits 0, and installs a
# rule scoped to whatever user the file happened to name.
grep -q 'subject\.user === "' "${POLKIT_SRC}" \
	|| die "${POLKIT_SRC} has no 'subject.user === \"...\"' line to substitute.
  The template changed shape, so the substitution would be a silent no-op and
  the installed rule would name the wrong user."

if [ ! -d /usr/share/polkit-1/rules.d ] && ! command -v pkaction >/dev/null 2>&1; then
	warn "no polkit installation detected here. The rule will be installed but"
	warn "  INERT until polkitd is present -- and NetworkManager is what pulls it in."
fi

POLKIT_TMP="$(mktemp)"
sed -E "s/subject\.user === \"[^\"]*\"/subject.user === \"${SERVICE_USER}\"/" \
	"${POLKIT_SRC}" > "${POLKIT_TMP}"
if ! grep -q "subject.user === \"${SERVICE_USER}\"" "${POLKIT_TMP}"; then
	rm -f "${POLKIT_TMP}"
	die "the generated polkit rule does not name ${SERVICE_USER}. Refusing to
  install a rule that grants nothing while looking like it grants something."
fi
run install -d -m 0755 -o root -g root /etc/polkit-1/rules.d
run install -m 0644 -o root -g root "${POLKIT_TMP}" "${POLKIT_DST}"
rm -f "${POLKIT_TMP}"
assert "polkit rule installed at ${POLKIT_DST}" test -f "${POLKIT_DST}"
assert "the installed polkit rule names ${SERVICE_USER}" \
	grep -q "subject.user === \"${SERVICE_USER}\"" "${POLKIT_DST}"

# GATE, FUNCTIONAL -- and side-effect free, which took some arranging.
#
# A READ-ONLY probe will not do. `nmcli radio wifi` with no verb reports the
# state, needs no authorization at all, and therefore passes identically with
# and without this rule: the exact "check that cannot fail" shape. The
# operation the UI performs is `nmcli radio wifi ON`, and that one is what goes
# through org.freedesktop.NetworkManager.enable-disable-wifi.
#
# Turning the radio ON WHEN IT IS ALREADY ON is that same authorized call with
# no resulting state change, so it is safe to run from a provisioning script.
# If the radio is off we do NOT run it -- switching a radio on is a decision
# that belongs to the human in phase 3, not to converge -- and the check says
# UNPROVEN rather than quietly passing.
#
# systemd-run --uid, not `sudo -u`: the defect IS the absence of a logind
# session, and a transient systemd unit reproduces the service's own context.
# A sudo invocation can inherit enough of the operator's session to answer a
# different question than the one that matters.
if [ "${DRY_RUN}" = "1" ]; then
	printf '  (skipped check: %s)\n' "nmcli radio wifi on as ${SERVICE_USER}"
elif ! command -v nmcli >/dev/null 2>&1; then
	warn "nmcli not found, so the polkit rule could NOT be exercised. UNPROVEN."
elif ! command -v systemd-run >/dev/null 2>&1; then
	warn "systemd-run not found, so the rule could NOT be exercised in a"
	warn "  sessionless unit -- which is the only context that reproduces the"
	warn "  defect. Installed but UNPROVEN."
else
	WIFI_RADIO="$(nmcli radio wifi 2>/dev/null || true)"
	if [ "${WIFI_RADIO}" = "enabled" ]; then
		if systemd-run --uid="${SERVICE_USER}" --wait --pipe --quiet \
			nmcli radio wifi on >/dev/null 2>&1; then
			ok "${SERVICE_USER} is authorized for 'nmcli radio wifi on' (the op that failed)"
		else
			die "'nmcli radio wifi on' as ${SERVICE_USER} in a sessionless unit STILL
  FAILS. The rule is installed and names the user, so something else is
  refusing. Two things to check: is polkitd installed and running, and does
  another file in /etc/polkit-1/rules.d sort before 50- and return NO?"
		fi
	else
		warn "the wifi radio reads '${WIFI_RADIO:-unknown}', not 'enabled', so the"
		warn "  functional check was NOT run -- the only side-effect-free form of it is"
		warn "  turning an already-on radio on. The rule is installed but UNPROVEN on"
		warn "  this machine. Re-run converge with the radio on, or watch the UI's"
		warn "  Network screen for 'Not authorized to perform this operation'."
	fi
fi

phase "Phase 1 complete"
say "NOT started. Start it deliberately once phase 2 has restored the config:"
say "    systemctl start reflex-ui"
say "Starting before the restore would come up on whatever ${CONFIG_DIR} holds."
