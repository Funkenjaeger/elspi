#!/bin/bash
# Every *-run.sh in our stage must be executable IN GIT'S INDEX.
#
#   tests/test-run-scripts-executable.sh
#
# WHY THIS IS ITS OWN TEST: build.sh line 68 reads
#
#     if [ -x ${i}-run.sh ]; then
#
# A run script without the executable bit is SILENTLY SKIPPED. No warning, no
# error, exit 0, and the build "succeeds" -- having simply not done that
# substage. Lose the bit on 03-boot-config and you get an image with SPI off
# and a serial getty on the Modbus line, and nothing anywhere says so.
#
# This is exactly the failure shape the estate's own rule names: a script that
# claims an effect must gate on a signal that could have come out differently.
# Here the signal is a file mode, and the thing that eats it is Git for
# Windows, where the working-tree mode is not authoritative -- so this checks
# THE INDEX, not the filesystem. Checking the filesystem on Windows would be a
# check that cannot fail.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO}" || exit 2

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	echo "UNKNOWN: not a git repository, cannot read index modes. NOT a pass."
	exit 2
fi

RC=0
FOUND=0

while read -r mode _ _ path; do
	case "${path}" in
		# build.sh:68 gates *-run.sh on [ -x ] and build.sh:107 gates
		# prerun.sh the same way -- both are silently skipped without it.
		*-run.sh|*/prerun.sh|*/elspi-drm-mode|tests/*.sh)
			FOUND=$((FOUND+1))
			if [ "${mode}" = "100755" ]; then
				echo "  ok        ${path}"
			else
				echo "  NOT EXEC  ${path}  (index mode ${mode})"
				RC=1
			fi
			;;
	esac
done < <(git ls-files --stage)

if [ "${FOUND}" -eq 0 ]; then
	echo "UNKNOWN: no candidate scripts found in the index -- nothing was checked."
	echo "  Treat as unverified. Are the files committed yet?"
	exit 2
fi

echo
if [ "${RC}" -eq 0 ]; then
	echo "RESULT: all ${FOUND} scripts are executable in the index"
else
	echo "RESULT: FAILED. A non-executable *-run.sh is SILENTLY SKIPPED by build.sh."
	echo "  Fix:  git update-index --chmod=+x <path>"
fi
exit "${RC}"
