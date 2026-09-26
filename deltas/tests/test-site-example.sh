#!/bin/bash
# Prove that examples/site/hooks/10-example-extra-key.sh -- the placeholder
# site hook docs/site-layer.md points at -- actually behaves the way that page
# claims: DRY_RUN changes nothing, a real run installs the pasted key line
# exactly once no matter how many times it runs, and a missing key file is a
# clean no-op, said out loud.
#
#   deltas/tests/test-site-example.sh
#
# Globbed by .github/workflows/tier1.yml's "delta-layer contracts" step
# alongside test-restore-contract.sh -- no separate registration needed there.
#
# Runs anywhere with bash + ssh-keygen, needs no image, no Pi, no root: the
# hook is exercised as the CURRENT user, which is exactly what
# `install -o "${SERVICE_USER}" -g "${SERVICE_USER}"` degrades to when
# SERVICE_USER is already the caller -- a chown to yourself, which
# unprivileged accounts may do.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DELTAS_DIR="$(cd "${HERE}/.." && pwd)"
HOOK_SRC="$(cd "${HERE}/../.." && pwd)/examples/site/hooks/10-example-extra-key.sh"
[ -f "${HOOK_SRC}" ] || { echo "FAIL: ${HOOK_SRC} is missing"; exit 1; }

