#!/bin/bash
# PHASE 3 -- INTERACTIVE. Blocks on a human; asks, never assumes.
#
#   03-interactive.sh [--app <reflex monorepo checkout>] [--dry-run]
#
# --app is OPTIONAL here and is only ever READ: phase 4 reports whether the
# firmware sources landed in the checkout. provision.sh passes it through the
# same way it does to phase 1; a standalone run falls back to the path the
# image manifest declares, and says UNKNOWN if there is neither.
#
# Checklist item 13, Evan's hard requirement: an interactive portion for
# anything that must not be hard-coded -- credentials, and any config depending
# on machines or infrastructure OUTSIDE this Pi. Nothing machine-specific in
# the repo.
#
# So this file contains no IP addresses, no hostnames, no SSIDs, no keys. It
# asks. Everything it writes came from the person running it, this run.
#
# It is RE-RUNNABLE: each step detects what is already set and offers to skip.
# A provisioning step that must be done exactly once, in order, is a step that
# gets half-done at 11pm.
#
# WHAT IT WILL NOT DO: it never prints a secret, never writes one to a log, and
# never stores a password anywhere but the shadow file via passwd(1). If you
# find yourself wanting to pass a credential as an argument, that is the signal
# that it belongs in a human's hands rather than in a script.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

APP_ARG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--app)     APP_ARG="${2:-}"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		*) die "unknown argument: $1" ;;
	esac
done

phase "Phase 3: INTERACTIVE -- things that must not live in the repo"

need_root
resolve_service_user
resolve_paths

# Where the app checkout is, for phase 4's firmware-sources report. NOT
# hardcoded -- /home/default/projects/reflex is this machine's value, not a
# fact about the layout -- and not required either, because phase 3 writes
# nothing there. Three sources, in descending order of authority, and the
# phase names which one it used.
if [ -n "${APP_ARG}" ]; then
	APP_DIR="${APP_ARG}"
	APP_DIR_SRC="--app"
elif [ -n "${APP_ROOT:-}" ]; then
	APP_DIR="${APP_ROOT}"
	APP_DIR_SRC="${IMAGE_MANIFEST} (paths.app_root)"
else
	APP_DIR=""
	APP_DIR_SRC=""
fi

if [ ! -t 0 ]; then
	die "stdin is not a terminal. This phase asks questions and must not be
  automated -- that is the whole point of it being a separate phase."
fi

ask_yn() { # ask_yn <prompt> ; returns 0 for yes
	local reply
	printf '\n  %s [y/N] ' "$1"
	read -r reply
	case "${reply}" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# --- 1. the service account's password --------------------------------------
# The image ships this account LOCKED (SEAM.md call 2: no credential enters the
# repo, and the build's throwaway is revoked by passwd -l). Locked means sudo
# and password-SSH do not work, so this is usually the first thing needed.
phase "1/4  password for ${SERVICE_USER}"
if passwd -S "${SERVICE_USER}" 2>/dev/null | awk '{print $2}' | grep -q '^P$'; then
	ok "${SERVICE_USER} already has a usable password -- leaving it alone"
else
	say "${SERVICE_USER} has NO usable password (the image locks it deliberately)."
	say "Until it is set: no sudo, no password SSH. Key-based SSH still works."
	if ask_yn "Set it now?"; then
		if [ "${DRY_RUN}" = "1" ]; then
			say "  would: passwd ${SERVICE_USER}"
		else
			passwd "${SERVICE_USER}" || warn "passwd did not complete; account stays locked"
		fi
	else
		warn "skipped -- the account stays locked."
	fi
fi

# --- 2. authorized_keys -----------------------------------------------------
# Names another machine by definition, so it cannot be in the repo.
phase "2/4  SSH access for your workstation"
HOME_DIR="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
AK="${HOME_DIR}/.ssh/authorized_keys"
if [ -s "${AK}" ]; then
	ok "authorized_keys already has $(grep -cvE '^\s*(#|$)' "${AK}") key(s)"
	say "fingerprints:"
	ssh-keygen -lf "${AK}" 2>/dev/null | sed 's/^/      /' || true
	ask_yn "Add another?" || SKIP_AK=1
fi
if [ -z "${SKIP_AK:-}" ]; then
	say "Paste ONE public key line (ssh-ed25519 ... / ssh-rsa ...), or empty to skip:"
	printf '  > '
	read -r PUBKEY
	if [ -n "${PUBKEY}" ]; then
		case "${PUBKEY}" in
			ssh-*|ecdsa-*|sk-*) ;;
			*) die "that does not look like a public key line. Refusing to write it." ;;
		esac
		# A PRIVATE key pasted here would be a disaster; catch the obvious shape.
		case "${PUBKEY}" in
			*PRIVATE*) die "that looks like a PRIVATE key. Never paste one here." ;;
		esac
		run install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 "${HOME_DIR}/.ssh"
		# Append from THIS shell, never through `run bash -c`. PUBKEY is a
		# plain variable and was never exported, so the child shell expanded
		# it to nothing and appended a bare newline -- and the old post-check,
		# `test -s`, passed on that one-byte file. Found 2026-09-13; present
		# since the step was written. The dry-run branch is spelled out
		# because a redirection cannot go through `run`.
		if [ "${DRY_RUN}" = "1" ]; then
			printf '  would: append the pasted key to %s\n' "${AK}"
		else
			printf '%s\n' "${PUBKEY}" >> "${AK}"
		fi
		run chown "${SERVICE_USER}:${SERVICE_USER}" "${AK}"
		run chmod 0600 "${AK}"
		# GATE: the pasted line itself, whole, is in the file. "Non-empty" is
		# not a check -- a lone newline satisfies it.
		assert "the pasted key is in authorized_keys" grep -qxF -- "${PUBKEY}" "${AK}"
	else
		warn "skipped."
	fi
