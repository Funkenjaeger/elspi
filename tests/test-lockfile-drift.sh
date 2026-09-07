#!/bin/bash
# Has the vendored reflex dependency set drifted from the reflex repo?
#
#   tests/test-lockfile-drift.sh [path-to-reflex-ui-dir]
#
# SEAM.md call 1 accepted a consequence honestly: "the image and the app become
# a version pair. Add a dependency to reflex-ui and the image's venv lacks it,
# so that provision needs network after all." This is the tripwire for that.
#
# stage-elspi/08-venv/files/{pyproject.toml,uv.lock} are COPIES, taken at the
# commit in files/REFLEX_COMMIT. Copies rot. The failure mode is quiet: the
# image builds fine, CI is green, and the gap only shows up as an unexpected
# network fetch during a recovery -- which is the one moment the whole design
# exists to protect.
#
# Exit codes:
#   0  in sync
#   1  DRIFTED -- re-vendor and update REFLEX_COMMIT
#   2  could not measure (reflex checkout not found) -- reported as UNKNOWN,
#      never as success

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VENDOR="${HERE}/../stage-elspi/08-venv/files"

REFLEX_UI="${1:-}"
if [ -z "${REFLEX_UI}" ]; then
	for candidate in "${HERE}/../../reflex/ui" "/c/projects/reflex/ui" "${HOME}/projects/reflex/ui"; do
		[ -f "${candidate}/uv.lock" ] && { REFLEX_UI="${candidate}"; break; }
	done
fi

if [ -z "${REFLEX_UI}" ] || [ ! -f "${REFLEX_UI}/uv.lock" ]; then
	echo "UNKNOWN: no reflex ui checkout found."
	echo "  Pass one explicitly: $0 /path/to/reflex/ui"
	echo "  NOT reporting success -- this check did not run."
	exit 2
fi

echo "vendored : ${VENDOR}"
echo "reflex   : ${REFLEX_UI}"

RC=0
for f in pyproject.toml uv.lock; do
	if [ ! -f "${VENDOR}/${f}" ]; then
		echo "DRIFT: vendored ${f} is missing entirely"
		RC=1
		continue
	fi
	if diff -q "${VENDOR}/${f}" "${REFLEX_UI}/${f}" >/dev/null 2>&1; then
		echo "  in sync: ${f}"
	else
		echo "  DRIFTED: ${f}"
		diff -u "${VENDOR}/${f}" "${REFLEX_UI}/${f}" | head -40
		RC=1
	fi
done

# The recorded commit should still exist in the reflex repo, and should be the
# commit those files came from. A recorded commit that is not an ancestor of
# anything is a sign the files were updated by hand without re-recording.
RECORDED="$(tr -d '[:space:]' < "${VENDOR}/REFLEX_COMMIT" 2>/dev/null || true)"
if [ -z "${RECORDED}" ]; then
	echo "  DRIFTED: REFLEX_COMMIT is empty"
	RC=1
elif git -C "${REFLEX_UI}" rev-parse --verify --quiet "${RECORDED}^{commit}" >/dev/null 2>&1; then
	echo "  recorded commit exists in reflex: ${RECORDED}"
else
	echo "  UNKNOWN: recorded commit ${RECORDED} is not in this reflex checkout"
	echo "           (a shallow clone or a different repo would also do this)"
	[ "${RC}" -eq 0 ] && RC=2
fi

echo
if [ "${RC}" -eq 0 ]; then
	echo "RESULT: in sync"
elif [ "${RC}" -eq 1 ]; then
	echo "RESULT: DRIFTED."
	echo "  Re-vendor:  cp ui/pyproject.toml ui/uv.lock stage-elspi/08-venv/files/"
	echo "              git -C <reflex> rev-parse HEAD > stage-elspi/08-venv/files/REFLEX_COMMIT"
	echo "  Then rebuild the image: the venv is baked, so a stale lock ships stale."
else
	echo "RESULT: UNKNOWN -- could not fully measure. Treat as unverified, not as pass."
fi
exit "${RC}"