command -v ssh-keygen >/dev/null 2>&1 || { echo "CANNOT RUN: ssh-keygen not on PATH"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ME="$(id -un)"

# A throwaway ed25519 keypair, generated fresh into the temp dir for this run
# only -- never a real credential, and never the repo's own.
KEYS="${WORK}/keys"
mkdir -p "${KEYS}"
ssh-keygen -q -t ed25519 -N '' -C 'elspi-example-hook-test' -f "${KEYS}/id" </dev/null
PUBLINE="$(cat "${KEYS}/id.pub")"

# run_hook <hookdir> [ENV=val ...] -- copies the real hook into <hookdir> so
# its own $(dirname "$0") resolves there (where extra-key.pub, if any, was
# already placed by the caller), then runs it with the same environment
# provision.sh exports for a site hook (deltas/provision.sh:194-199,
# docs/site-layer.md).
#
# Extra assignments (DRY_RUN=1) arrive through "$@", a parameter expansion --
# and bash's own assignment-prefix recognition only fires on LITERAL leading
# words, never on ones produced by expanding "$@" (confirmed: a shell
# function taking `f() { ... A=1 "$@" cmd; }` and called `f C=3` runs `C=3`
# as a command, "command not found", rather than exporting it). `env` parses
# its own argv for NAME=value pairs instead, so it is used here rather than
# bare assignment words.
run_hook() {
	local hookdir="$1"; shift
	mkdir -p "${hookdir}"
	cp "${HOOK_SRC}" "${hookdir}/hook.sh"
	chmod +x "${hookdir}/hook.sh"
	env DELTAS_DIR="${DELTAS_DIR}" SERVICE_USER="${ME}" HOME_DIR="${hookdir}/home" "$@" \
		"${hookdir}/hook.sh"
}

echo "== DRY_RUN=1 with a key present changes nothing =="
D1="${WORK}/case1"
mkdir -p "${D1}/hooks"
cp "${KEYS}/id.pub" "${D1}/hooks/extra-key.pub"
OUT="$(run_hook "${D1}/hooks" DRY_RUN=1 2>&1)"; RC=$?
if [ "${RC}" -ne 0 ]; then
	printf '  FAIL  DRY_RUN=1 run exited %d:\n%s\n' "${RC}" "$(printf '%s' "${OUT}" | sed 's/^/        /')"; FAIL=$((FAIL+1))
elif [ -e "${D1}/hooks/home/.ssh" ]; then
	printf '  FAIL  DRY_RUN=1 created %s/home/.ssh -- it changed the filesystem\n' "${D1}/hooks"; FAIL=$((FAIL+1))
elif ! printf '%s' "${OUT}" | grep -q 'would:.*append'; then
	printf '  FAIL  DRY_RUN=1 did not say what it would append:\n%s\n' "$(printf '%s' "${OUT}" | sed 's/^/        /')"; FAIL=$((FAIL+1))
else
	printf '  ok    DRY_RUN=1: home/.ssh was never created, "would: append" was printed\n'; PASS=$((PASS+1))
fi

echo
echo "== a real run installs the line once, and a second run does not duplicate it =="
D2="${WORK}/case2"
mkdir -p "${D2}/hooks"
cp "${KEYS}/id.pub" "${D2}/hooks/extra-key.pub"
AK="${D2}/hooks/home/.ssh/authorized_keys"

OUT1="$(run_hook "${D2}/hooks" 2>&1)"; RC1=$?
COUNT1="$(grep -cxF -- "${PUBLINE}" "${AK}" 2>/dev/null || echo 0)"
if [ "${RC1}" -ne 0 ]; then
	printf '  FAIL  first real run exited %d:\n%s\n' "${RC1}" "$(printf '%s' "${OUT1}" | sed 's/^/        /')"; FAIL=$((FAIL+1))
elif [ "${COUNT1}" != "1" ]; then
	printf '  FAIL  first real run: authorized_keys has the line %s time(s), want 1\n' "${COUNT1}"; FAIL=$((FAIL+1))
else
	PERM_DIR="$(stat -c '%a' "${D2}/hooks/home/.ssh" 2>/dev/null || stat -f '%Lp' "${D2}/hooks/home/.ssh")"
	PERM_FILE="$(stat -c '%a' "${AK}" 2>/dev/null || stat -f '%Lp' "${AK}")"
	if [ "${PERM_DIR}" != "700" ] || [ "${PERM_FILE}" != "600" ]; then
		printf '  FAIL  first real run: perms are %s/%s, want 700/600\n' "${PERM_DIR}" "${PERM_FILE}"; FAIL=$((FAIL+1))
	else
		printf '  ok    first real run: line installed once, .ssh 700, authorized_keys 600\n'; PASS=$((PASS+1))
	fi
fi

OUT2="$(run_hook "${D2}/hooks" 2>&1)"; RC2=$?
COUNT2="$(grep -cxF -- "${PUBLINE}" "${AK}" 2>/dev/null || echo 0)"
if [ "${RC2}" -ne 0 ]; then
	printf '  FAIL  second real run exited %d:\n%s\n' "${RC2}" "$(printf '%s' "${OUT2}" | sed 's/^/        /')"; FAIL=$((FAIL+1))
elif [ "${COUNT2}" != "1" ]; then
	printf '  FAIL  second real run: authorized_keys has the line %s time(s), want 1 (not duplicated)\n' "${COUNT2}"; FAIL=$((FAIL+1))
elif ! printf '%s' "${OUT2}" | grep -q 'already in authorized_keys'; then
	printf '  FAIL  second real run: did not say the line was already there:\n%s\n' "$(printf '%s' "${OUT2}" | sed 's/^/        /')"; FAIL=$((FAIL+1))
else
	printf '  ok    second real run: still exactly 1 occurrence, said "already in authorized_keys"\n'; PASS=$((PASS+1))
fi

echo
echo "== no key file: clean no-op, said out loud =="
D3="${WORK}/case3"
mkdir -p "${D3}/hooks"
OUT="$(run_hook "${D3}/hooks" 2>&1)"; RC=$?
if [ "${RC}" -ne 0 ]; then
	printf '  FAIL  no-key run exited %d, want 0:\n%s\n' "${RC}" "$(printf '%s' "${OUT}" | sed 's/^/        /')"; FAIL=$((FAIL+1))
elif [ -e "${D3}/hooks/home/.ssh" ]; then
	printf '  FAIL  no-key run created %s/home/.ssh -- it should have been a pure no-op\n' "${D3}/hooks"; FAIL=$((FAIL+1))
elif ! printf '%s' "${OUT}" | grep -q 'nothing to do'; then
	printf '  FAIL  no-key run did not say "nothing to do":\n%s\n' "$(printf '%s' "${OUT}" | sed 's/^/        /')"; FAIL=$((FAIL+1))
else
	printf '  ok    no extra-key.pub: exited 0, no filesystem change, said "nothing to do"\n'; PASS=$((PASS+1))
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
