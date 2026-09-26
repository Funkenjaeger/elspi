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

# The script needs root for the parts that WRITE, and since 2026-09-23 every
# content gate runs BEFORE need_root. So a non-root run is the honest way to
# test the refusals -- and each case names the REASON it must be refused for.
# Until then these cases matched any 'refus|fatal', and "must run as root"
# (FATAL) satisfied every one of them: the content gates were never reached.
refuses() { # refuses <description> <reason regex> <args...>
	local desc="$1" why="$2"; shift 2
	local out rc
	out="$("${RESTORE}" "$@" 2>&1)"; rc=$?
	if [ "${rc}" -eq 0 ]; then
		printf '  FAIL  %s\n        it EXITED 0 -- the contract is soft\n' "${desc}"
		FAIL=$((FAIL+1))
		return
	fi
	# A refusal must say WHY -- and the right why. An exit code alone, at a
	# lathe, is not a message; a refusal for some other reason is not this one.
	if ! printf '%s' "${out}" | grep -qiE -- "${why}"; then
		printf '  FAIL  %s\n        exited %d but not for /%s/:\n%s\n' \
			"${desc}" "${rc}" "${why}" "$(printf '%s' "${out}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
		return
	fi
	printf '  ok    %s\n' "${desc}"
	PASS=$((PASS+1))
}

# The other side: a capture the CONTENT gates must let through. Non-root, it
# then stops at need_root -- which is exactly the proof it got past them.
passes_content() { # passes_content <description> <args...>
	local desc="$1"; shift
	local out rc
	out="$("${RESTORE}" "$@" 2>&1)"; rc=$?
	if printf '%s' "${out}" | grep -qiE 'no non-empty Els-0|partial capture|REFUSING|not a whole number|below the public minimum'; then
		printf '  FAIL  %s\n        refused on content grounds:\n%s\n' \
			"${desc}" "$(printf '%s' "${out}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	elif [ "${rc}" -ne 0 ] && ! printf '%s' "${out}" | grep -qi 'must run as root'; then
		printf '  FAIL  %s\n        failed for an unexpected reason:\n%s\n' \
			"${desc}" "$(printf '%s' "${out}" | sed 's/^/          /')"
		FAIL=$((FAIL+1))
	else
		printf '  ok    %s\n' "${desc}"
		PASS=$((PASS+1))
	fi
	LAST_OUT="${out}"
}
mkcapture() { # mkcapture <dir> <number of yaml files incl. Els-0.yaml> [--no-axis]
	local d="$1" n="$2" i
	mkdir -p "${d}"
	printf 'els_backlash_steps: 450\nels_cal_last_measured_steps: 375\n' > "${d}/Els-0.yaml"
	[ "${n}" -ge 2 ] && [ "${3:-}" != "--no-axis" ] && printf 'k: 0\n' > "${d}/Axis-0.yaml"
	i=1
	while [ "$(find "${d}" -maxdepth 1 -name '*.yaml' | wc -l)" -lt "${n}" ]; do
		printf 'k: %d\n' "${i}" > "${d}/Other-${i}.yaml"; i=$((i+1))
	done
}

echo "== the refusals that matter =="

# 1. No backup at all. The headline case: silence here means a lathe comes up
#    on defaults.
refuses "no --config-backup at all" 'was not given'

# 2. A path that does not exist.
refuses "--config-backup pointing at nothing" 'does not exist' --config-backup "${WORK}/nope"

# 3. An EMPTY directory. This is the dangerous one: the path exists, so a naive
#    check passes, and the restore "succeeds" having copied nothing.
mkdir -p "${WORK}/empty"
refuses "an empty directory" 'no non-empty Els-0' --config-backup "${WORK}/empty"

# 4. A directory with the right shape but NO Els-0.yaml -- the commissioned
#    geometry missing while everything else is present.
mkdir -p "${WORK}/no-els"
for i in $(seq 1 18); do printf 'k: %d\n' "${i}" > "${WORK}/no-els/Other-${i}.yaml"; done
refuses "18 yaml files but no Els-0.yaml" 'no non-empty Els-0' --config-backup "${WORK}/no-els"

# 5. Els-0.yaml present but EMPTY. A zero-byte file is not a restore point, and
#    `test -f` would accept it.
mkdir -p "${WORK}/empty-els"
for i in $(seq 1 18); do printf 'k: %d\n' "${i}" > "${WORK}/empty-els/Other-${i}.yaml"; done
: > "${WORK}/empty-els/Els-0.yaml"
refuses "Els-0.yaml present but zero bytes" 'no non-empty Els-0' --config-backup "${WORK}/empty-els"

# 6. A PARTIAL capture against a SITE's bar. The public minimum is Els-0.yaml
#    (what reflex itself needs -- see 02-restore.sh's header); a site that
#    knows its machine carries more raises the bar with ELSPI_RESTORE_MIN_YAML,
#    and then a subset is a quiet failure it must refuse.
mkcapture "${WORK}/partial" 4
ELSPI_RESTORE_MIN_YAML=15 refuses "a partial capture (4 files) under a site bar of 15" 'partial capture' --config-backup "${WORK}/partial"
mkcapture "${WORK}/fourteen" 14
ELSPI_RESTORE_MIN_YAML=15 refuses "14 files under a site bar of 15 (one short)" 'partial capture' --config-backup "${WORK}/fourteen"

# 7. The bar can only go UP, and must be a number.
mkcapture "${WORK}/nineteen" 19
ELSPI_RESTORE_MIN_YAML=0 refuses "ELSPI_RESTORE_MIN_YAML=0 (below the public minimum)" 'below the public minimum' --config-backup "${WORK}/nineteen"
ELSPI_RESTORE_MIN_YAML=fifteen refuses "ELSPI_RESTORE_MIN_YAML=fifteen (not a number)" 'not a whole number' --config-backup "${WORK}/nineteen"

