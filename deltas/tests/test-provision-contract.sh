#!/bin/bash
# Prove that provision.sh's own "--app is required" check -- pure validation,
# a read of an argument that was or was not given -- is reached and refuses
# BEFORE need_root, rather than need_root shadowing it with "must run as
# root".
#
#   tests/test-provision-contract.sh
#
# Until 2026-09-25 need_root ran first (deltas/provision.sh:104, before the
# "--app is required" check at :113), so a non-root caller with no --app got
# refused for being non-root -- discovering the actual problem (no --app)
# only after fixing the one that was never the problem. deltas/02-restore.sh's
# comment at :72 states the rule this now follows: "a refusal is the SAME
# refusal for any caller."
#
# Runs anywhere with bash, needs no image, no Pi, no root -- this refusal
# happens before either phase script is ever invoked, which is itself the
# property being tested. load_site_env runs before need_root on BOTH sides of
# this change (deltas/provision.sh:96-102 says why: "loaded before need_root
# because it only reads"), so it is not exercised here; test-restore-contract.sh
# already covers load_site_env's own refusals.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVISION="${HERE}/../provision.sh"

PASS=0; FAIL=0

refuses() { # refuses <description> <reason regex> <args...>
	local desc="$1" why="$2"; shift 2
	local out rc
	out="$("${PROVISION}" "$@" 2>&1)"; rc=$?
	if [ "${rc}" -eq 0 ]; then
		printf '  FAIL  %s\n        it EXITED 0 -- the contract is soft\n' "${desc}"
		FAIL=$((FAIL+1))
		return
	fi
	if ! printf '%s' "${out}" | grep -qiE -- "${why}"; then
		printf '  FAIL  %s\n        exited %d but not for /%s/:\n%s\n' \
			"${desc}" "${rc}" "${why}" "$(printf '%s' "${out}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
		return
	fi
	printf '  ok    %s\n' "${desc}"
	PASS=$((PASS+1))
}

echo "== the refusal that matters =="

# A non-root caller with no --app at all: the headline case named by the
# 2026-09-25 build order. Must be refused for the missing --app, not for
# being non-root.
refuses "non-root caller, no --app at all" 'is required' --dry-run

echo
echo "== --fresh: first commissioning, at the provision.sh level =="

# The two argument-shape refusals, observed through provision.sh itself
# (test-restore-contract.sh covers them on 02-restore.sh). Both are pure reads
# of the arguments, so a non-root caller must get THESE reasons, not
# "must run as root".
refuses "--fresh together with --config-backup" 'mutually exclusive' \
	--app /nonexistent-app --fresh --config-backup /nonexistent-capture --dry-run
refuses "neither --fresh nor --config-backup (the kept hard fail)" \
	'config-backup is required.*--fresh' --app /nonexistent-app --dry-run

