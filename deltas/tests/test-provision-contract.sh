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
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
