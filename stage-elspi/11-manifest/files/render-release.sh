#!/bin/bash
# render-release.sh -- ONE declaration, TWO renderings.
#
#   render-release.sh generate <rootfs-dir>
#   render-release.sh validate <rootfs-dir>
#
# /etc/elspi-image.json (written by ../00-run.sh) is what the image claims
# about itself, in JSON, because its two consumers (the verification harness,
# the delta layer) already parse JSON. /etc/elspi-release is the SAME data,
# reshaped into os-release's flat KEY=VALUE, for the UI and the reflex
# updater (order 2026-09-14#6) -- neither of which should need a JSON parser
# pulled in for one file.
#
# This script owns the mapping between the two so nobody hand-writes the flat
# file to agree with the JSON by eye, and it is a STANDALONE script rather
# than inline in 00-run.sh for exactly one reason: 00-run.sh needs a real
# pi-gen chroot (ROOTFS_DIR, on_chroot) to MEASURE the values in the first
# place, but rendering the flat file from an already-written JSON needs
# neither. That split is what lets the offline tests drive this on a
# synthetic fixture instead of a 2-3 hour pi-gen build.
#
# Two callers beyond the build:
#   - tests/self-test.sh, on tests/make-fixture.sh's synthetic rootfs. It is
#     "the harness" for the specific properties introduced here (missing
#     file, JSON/flat disagreement, non-integer release) because
#     tests/verify-image.sh is out of this order's bound (2026-09-14#5) and
#     tests/self-test.sh's usual harness (verify-image.sh) does not know
#     about /etc/elspi-release. See REPORT.md.
#   - tests/assert-inside.sh, booted or chrooted, inline (duplicated rather
#     than shelled out to, because assert-inside.sh is copied into the rootfs
#     as a single file and does not carry this one with it).
set -uo pipefail

MODE="${1:-}"
ROOTFS="${2:-}"
if [ -z "${MODE}" ] || [ -z "${2+x}" ]; then
	echo "usage: render-release.sh <generate|validate> <rootfs-dir>" >&2
	exit 2
fi

JSON="${ROOTFS}/etc/elspi-image.json"
FLAT="${ROOTFS}/etc/elspi-release"

# Single point of truth for the JSON->shell-variable mapping, used by both
# subcommands, so "generate" and "validate" cannot quietly drift apart on
# which JSON path feeds which flat key.
jget() { # <python expression fragment starting with ['key']...>
	python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
try:
    v = eval('d' + sys.argv[2])
except Exception:
    sys.exit(1)
print(v)
" "${JSON}" "$1"
}

case "${MODE}" in
generate)
	[ -f "${JSON}" ] || { echo "FATAL: ${JSON} missing -- write the manifest first" >&2; exit 1; }

	IMAGE_RELEASE="$(jget "['image_release']")"        || { echo "FATAL: manifest has no image_release" >&2; exit 1; }
	IMAGE_BUILD="$(jget "['image_build_sha']")"         || { echo "FATAL: manifest has no image_build_sha" >&2; exit 1; }
	IMAGE_DATE="$(jget "['built_utc']")"                || { echo "FATAL: manifest has no built_utc" >&2; exit 1; }
	REFLEX_COMMIT="$(jget "['reflex_lock_commit']")"    || { echo "FATAL: manifest has no reflex_lock_commit" >&2; exit 1; }
	PYTHON_V="$(jget "['runtime_versions']['python']")" || { echo "FATAL: manifest has no runtime_versions.python" >&2; exit 1; }
	KIVY_V="$(jget "['runtime_versions']['kivy']")"     || { echo "FATAL: manifest has no runtime_versions.kivy" >&2; exit 1; }
	UV_V="$(jget "['runtime_versions']['uv']")"         || { echo "FATAL: manifest has no runtime_versions.uv" >&2; exit 1; }

	# os-release SHAPE: KEY=VALUE, one per line, double-quoted the way
	# /etc/os-release does it, so anything that wants to can `. /etc/elspi-release`.
	# ELSPI_IMAGE_RELEASE is left UNQUOTED on purpose -- it is the one field a
	# consumer needs as an integer for a numeric compare, and quoting it would
	# make that a string compare by accident.
	cat > "${FLAT}" <<-RELEASE
	ELSPI_IMAGE_RELEASE=${IMAGE_RELEASE}
	ELSPI_IMAGE_BUILD="${IMAGE_BUILD}"
	ELSPI_IMAGE_DATE="${IMAGE_DATE}"
	ELSPI_REFLEX_COMMIT="${REFLEX_COMMIT}"
	ELSPI_PYTHON="${PYTHON_V}"
	ELSPI_KIVY="${KIVY_V}"
	ELSPI_UV="${UV_V}"
	RELEASE
	echo "  wrote ${FLAT} (release ${IMAGE_RELEASE}, reflex lock ${REFLEX_COMMIT})"
	;;