# --fresh ON A CARD THAT ALREADY HOLDS CONFIG -- refused UP FRONT, before
# phase 1 touches the machine. Since 2026-09-26 a fresh card converges and
# starts the UI at first boot (stage-elspi/14-first-boot-ui), and the running
# app writes its own commissioning ledger into CONFIG_DIR at startup. So
# `provision.sh --fresh` on such a card is the COMMON case of this refusal,
# not a corner. 02-restore.sh refused it too, but only as phase 2 -- after
# phase 1 had re-converged the machine as root, and with a closing message
# ("the service is enabled but has no commissioned config. DO NOT START IT")
# that is false about a UI that is on the screen. provision.sh's own rule
# (its header: fail on arguments "HERE, before phase 1 does half the work")
# is what this case holds it to.
#
# CONFIG_DIR is resolved by lib.sh, not passed, so the fixture comes from an
# unprivileged mount namespace, exactly as test-restore-contract.sh case 4
# does: a tmpfs over /var/lib holds a non-empty reflex-config, and a tmpfs
# over /opt guarantees there is no image venv -- so even on a machine that
# HAS one, a phase 1 reached by mistake dies at its first check and changes
# nothing (and --dry-run is passed as well). The namespace maps the caller to
# uid 0, so need_root is satisfied and cannot be what refuses.
if command -v unshare >/dev/null 2>&1 && unshare --mount --map-root-user true 2>/dev/null; then
	NS_OUT="$(unshare --mount --map-root-user bash -c '
		set -u
		mount -t tmpfs tmpfs /var/lib || exit 90
		mount -t tmpfs tmpfs /opt     || exit 91
		mkdir -p /var/lib/reflex-config/ledger/snapshots || exit 92
		echo "startup snapshot" > /var/lib/reflex-config/ledger/snapshots/first.yaml || exit 93
		BEFORE="$(find /var/lib/reflex-config -type f -exec md5sum {} + | sort)"
		SCRIPT_OUT="$('"${PROVISION}"' --app /nonexistent-app --fresh --dry-run 2>&1)"; SCRIPT_RC=$?
		AFTER="$(find /var/lib/reflex-config -type f -exec md5sum {} + | sort)"
		printf "RC=%s\n" "${SCRIPT_RC}"
		printf "%s\n" "${SCRIPT_OUT}"
		[ "${BEFORE}" = "${AFTER}" ] && echo "TREE=unchanged" || echo "TREE=CHANGED"
	' 2>&1)"; NS_RC=$?
	SCRIPT_RC="$(printf '%s' "${NS_OUT}" | sed -n 's/^RC=//p')"
	if [ "${NS_RC}" -ge 90 ]; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        could not set up the namespace fixture (exit %d):\n%s\n' \
			"${NS_RC}" "$(printf '%s' "${NS_OUT}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif [ "${SCRIPT_RC}" = "0" ]; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        it EXITED 0 -- the directory was not refused\n'
		FAIL=$((FAIL+1))
	elif printf '%s' "${NS_OUT}" | grep -q 'Phase 1'; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        refused only AFTER phase 1 had started -- the up-front check is missing:\n%s\n' \
			"$(printf '%s' "${NS_OUT}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif ! printf '%s' "${NS_OUT}" | grep -qi 'already holds'; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        refused, but not for holding config:\n%s\n' \
			"$(printf '%s' "${NS_OUT}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif ! printf '%s' "${NS_OUT}" | grep -q 'TREE=unchanged'; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        refused, but the directory changed\n'
		FAIL=$((FAIL+1))
	else
		printf '  ok    --fresh with a non-empty CONFIG_DIR: refused before phase 1, directory untouched\n'
		PASS=$((PASS+1))
	fi
	# THE CONTROL: an EMPTY CONFIG_DIR must get PAST the up-front check and
	# reach phase 1 (which then dies at its own first check: no --app, no
	# venv). Without this, an up-front check that refused every --fresh would
	# pass the case above.
	CTL_OUT="$(unshare --mount --map-root-user bash -c '
		mount -t tmpfs tmpfs /var/lib || exit 90
		mount -t tmpfs tmpfs /opt     || exit 91
		mkdir -p /var/lib/reflex-config || exit 92
		'"${PROVISION}"' --app /nonexistent-app --fresh --dry-run 2>&1
	' 2>&1)"
	if printf '%s' "${CTL_OUT}" | grep -qi 'already holds'; then
		printf '  FAIL  --fresh with an EMPTY CONFIG_DIR (control)\n        refused as if it held config:\n%s\n' \
			"$(printf '%s' "${CTL_OUT}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif ! printf '%s' "${CTL_OUT}" | grep -q 'Phase 1'; then
		printf '  FAIL  --fresh with an EMPTY CONFIG_DIR (control)\n        did not reach phase 1:\n%s\n' \
			"$(printf '%s' "${CTL_OUT}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	else
		printf '  ok    --fresh with an EMPTY CONFIG_DIR (control): passes the up-front check, reaches phase 1\n'
		PASS=$((PASS+1))
	fi
else
	printf '  skip  --fresh with a non-empty CONFIG_DIR (needs unprivileged user namespaces; unavailable here)\n'
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