fi

# --- 3. network -------------------------------------------------------------
# nmcli, because RUNTIME-INVENTORY.md records that the nmcli PYTHON package
# shells out to the nmcli BINARY -- the app needs NetworkManager present, and
# the image installs it for that reason.
phase "3/4  network"
if command -v nmcli >/dev/null 2>&1; then
	say "current connections:"
	nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | sed 's/^/      /' \
		|| say "      (none active)"
	if ask_yn "Add a WiFi connection?"; then
		printf '  SSID: '; read -r SSID
		if [ -n "${SSID}" ]; then
			say "Passphrase (not echoed):"
			printf '  > '; read -rs WIFIPSK; printf '\n'
			if [ "${DRY_RUN}" = "1" ]; then
				say "  would: nmcli device wifi connect <SSID> (passphrase withheld)"
			else
				# The passphrase never reaches a log, an argument list this script
				# prints, or this repo. nmcli stores it in its own keyfile.
				if nmcli device wifi connect "${SSID}" password "${WIFIPSK}" >/dev/null 2>&1; then
					ok "connected to ${SSID}"
				else
					warn "could not connect to ${SSID} -- check the passphrase or signal"
				fi
			fi
			unset WIFIPSK
		fi
	fi
else
	warn "nmcli not found. The image is supposed to install network-manager;"
	warn "  the nmcli PYTHON package shells out to this binary, so the app needs it."
fi

# --- 4. firmware toolchain: THE ROLE QUESTION IS RETIRED --------------------
# SEAM.md call 3, RATIFIED WITH AN AMENDMENT, put the firmware toolchain BYTES
# in the image unconditionally (installing them at provision time would put a
# package mirror back on the recovery path) and left the ENABLEMENT here as a
# question -- where "enable the dev role" meant cloning reflex-fw and exposing
# it, and "no" meant an appliance with the bytes sitting inert.
#
# THAT QUESTION IS RETIRED, because the thing it asked about no longer exists.
# reflex-fw was folded into the reflex monorepo at the 2026-08-17 weld: the
# firmware sources now live at <app>/fw, INSIDE the same checkout phase 1
# already requires and converges. There is no second repository to clone, no
# second URL that "names another machine", and nothing for a "no" to withhold
# -- the sources arrive with the app either way. Asking would have been a
# prompt whose answer the script already knows, and on the first real card
# (2026-09-13) it was exactly that: a request for a clone URL for a repo that
# had not existed separately for four weeks.
#
# SEAM.md is NOT edited to match. It records the call as it was ratified; this
# is the note that the call's mechanism was overtaken by the monorepo weld.
# The DECISION it protects -- bytes baked unconditionally, never fetched at
# provision time -- is untouched, and is what the first check below reports.
#
# What is left is a REPORT, not a decision, so it is not a prompt: the bytes
# SEAM.md promises, and whether the sources actually landed in this checkout.
phase "4/4  firmware toolchain (report only -- the dev-role question is retired)"
if command -v openocd >/dev/null 2>&1 && command -v arm-none-eabi-gcc >/dev/null 2>&1; then
	ok "toolchain present in the image (openocd, arm-none-eabi-gcc) -- as designed"
else
	warn "toolchain NOT found. The image is supposed to bake gcc-arm-none-eabi,"
	warn "  cmake and openocd in unconditionally (SEAM.md call 3)."
fi

if [ -z "${APP_DIR}" ]; then
	warn "no --app given and ${IMAGE_MANIFEST} declares no paths.app_root, so"
	warn "  whether the firmware sources are present could NOT be determined."
	warn "  Re-run as: 03-interactive.sh --app <reflex monorepo checkout>"
elif [ -d "${APP_DIR}/fw" ]; then
	ok "firmware sources present at ${APP_DIR}/fw (path per ${APP_DIR_SRC})"
elif [ -d "${APP_DIR}" ]; then
	warn "${APP_DIR} exists but has no fw/ (path per ${APP_DIR_SRC})."
	warn "  Since the 2026-08-17 weld the firmware lives inside the app checkout,"
	warn "  so this is a pre-weld or partial checkout. Nothing here can fix that:"
	warn "  firmware cannot be built on this machine until the checkout is whole."
else
	warn "${APP_DIR} does not exist (path per ${APP_DIR_SRC}), so the firmware"
	warn "  sources could not be checked. Phase 1 requires this path and would"
	warn "  have refused -- has converge actually run on this machine?"
fi

# --- what used to be step 5 -------------------------------------------------
# A fifth step lived here until 2026-09-13: a purpose-scoped, forced-command
# SSH key for one estate's monitoring collector. It was the one thing in this
# file that named a specific network rather than asking a human about theirs,
# and item 13 says nothing machine-specific lives in this repo.
#
# It is a SITE HOOK now. provision.sh --site-hooks DIR runs every executable
# DIR/*.sh as root after this phase, with DELTAS_DIR, SERVICE_USER, HOME_DIR,
# APP_DIR, CONFIG_DIR and DRY_RUN exported -- so a hook can source lib.sh and
# behave like a phase without living in this repo. deltas/README.md has the
# contract; the hooks themselves live outside this tree, by design.

phase "Phase 3 complete"
say "Nothing here was recorded in the repo, which is the point."
