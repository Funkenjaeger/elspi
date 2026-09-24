#!/bin/bash
# EXAMPLE site hook: install one extra authorized_keys line for SERVICE_USER,
# read from a key file that sits BESIDE this script (extra-key.pub). This repo
# ships no such file and never will -- see docs/site-layer.md and this
# example's own README for what belongs in a real site-hooks directory
# instead of examples/site/.
#
# A PLACEHOLDER TO ADAPT, not a hook to run unmodified. A bare key grants a
# full interactive shell to SERVICE_USER over SSH. A key that exists only so
# one collector, backup job or monitor can reach this machine should almost
# always carry a forced command instead, in the pasted line itself:
#
#   restrict,command="/usr/local/bin/my-collector-endpoint" ssh-ed25519 AAAA...
#
# `restrict` (OpenSSH >= 7.2) turns off port/agent/X11 forwarding and PTY
# allocation in one word; `command=` is what actually pins the session to one
# script regardless of what the client asks to run. See sshd(8),
# AUTHORIZED_KEYS FILE FORMAT.
#
# Run this only through provision.sh --site-hooks: it needs DELTAS_DIR,
# SERVICE_USER, HOME_DIR and DRY_RUN exported the way provision.sh exports
# them (deltas/provision.sh, docs/site-layer.md), and it uses lib.sh's
# run/assert so DRY_RUN is honoured the same way the phases honour it.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

: "${DELTAS_DIR:?DELTAS_DIR not set -- run this hook through provision.sh --site-hooks, not standalone}"
# shellcheck source=/dev/null
. "${DELTAS_DIR}/lib.sh"
: "${SERVICE_USER:?SERVICE_USER not set -- run this hook through provision.sh --site-hooks}"
: "${HOME_DIR:?HOME_DIR not set -- run this hook through provision.sh --site-hooks}"

KEYFILE="${HERE}/extra-key.pub"

if [ ! -e "${KEYFILE}" ]; then
	say "no extra-key.pub beside this hook (${HERE}) -- nothing to do"
	exit 0
fi
[ -r "${KEYFILE}" ] || die "${KEYFILE} exists but is not readable"

PUBKEY="$(head -n 1 "${KEYFILE}")"
case "${PUBKEY}" in
	ssh-*|ecdsa-*|sk-*) ;;
	*) die "${KEYFILE} does not look like a public key line (expected ssh-*/ecdsa-*/sk-*)" ;;
esac
case "${PUBKEY}" in
	*PRIVATE*) die "${KEYFILE} looks like a PRIVATE key. Never point this hook at one." ;;
esac

AK="${HOME_DIR}/.ssh/authorized_keys"

run install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 "${HOME_DIR}/.ssh"
if [ ! -e "${AK}" ]; then
	run install -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0600 /dev/null "${AK}"
fi

if [ -e "${AK}" ] && grep -qxF -- "${PUBKEY}" "${AK}" 2>/dev/null; then
	ok "extra-key.pub's line is already in authorized_keys -- nothing to add"
else
	# Appended from THIS shell, never through `run bash -c` -- see
	# deltas/03-interactive.sh's comment on its own authorized_keys append for
	# the expansion trap that bit that step once (an unexported variable
	# expands to nothing in a child shell, and a bare newline still passes a
	# `test -s` check). A redirection cannot go through `run` either way, so
	# the DRY_RUN branch is spelled out here instead.
	if [ "${DRY_RUN}" = "1" ]; then
		say "would: append extra-key.pub's line to ${AK}"
	else
		printf '%s\n' "${PUBKEY}" >> "${AK}"
	fi
	run chown "${SERVICE_USER}:${SERVICE_USER}" "${AK}"
	run chmod 0600 "${AK}"
	assert "extra-key.pub's line is now in authorized_keys" grep -qxF -- "${PUBKEY}" "${AK}"
fi
