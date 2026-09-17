#!/bin/bash
# Prove that 02-restore.sh actually REFUSES, rather than merely saying it does.
#
#   tests/test-restore-contract.sh
#
# docs/design/seam.md: "restore refuses to invent data ... the restore contract is the one
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
echo "== --fresh: first commissioning, named on purpose =="

# 1. no flags at all -- still refuses, same as before --fresh existed. This
#    pins the kept hard fail: --fresh must be a deliberate opt-in, and its
#    absence must not change behaviour by one byte.
refuses "no flags at all (kept hard fail, unchanged)"

# 2. --fresh with --config-backup -- mutually exclusive, refused BEFORE
#    either is acted on, naming both so the operator knows which one to drop.
OUT="$("${RESTORE}" --fresh --config-backup "${WORK}/good" 2>&1)"; RC=$?
if [ "${RC}" -eq 0 ]; then
	printf '  FAIL  --fresh with --config-backup\n        it EXITED 0 -- both were accepted\n'
	FAIL=$((FAIL+1))
elif ! printf '%s' "${OUT}" | grep -qi 'mutually exclusive'; then
	printf '  FAIL  --fresh with --config-backup\n        refused, but did not name both as mutually exclusive:\n%s\n' \
		"$(printf '%s' "${OUT}" | sed 's/^/          /')"
	FAIL=$((FAIL+1))
else
	printf '  ok    --fresh with --config-backup refused, naming both\n'
	PASS=$((PASS+1))
fi

# 3. --fresh alone, CONFIG_DIR empty or absent -- true of any machine that is
#    not a provisioned elspi Pi, which is exactly this sandbox (confirmed:
#    resolve_paths falls back to /var/lib/reflex-config, which does not exist
#    here). The restore phase must be skipped entirely -- no root needed,
#    nothing written -- and the UNCOMMISSIONED banner must appear twice: once
#    up front, once in the final summary.
OUT="$("${RESTORE}" --fresh 2>&1)"; RC=$?
BANNERS="$(printf '%s' "${OUT}" | grep -c 'UNCOMMISSIONED')"
if [ "${RC}" -ne 0 ]; then
	printf '  FAIL  --fresh on an empty CONFIG_DIR\n        exited %d, expected 0:\n%s\n' \
		"${RC}" "$(printf '%s' "${OUT}" | sed 's/^/          /')"
	FAIL=$((FAIL+1))
elif [ "${BANNERS}" -lt 2 ]; then
	printf '  FAIL  --fresh on an empty CONFIG_DIR\n        UNCOMMISSIONED banner appeared %s time(s), expected 2:\n%s\n' \
		"${BANNERS}" "$(printf '%s' "${OUT}" | sed 's/^/          /')"
	FAIL=$((FAIL+1))
else
	printf '  ok    --fresh on an empty CONFIG_DIR: restore skipped, banner printed twice\n'
	PASS=$((PASS+1))
fi

# 4. --fresh must refuse if CONFIG_DIR already holds a file. CONFIG_DIR is not
#    an argument the caller controls -- it is resolved by lib.sh from
#    /etc/elspi-image.json or a hardcoded default, and pointing that at a
#    fixture would mean editing lib.sh, which this change does not touch. An
#    unprivileged mount namespace gets a fixture CONFIG_DIR without editing
#    lib.sh, touching the real filesystem, or needing real root: a tmpfs over
#    /var/lib exists only inside the subprocess and is gone when it exits.
#    Where user namespaces are unavailable, this case is SKIPPED rather than
#    faked -- it must not report ok for something it did not check.
if command -v unshare >/dev/null 2>&1 && unshare --mount --map-root-user true 2>/dev/null; then
	NS_OUT="$(unshare --mount --map-root-user bash -c '
		set -u
		mount -t tmpfs tmpfs /var/lib || exit 90
		mkdir -p /var/lib/reflex-config || exit 91
		echo "pre-existing" > /var/lib/reflex-config/pre-existing || exit 92
		BEFORE="$(md5sum /var/lib/reflex-config/pre-existing)"
		SCRIPT_OUT="$('"${RESTORE}"' --fresh 2>&1)"; SCRIPT_RC=$?
		AFTER="$(md5sum /var/lib/reflex-config/pre-existing 2>&1)"
		printf "RC=%s\n" "${SCRIPT_RC}"
		printf "%s\n" "${SCRIPT_OUT}"
		printf "BEFORE=%s\n" "${BEFORE}"
		printf "AFTER=%s\n" "${AFTER}"
	' 2>&1)"; NS_RC=$?
	SCRIPT_RC="$(printf '%s' "${NS_OUT}" | sed -n 's/^RC=//p')"
	BEFORE_HASH="$(printf '%s' "${NS_OUT}" | sed -n 's/^BEFORE=//p')"
	AFTER_HASH="$(printf '%s' "${NS_OUT}" | sed -n 's/^AFTER=//p')"
	if [ "${NS_RC}" -ge 90 ]; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        could not set up the namespace fixture (exit %d):\n%s\n' \
			"${NS_RC}" "$(printf '%s' "${NS_OUT}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif [ "${SCRIPT_RC}" = "0" ]; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        it EXITED 0 -- the directory was not refused\n'
		FAIL=$((FAIL+1))
	elif ! printf '%s' "${NS_OUT}" | grep -qi 'already holds a file'; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        refused, but not for holding a file:\n%s\n' \
			"$(printf '%s' "${NS_OUT}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif [ "${BEFORE_HASH}" != "${AFTER_HASH}" ]; then
		printf '  FAIL  --fresh with a non-empty CONFIG_DIR\n        refused correctly, but the directory changed:\n        before: %s\n        after:  %s\n' \
			"${BEFORE_HASH}" "${AFTER_HASH}"
		FAIL=$((FAIL+1))
	else
		printf '  ok    --fresh with a non-empty CONFIG_DIR: refused, directory untouched (hash matched)\n'
		PASS=$((PASS+1))
	fi
else
	printf '  skip  --fresh with a non-empty CONFIG_DIR (needs unprivileged user namespaces; unavailable here)\n'
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
