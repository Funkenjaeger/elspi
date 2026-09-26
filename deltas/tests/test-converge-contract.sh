#!/bin/bash
# Prove that 01-converge.sh's PURE VALIDATION -- argument parsing and
# require_app_dir's checkout checks -- is reached and refuses BEFORE
# need_root, rather than need_root shadowing it with "must run as root".
#
#   tests/test-converge-contract.sh
#
# Until 2026-09-25 need_root ran first (deltas/01-converge.sh:52, before
# resolve_paths/require_app_dir), so a non-root caller got the SAME root
# refusal no matter what --app named or omitted -- masking a typo'd --app
# path behind a message that has nothing to do with it. deltas/02-restore.sh's
# comment at :72 states the rule this now follows: "a refusal is the SAME
# refusal for any caller."
#
# Runs anywhere with bash, needs no image, no Pi, no root -- these refusals
# all happen before anything is written, which is itself the property being
# tested. resolve_service_user (which needs a real service-user account or
# /etc/elspi-image.json to succeed) still runs AFTER need_root, matching
# 02-restore.sh's shape of pairing it with the write phase, so it is never
# exercised here and this suite needs no image manifest or fixture account.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONVERGE="${HERE}/../01-converge.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0

# Each case names the REASON it must be refused for -- an exit code alone
# does not distinguish "refused for the right reason" from "need_root ate it".
refuses() { # refuses <description> <reason regex> <args...>
	local desc="$1" why="$2"; shift 2
	local out rc
	out="$("${CONVERGE}" "$@" 2>&1)"; rc=$?
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

# The other side: an --app the checkout-shape gates must let through. Non-root,
# it then stops at need_root or resolve_service_user (both AFTER the checkout
# gates now) -- which is exactly the proof it got past them, not proof of
# nothing.
passes_validation() { # passes_validation <description> <args...>
	local desc="$1"; shift
	local out rc
	out="$("${CONVERGE}" "$@" 2>&1)"; rc=$?
	if printf '%s' "${out}" | grep -qiE -- '--app is required|--app .* does not exist|does not look like the reflex monorepo|has no ui/deploy/reflex-ui.service'; then
		printf '  FAIL  %s\n        refused on checkout-shape grounds:\n%s\n' \
			"${desc}" "$(printf '%s' "${out}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif [ "${rc}" -ne 0 ] && ! printf '%s' "${out}" | grep -qiE 'must run as root|service user .* does not exist'; then
		printf '  FAIL  %s\n        failed for an unexpected reason:\n%s\n' \
			"${desc}" "$(printf '%s' "${out}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	else
		printf '  ok    %s\n' "${desc}"
		PASS=$((PASS+1))
	fi
}

mkapp() { # mkapp <dir> [--no-start] [--no-service]
	local d="$1"; shift
	mkdir -p "${d}/ui/deploy"
	if [ "${1:-}" != "--no-start" ]; then
		printf '#!/bin/bash\necho start\n' > "${d}/ui/deploy/start.sh"
	fi
	if [ "${1:-}" != "--no-service" ] && [ "${2:-}" != "--no-service" ]; then
		printf '[Unit]\nDescription=reflex-ui\n' > "${d}/ui/deploy/reflex-ui.service"
	fi
}

echo "== the refusals that matter =="

# 1. No --app at all. The headline case: this is the message that need_root
#    used to shadow entirely.
refuses "no --app at all" 'is required' --dry-run

# 2. --app pointing at a path that does not exist.
refuses "--app pointing at nothing" 'does not exist' --app "${WORK}/nope" --dry-run

# 3. --app exists but has no ui/deploy/start.sh -- not the monorepo shape.
mkdir -p "${WORK}/no-start"
refuses "--app with no ui/deploy/start.sh" 'ui/deploy/start.sh missing' --app "${WORK}/no-start" --dry-run

# 4. --app has start.sh but no reflex-ui.service to install.
mkapp "${WORK}/no-service" --no-service
refuses "--app with no ui/deploy/reflex-ui.service" 'reflex-ui\.service to install' --app "${WORK}/no-service" --dry-run

echo
echo "== the control: a well-formed --app must NOT be refused for these reasons =="
# Without this, every assertion above is satisfied by a script that refuses
# everything -- which would pass the suite and converge nothing.
mkapp "${WORK}/good"
passes_validation "a well-formed --app checkout gets past the checkout-shape gates" --app "${WORK}/good" --dry-run

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