validate)
	FAIL=0

	if [ ! -f "${FLAT}" ]; then
		echo "FAIL: ${FLAT} does not exist" >&2
		exit 1
	fi
	echo "  found ${FLAT}"

	# Parses as KEY=VALUE: every non-blank, non-comment line matches
	# NAME=... with no stray leading characters.
	BAD_LINES="$(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=.*$|^[[:space:]]*(#.*)?$' "${FLAT}" || true)"
	if [ -n "${BAD_LINES}" ]; then
		echo "FAIL: ${FLAT} has a line that is not KEY=VALUE:" >&2
		echo "${BAD_LINES}" >&2
		FAIL=1
	else
		echo "  parses as KEY=VALUE"
	fi

	# Source it in a SUBSHELL, never in this one, so a malformed file cannot
	# corrupt this script's own variables, and so pulling the values out does
	# not need a second hand-rolled KEY=VALUE parser that could disagree with
	# the first.
	FLAT_RELEASE="$(set -a; . "${FLAT}" 2>/dev/null; printf '%s' "${ELSPI_IMAGE_RELEASE:-}")"
	FLAT_REFLEX="$(set -a; . "${FLAT}" 2>/dev/null; printf '%s' "${ELSPI_REFLEX_COMMIT:-}")"

	case "${FLAT_RELEASE}" in
		''|*[!0-9]*)
			echo "FAIL: ELSPI_IMAGE_RELEASE is not a plain non-negative integer: '${FLAT_RELEASE}'" >&2
			FAIL=1
			;;
		*)
			echo "  ELSPI_IMAGE_RELEASE=${FLAT_RELEASE} is an integer"
			;;
	esac

	if [ ! -f "${JSON}" ]; then
		echo "FAIL: ${JSON} missing -- cannot cross-check against the manifest" >&2
		exit 1
	fi
	JSON_RELEASE="$(jget "['image_release']" 2>/dev/null || true)"
	JSON_REFLEX="$(jget "['reflex_lock_commit']" 2>/dev/null || true)"

	if [ -n "${JSON_RELEASE}" ] && [ "${FLAT_RELEASE}" = "${JSON_RELEASE}" ]; then
		echo "  ELSPI_IMAGE_RELEASE agrees with the manifest (${JSON_RELEASE})"
	else
		echo "FAIL: ELSPI_IMAGE_RELEASE ('${FLAT_RELEASE}') disagrees with the manifest's image_release ('${JSON_RELEASE}')" >&2
		FAIL=1
	fi

	if [ -n "${JSON_REFLEX}" ] && [ "${FLAT_REFLEX}" = "${JSON_REFLEX}" ]; then
		echo "  ELSPI_REFLEX_COMMIT agrees with the manifest (${JSON_REFLEX})"
	else
		echo "FAIL: ELSPI_REFLEX_COMMIT ('${FLAT_REFLEX}') disagrees with the manifest's reflex_lock_commit ('${JSON_REFLEX}')" >&2
		FAIL=1
	fi

	[ "${FAIL}" -eq 0 ]
	;;

*)
	echo "usage: render-release.sh <generate|validate> <rootfs-dir>" >&2
	exit 2
	;;
esac
