#!/bin/bash
# The USB automount name-sanitizer's CONTRACT, executed rather than grepped.
#
#   tests/test-usb-automount-name.sh
#
# Runs the REAL stage-elspi/13-usb-automount/files/elspi-usb-mount-name
# straight out of the source tree, not a stub -- same reasoning
# tests/test-drm-mode-switcher.sh's header gives: a fixture that reimplements
# the sanitizer only proves its author can copy the logic twice.
#
# ELSPI_MEDIA_ROOT lets this drive the collision check without touching the
# real /media; production callers (the udev rule) never set it.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${REPO}/stage-elspi/13-usb-automount/files/elspi-usb-mount-name"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

ok()  { echo "  ok    $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

if [ ! -f "${HELPER}" ]; then
	echo "UNKNOWN: ${HELPER} not found -- nothing was checked. NOT a pass."
	exit 2
fi

if [ ! -x "${HELPER}" ]; then
	echo "UNKNOWN: ${HELPER} exists but is not executable -- nothing was checked."
	exit 2
fi

# --- syntax -------------------------------------------------------------
if bash -n "${HELPER}" 2>/dev/null; then
	ok "the helper parses"
else
	bad "the helper parses"
	echo "  (refusing to run a script that does not parse)"
	exit 1
fi

# A safe name is exactly what the udev rule's own sanitizer contract
# promises: nothing outside [A-Za-z0-9._-], never empty, never "." or "..".
is_safe_name() { # <name>
	case "$1" in
	""|.|..) return 1 ;;
	esac
	case "$1" in
	*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

run_helper() { # run_helper <label> <kernel> [media-root]
	local label="$1" kernel="$2" root="${3:-${WORK}/media-unused}"
	mkdir -p "${root}"
	ELSPI_MEDIA_ROOT="${root}" "${HELPER}" "${label}" "${kernel}"
}

# --- a label with spaces and slashes gives a safe name -----------------
NAME="$(run_helper 'My Stick/Data 2026' sda1)"
if is_safe_name "${NAME}"; then
	ok "label with spaces and slashes -> safe name ('${NAME}')"
else
	bad "label with spaces and slashes -> safe name (got '${NAME}')"
fi
case "${NAME}" in
*" "*|*"/"*)
	bad "sanitized name still carries a space or slash ('${NAME}')"
	;;
*)
	ok "sanitized name carries no space or slash ('${NAME}')"
	;;
esac

# --- an empty label falls back to the kernel name -----------------------
NAME="$(run_helper '' sdb1)"
if [ "${NAME}" = "sdb1" ]; then
	ok "empty label -> falls back to the kernel name ('${NAME}')"
else
	bad "empty label -> falls back to the kernel name (got '${NAME}', wanted 'sdb1')"
fi

# A label of nothing but characters the sanitizer strips (collapses to an
# all-underscore run) is not a label a human chose either -- same fallback.
NAME="$(run_helper '***' sdc1)"
if [ "${NAME}" = "sdc1" ]; then
	ok "label of only stripped characters -> falls back to the kernel name ('${NAME}')"
else
	bad "label of only stripped characters -> falls back to the kernel name (got '${NAME}', wanted 'sdc1')"
fi

# --- two sticks with the same label get distinct names -------------------
ROOT="${WORK}/media-collide"
mkdir -p "${ROOT}"
NAME1="$(run_helper 'STICK' sdd1 "${ROOT}")"
mkdir -p "${ROOT}/${NAME1}"   # simulate the first one actually being mounted
NAME2="$(run_helper 'STICK' sde1 "${ROOT}")"

if [ -n "${NAME1}" ] && [ -n "${NAME2}" ] && [ "${NAME1}" != "${NAME2}" ]; then
	ok "two sticks with the same label get distinct names ('${NAME1}' vs '${NAME2}')"
else
	bad "two sticks with the same label get distinct names (got '${NAME1}' and '${NAME2}')"
fi
if is_safe_name "${NAME2}"; then
	ok "the second (collision) name is itself safe ('${NAME2}')"
else
	bad "the second (collision) name is itself safe (got '${NAME2}')"
fi

# A third stick with the same label must not collide with EITHER of the
# first two.
mkdir -p "${ROOT}/${NAME2}"
NAME3="$(run_helper 'STICK' sdf1 "${ROOT}")"
if [ "${NAME3}" != "${NAME1}" ] && [ "${NAME3}" != "${NAME2}" ]; then
	ok "a third same-label stick gets a name distinct from both prior ones ('${NAME3}')"
else
	bad "a third same-label stick collides with an earlier name (got '${NAME3}')"
fi

# --- a label of '..' never escapes /media ---------------------------------
# is_safe_name() alone is NOT enough of an assertion here: the collision
# loop's `[ -e "${MEDIA_ROOT}/${name}" ]` check treats MEDIA_ROOT/.. as
# "taken" too (it is the real parent directory, and it always exists), so
# even a helper with NO explicit dot-guard at all produces something like
# '..-2' -- which passes a charset-only safety check by accident, on the
# very first call, with nothing else plugged in. That accidental rescue is
# a real belt-and-suspenders effect worth keeping, but it must not be
# mistaken for proof the deliberate guard exists. So this asserts the
# PRECISE documented fallback (the sanitized kernel name), which only a
# real guard produces, in addition to the charset check.
NAME="$(run_helper '..' sdg1)"
if [ "${NAME}" = "sdg1" ]; then
	ok "label '..' -> falls back to the kernel name exactly ('${NAME}')"
else
	bad "label '..' -> falls back to the kernel name exactly (got '${NAME}', wanted 'sdg1')"
fi
if is_safe_name "${NAME}"; then
	ok "label '..' -> safe name, not '..' itself ('${NAME}')"
else
	bad "label '..' -> safe name, not '..' itself (got '${NAME}')"
fi
# Belt and suspenders: resolve /media/<name> and confirm it cannot land
# outside the media root, the way /media/.. would.
ROOT2="${WORK}/media-dotdot"
mkdir -p "${ROOT2}"
RESOLVED="$(cd "${ROOT2}" && mkdir -p "${NAME}" 2>/dev/null && cd "${NAME}" 2>/dev/null && pwd)"
case "${RESOLVED}" in
"${ROOT2}"/*|"${ROOT2}")
	ok "resolved mount path stays inside the media root ('${RESOLVED}')"
	;;
*)
	bad "resolved mount path escaped the media root (got '${RESOLVED}')"
	;;
esac

# A label of '.' is the same trap with a shorter name.
NAME="$(run_helper '.' sdh1)"
if [ "${NAME}" = "sdh1" ]; then
	ok "label '.' -> falls back to the kernel name exactly ('${NAME}')"
else
	bad "label '.' -> falls back to the kernel name exactly (got '${NAME}', wanted 'sdh1')"
fi
if is_safe_name "${NAME}"; then
	ok "label '.' -> safe name, not '.' itself ('${NAME}')"
else
	bad "label '.' -> safe name, not '.' itself (got '${NAME}')"
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
