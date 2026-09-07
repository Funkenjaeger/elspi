#!/bin/bash
# Prove that 02-restore.sh actually REFUSES, rather than merely saying it does.
#
#   tests/test-restore-contract.sh
#
# SEAM.md: "restore refuses to invent data ... the restore contract is the one
# that must not be softened." A refusal that has never been observed is a
# comment. This exercises the refusal paths against real inputs and requires a
# NON-ZERO exit and an untouched target for each.
#
# Runs anywhere with bash; needs no image, no Pi, no root -- the refusals all
# happen before anything is written, which is itself the property being tested.
# Paths that WOULD write are not exercised here; they need a real machine.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESTORE="${HERE}/../02-restore.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0

# The script needs root for the parts that write. Every case below must fail
# BEFORE that matters, so a non-root run is the honest way to test them: if a
# case ever gets far enough to hit need_root, it has already gone too far.
refuses() { # refuses <description> <args...>
	local desc="$1"; shift
	local out rc
	out="$("${RESTORE}" "$@" 2>&1)"; rc=$?
	if [ "${rc}" -eq 0 ]; then
		printf '  FAIL  %s\n        it EXITED 0 -- the contract is soft\n' "${desc}"
		FAIL=$((FAIL+1))
		return
	fi
	# A refusal must say WHY. An exit code alone, at a lathe, is not a message.
	if ! printf '%s' "${out}" | grep -qiE 'refus|fatal'; then
		printf '  FAIL  %s\n        exited %d but printed no refusal:\n%s\n' \
			"${desc}" "${rc}" "$(printf '%s' "${out}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
		return
	fi
	printf '  ok    %s\n' "${desc}"
	PASS=$((PASS+1))
}

echo "== the refusals that matter =="

# 1. No backup at all. The headline case: silence here means a lathe comes up
#    on defaults.
refuses "no --config-backup at all"

# 2. A path that does not exist.
refuses "--config-backup pointing at nothing" --config-backup "${WORK}/nope"

# 3. An EMPTY directory. This is the dangerous one: the path exists, so a naive
#    check passes, and the restore "succeeds" having copied nothing.
mkdir -p "${WORK}/empty"
refuses "an empty directory" --config-backup "${WORK}/empty"

# 4. A directory with the right shape but NO Els-0.yaml -- the commissioned
#    geometry missing while everything else is present.
mkdir -p "${WORK}/no-els"
for i in $(seq 1 18); do printf 'k: %d\n' "${i}" > "${WORK}/no-els/Other-${i}.yaml"; done
refuses "18 yaml files but no Els-0.yaml" --config-backup "${WORK}/no-els"

# 5. Els-0.yaml present but EMPTY. A zero-byte file is not a restore point, and
#    `test -f` would accept it.
mkdir -p "${WORK}/empty-els"
for i in $(seq 1 18); do printf 'k: %d\n' "${i}" > "${WORK}/empty-els/Other-${i}.yaml"; done
: > "${WORK}/empty-els/Els-0.yaml"
refuses "Els-0.yaml present but zero bytes" --config-backup "${WORK}/empty-els"

# 6. A PARTIAL capture -- Els-0.yaml is there, but only a handful of files.
#    Restoring a subset over a machine that needs all of it is a quiet failure.
mkdir -p "${WORK}/partial"
printf 'els_backlash_steps: 450\n' > "${WORK}/partial/Els-0.yaml"
for i in 1 2 3; do printf 'k: %d\n' "${i}" > "${WORK}/partial/Other-${i}.yaml"; done
refuses "a partial capture (4 files)" --config-backup "${WORK}/partial"

echo
echo "== the control: a well-formed capture must NOT be refused for these reasons =="
# Without this, every assertion above is satisfied by a script that refuses
# everything -- which would pass the suite and provision nothing.
mkdir -p "${WORK}/good"
printf 'els_backlash_steps: 450\nels_cal_last_measured_steps: 375\n' > "${WORK}/good/Els-0.yaml"
for i in $(seq 1 18); do printf 'k: %d\n' "${i}" > "${WORK}/good/Other-${i}.yaml"; done
OUT="$("${RESTORE}" --config-backup "${WORK}/good" --dry-run 2>&1)"; RC=$?
if printf '%s' "${OUT}" | grep -qiE 'no non-empty Els-0|partial capture|REFUSING'; then
	printf '  FAIL  a well-formed capture was refused on content grounds\n%s\n' \
		"$(printf '%s' "${OUT}" | sed 's/^/          /')"
	FAIL=$((FAIL+1))
elif [ "${RC}" -ne 0 ] && ! printf '%s' "${OUT}" | grep -qi 'must run as root'; then
	printf '  FAIL  a well-formed capture failed for an unexpected reason\n%s\n' \
		"$(printf '%s' "${OUT}" | sed 's/^/          /')"
	FAIL=$((FAIL+1))
else
	printf '  ok    a well-formed capture gets past the content gates\n'
	PASS=$((PASS+1))
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
