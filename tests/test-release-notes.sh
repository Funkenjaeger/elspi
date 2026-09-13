#!/bin/bash
# Prove tools/release-notes.sh both works and can go red.
#
#   tests/test-release-notes.sh
#
# The pinned URL this generator prints is what a person pastes into a GitHub
# release page and then runs -- if the repo slug is wrong the command still
# "looks right" and fails only when someone actually flashes with it, far
# from where the mistake was made. So this checks the generated text, not
# just that the script exits 0, and proves the check itself can fail by
# running it against a deliberately mangled copy.
#
# Runs anywhere bash does. No network, no image, no pi-gen build.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
GEN="${REPO}/tools/release-notes.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
ok()  { echo "  OK    $1"; PASSED=$((PASSED+1)); }
bad() { echo "  FAIL  $1"; FAILED=$((FAILED+1)); }

# expect_red <label> <shell...> -- the command MUST fail
expect_red() {
	local label="$1"; shift
	if ( "$@" ) >"${WORK}/red.out" 2>&1; then
		echo "  MISS  stayed GREEN: ${label}"
		echo "        ^ this property is NOT actually enforced."
		sed 's/^/           /' "${WORK}/red.out"
		FAILED=$((FAILED+1))
	else
		ok "went red: ${label}"
		sed -n '$p' "${WORK}/red.out" | sed 's/^/           /'
	fi
}

[ -x "${GEN}" ] || { echo "UNKNOWN: ${GEN} is missing or not executable. NOT a pass."; exit 2; }

TAG="v2026-09-13"
SLUG="Funkenjaeger/elspi"
PINNED_URL="https://github.com/${SLUG}/releases/download/${TAG}/os_list.json"

# ---------------------------------------------------------------------------
echo "== green: default slug, a sample tag =="
OUT="${WORK}/notes.md"
if ! "${GEN}" "${TAG}" >"${OUT}" 2>"${WORK}/notes.err"; then
	echo "  BROKEN the generator FAILED for a plain tag, so nothing below proves anything."
	sed 's/^/           /' "${WORK}/notes.err"
	exit 1
fi
ok "generator exited 0 for tag ${TAG}"

# the two command lines, found independently of each other
WIN_LINE="$(grep -F 'rpi-imager --repo' "${OUT}" | grep -F 'cmd /c start' || true)"
LINUX_LINE="$(grep -E '^[[:space:]]*rpi-imager --repo' "${OUT}" || true)"

# check_pinned_url <file> -- the assertion this whole test exists to make:
# the generator's OWN pinned URL, built here independently of the script, must
# appear in both flashing commands.
check_pinned_url() {
	local f="$1"
	local win linux
	win="$(grep -F 'cmd /c start rpi-imager --repo' "${f}" || true)"
	linux="$(grep -E '^[[:space:]]*rpi-imager --repo' "${f}" | grep -vF 'cmd /c start' || true)"
	[ -n "${win}" ] && [ -n "${linux}" ] || return 1
	case "${win}" in *"${PINNED_URL}"*) ;; *) return 1 ;; esac
	case "${linux}" in *"${PINNED_URL}"*) ;; *) return 1 ;; esac
}

if check_pinned_url "${OUT}"; then
	ok "pinned URL (${PINNED_URL}) appears in both commands"
else
	bad "pinned URL missing from one or both commands"
fi

if [ -n "${WIN_LINE}" ]; then
	trimmed="$(printf '%s' "${WIN_LINE}" | sed -E 's/^[[:space:]]+//')"
	case "${trimmed}" in
		"cmd /c start rpi-imager --repo"*) ok "Windows line starts with 'cmd /c start rpi-imager --repo'" ;;
		*) bad "Windows line does not start with 'cmd /c start rpi-imager --repo': ${trimmed}" ;;
	esac
else
	bad "no Windows command line found in the output"
fi

if [ -n "${LINUX_LINE}" ]; then
	trimmed="$(printf '%s' "${LINUX_LINE}" | sed -E 's/^[[:space:]]+//')"
	case "${trimmed}" in
		"rpi-imager --repo"*) ok "Linux line starts with 'rpi-imager --repo'" ;;
		*) bad "Linux line does not start with 'rpi-imager --repo': ${trimmed}" ;;
	esac
else
	bad "no Linux command line found in the output"
fi

# named assets line
if grep -qF 'image_<date>-elspi.img.xz' "${OUT}" \
	&& grep -qF 'os_list.json' "${OUT}" \
	&& grep -qF '<date>-elspi.info' "${OUT}"; then
	ok "required-assets line names the image, os_list.json, and the .info"
else
	bad "required-assets line is missing one of the three asset names"
fi

# ---------------------------------------------------------------------------
echo
echo "== green: --repo-slug overrides the default =="
OUT2="${WORK}/notes-other-slug.md"
OTHER_URL="https://github.com/example-org/example-repo/releases/download/${TAG}/os_list.json"
if "${GEN}" "${TAG}" --repo-slug "example-org/example-repo" >"${OUT2}" 2>"${WORK}/notes2.err"; then
	if grep -qF "${OTHER_URL}" "${OUT2}"; then
		ok "--repo-slug changes the pinned URL"
	else
		bad "--repo-slug given but the pinned URL did not change"
	fi
else
	bad "generator failed with a valid --repo-slug"
	sed 's/^/           /' "${WORK}/notes2.err"
fi

# ---------------------------------------------------------------------------
echo
echo "== red: each of these MUST fail =="

# 1. an empty tag must be refused outright.
expect_red "empty tag (no argument at all)" "${GEN}"
expect_red "empty tag (explicit empty string)" "${GEN}" ""

# 2. a malformed --repo-slug (no "owner/name" slash).
expect_red "--repo-slug with no slash" "${GEN}" "${TAG}" --repo-slug "not-a-slug"

# 3. the assertion itself: run a COPY of the generator with its default slug
#    mangled, and require check_pinned_url to reject what it prints. This is
#    the proof the pass above is actually checking something -- a check_*
#    function that cannot fail is not a check.
SANDBOX="${WORK}/sandbox"
mkdir -p "${SANDBOX}"
cp "${GEN}" "${SANDBOX}/release-notes.sh"
chmod +x "${SANDBOX}/release-notes.sh"
sed -i 's#REPO_SLUG="Funkenjaeger/elspi"#REPO_SLUG="wrong-owner/wrong-repo"#' "${SANDBOX}/release-notes.sh"
if ! grep -qF 'REPO_SLUG="wrong-owner/wrong-repo"' "${SANDBOX}/release-notes.sh"; then
	echo "  UNKNOWN sed did not find the default-slug line to mangle -- skipping this red case"
	FAILED=$((FAILED+1))
else
	"${SANDBOX}/release-notes.sh" "${TAG}" >"${WORK}/mangled.md" 2>"${WORK}/mangled.err" || true
	expect_red "pinned-URL check against a generator with the default slug mangled" \
		check_pinned_url "${WORK}/mangled.md"
	# and prove the SAME check is green on the unmangled output, or it proves nothing
	if check_pinned_url "${OUT}"; then
		ok "the same check passes the unmangled output"
	else
		bad "the check fails the unmangled output too -- it is not measuring the mutation"
	fi
fi

echo
echo "RESULT: ${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ] || exit 1
