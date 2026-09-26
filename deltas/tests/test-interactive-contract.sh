#!/bin/bash
# Prove that 03-interactive.sh's tty check -- the one thing in this phase that
# is pure validation (a read of stdin's own state, nothing written) -- is
# reached and refuses BEFORE need_root, rather than need_root shadowing it
# with "must run as root".
#
#   tests/test-interactive-contract.sh
#
# Until 2026-09-25 need_root ran first (deltas/03-interactive.sh:44, before
# the "stdin is not a terminal" check at :64-67), so an unattended
# (non-interactive, non-root) caller got the root refusal instead of the
# message that actually explains why this phase cannot run unattended.
# deltas/02-restore.sh's comment at :72 states the rule this now follows:
# "a refusal is the SAME refusal for any caller."
#
# Runs anywhere with bash, needs no image, no Pi, no root, and no real
# terminal -- the refusal it exercises IS the absence of one. There is no
# "control" case here exercising a real tty: doing so needs a pty AND scripted
# answers to every ask_yn prompt, and a test that can hang waiting on a
# prompt is worse than no test (see resolve_service_user's note in
# test-converge-contract.sh for the same reason that gate is not exercised
# here either -- it also runs after need_root, unaffected by this reorder).
# `timeout` guards every invocation below so a regression that reintroduces a
# blocking read fails the suite instead of hanging it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INTERACTIVE="${HERE}/../03-interactive.sh"

PASS=0; FAIL=0

refuses() { # refuses <description> <reason regex> <args...>
	local desc="$1" why="$2"; shift 2
	local out rc
	out="$(timeout 10 "${INTERACTIVE}" "$@" </dev/null 2>&1)"; rc=$?
	if [ "${rc}" -eq 0 ]; then
		printf '  FAIL  %s\n        it EXITED 0 -- the contract is soft\n' "${desc}"
		FAIL=$((FAIL+1))
		return
	fi
	if [ "${rc}" -eq 124 ]; then
		printf '  FAIL  %s\n        TIMED OUT waiting on a prompt instead of refusing\n' "${desc}"
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

# 1. stdin is not a terminal -- explicitly forced with </dev/null so this does
#    not depend on however the outer harness happens to be invoked. This is
#    the headline case: this is the message need_root used to shadow entirely.
refuses "stdin is not a terminal (no --app, --dry-run)" 'stdin is not a terminal' --dry-run

# 2. Same, with a bogus --app: still the tty refusal, not a root refusal and
#    not confused by --app (--app is read-only in this phase and optional).
refuses "stdin is not a terminal (bogus --app)" 'stdin is not a terminal' --app /nonexistent/path --dry-run

echo
echo "== the control: argument parsing still refuses first, unaffected by the reorder =="
# Unknown-argument parsing happens in the while-loop, before EITHER the tty
# check or need_root, on both sides of this change -- this case is not
# expected to go red against the pristine script; it is here so a future
# change cannot silently move need_root back ahead of arg parsing too.
refuses "unknown argument" 'unknown argument' --bogus-flag

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