echo
echo "== the public minimum, and a site bar that is met =="
# Els-0.yaml alone is what reflex needs: the rest it would default. Passing
# here is the public contract -- and the missing axes are still NAMED.
mkcapture "${WORK}/els-only" 1
passes_content "Els-0.yaml alone passes the public minimum" --config-backup "${WORK}/els-only"
if printf '%s' "${LAST_OUT}" | grep -q 'no Axis-\*.yaml'; then
	printf '  ok    ...and the missing Axis-*.yaml is reported (the app would build identity axes)\n'; PASS=$((PASS+1))
else
	printf '  FAIL  Els-0.yaml alone passed WITHOUT naming the missing Axis-*.yaml:\n%s\n' "$(printf '%s' "${LAST_OUT}" | sed 's/^/          /')"; FAIL=$((FAIL+1))
fi
mkcapture "${WORK}/partial-public" 4
passes_content "a 4-file capture with Els-0.yaml passes when no site bar is set" --config-backup "${WORK}/partial-public"
if printf '%s' "${LAST_OUT}" | grep -q 'no Axis-\*.yaml'; then
	printf '  FAIL  a capture WITH Axis-0.yaml was reported as missing axes\n'; FAIL=$((FAIL+1))
else
	printf '  ok    ...and a capture carrying Axis-*.yaml is not warned about\n'; PASS=$((PASS+1))
fi
mkcapture "${WORK}/fifteen" 15
ELSPI_RESTORE_MIN_YAML=15 passes_content "exactly 15 files under a site bar of 15" --config-backup "${WORK}/fifteen"
ELSPI_RESTORE_MIN_YAML=15 passes_content "19 files under a site bar of 15" --config-backup "${WORK}/nineteen"

echo
echo "== site.env: settings from the site hooks directory (lib.sh load_site_env) =="
# Parsed as DATA: ELSPI_<NAME>=<value> lines only, exported; anything else is
# refused by line number and the file is never sourced.
site_env() { # site_env <dir> -> prints what a phase would then see, or DIED
	( . "${HERE}/../lib.sh"; load_site_env "$1" >/dev/null 2>&1 || exit 0
	  bash -c 'printf "%s|%s\n" "${ELSPI_RESTORE_MIN_YAML:-UNSET}" "${ELSPI_OTHER:-UNSET}"' ) || echo DIED
}
mkdir -p "${WORK}/se-good" "${WORK}/se-none" "${WORK}/se-bad" "${WORK}/se-code"
printf '# a site bar\nELSPI_RESTORE_MIN_YAML=15\n\nELSPI_OTHER=a/b-c.d\n' > "${WORK}/se-good/site.env"
printf 'ELSPI_RESTORE_MIN_YAML=15\nPATH=/tmp/evil\n' > "${WORK}/se-bad/site.env"
printf 'ELSPI_RESTORE_MIN_YAML=$(touch %s/pwned)\n' "${WORK}" > "${WORK}/se-code/site.env"
GOT="$(unset ELSPI_RESTORE_MIN_YAML ELSPI_OTHER; site_env "${WORK}/se-good")"
if [ "${GOT}" = "15|a/b-c.d" ]; then
	printf '  ok    site.env values are exported to what runs next\n'; PASS=$((PASS+1))
else
	printf '  FAIL  site.env: a phase would see %s, want 15|a/b-c.d\n' "${GOT}"; FAIL=$((FAIL+1))
fi
GOT="$(unset ELSPI_RESTORE_MIN_YAML ELSPI_OTHER; site_env "${WORK}/se-none")"
if [ "${GOT}" = "UNSET|UNSET" ]; then
	printf '  ok    no site.env: nothing exported, nothing refused\n'; PASS=$((PASS+1))
else
	printf '  FAIL  no site.env: a phase would see %s\n' "${GOT}"; FAIL=$((FAIL+1))
fi
for c in se-bad se-code; do
	OUT="$( ( . "${HERE}/../lib.sh"; load_site_env "${WORK}/${c}" ) 2>&1 )"; RC=$?
	if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -q 'site.env:[0-9]* is not an ELSPI_'; then
		printf '  ok    site.env with a non-ELSPI_/code line is refused by line number (%s)\n' "${c}"; PASS=$((PASS+1))
	else
		printf '  FAIL  site.env %s was not refused by line:\n%s\n' "${c}" "$(printf '%s' "${OUT}" | sed 's/^/          /')"; FAIL=$((FAIL+1))
	fi
done
if [ -e "${WORK}/pwned" ]; then
	printf '  FAIL  site.env content was EXECUTED\n'; FAIL=$((FAIL+1))
else
	printf '  ok    site.env content is never executed\n'; PASS=$((PASS+1))
fi

echo
echo "== the control: a well-formed capture must NOT be refused for these reasons =="
# Without this, every assertion above is satisfied by a script that refuses
# everything -- which would pass the suite and provision nothing.
mkcapture "${WORK}/good" 19
passes_content "a well-formed capture (19 files) gets past the content gates" --config-backup "${WORK}/good" --dry-run

echo
echo "== --fresh: first commissioning, named on purpose =="

# 1. no flags at all -- still refuses, same as before --fresh existed. This
#    pins the kept hard fail: --fresh must be a deliberate opt-in, and its
#    absence must not change behaviour by one byte.
refuses "no flags at all (kept hard fail, unchanged)" 'was not given' 

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
