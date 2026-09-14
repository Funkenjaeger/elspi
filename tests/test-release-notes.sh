#!/bin/bash
# Prove tools/release-notes.sh both works and can go red.
#
#   tests/test-release-notes.sh
#
# THE CONTRACT THIS ENFORCES, revised 2026-09-13:
#
# A release page is BRIEF. It is not a second home for the flashing
# instructions -- docs/flashing.md is the only home, and the release page links
# to it AT THE TAG so the instructions a reader follows are the ones that
# shipped with that image. The generator therefore prints exactly four things:
# one sentence, the two PINNED commands, the link, and the required-assets
# line. Anything longer has started to drift from docs/flashing.md, and a
# duplicate that drifts is worse than a link.
#
# So this file asserts an UPPER BOUND on length and the ABSENCE of the prose
# the old monolithic form carried, as well as the presence of what must be
# there. The pinned URL is the load-bearing one: if the repo slug or tag is
# wrong the command still "looks right" and fails only when someone actually
# flashes with it, far from where the mistake was made. Every presence check is
# proven able to fail by running it against a deliberately mangled copy.
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
DOCS_URL="https://github.com/${SLUG}/blob/${TAG}/docs/flashing.md"

# The brief form is 15 lines. The old monolithic form was 20. The cap is 16:
# tight enough that restoring a paragraph trips it, loose enough that rewording
# the one sentence does not.
MAX_LINES=16

# --- the checks, as functions, so each can be run against a mangled copy -----

# check_pinned_url <file> -- the generator's OWN pinned URL, built here
# independently of the script, must appear in both flashing commands.
check_pinned_url() {
	local f="$1"
	local win linux
	win="$(grep -F 'cmd /c start rpi-imager --repo' "${f}" || true)"
	linux="$(grep -E '^[[:space:]]*rpi-imager --repo' "${f}" | grep -vF 'cmd /c start' || true)"
	[ -n "${win}" ] && [ -n "${linux}" ] || return 1
	case "${win}" in *"${PINNED_URL}"*) ;; *) return 1 ;; esac
	case "${linux}" in *"${PINNED_URL}"*) ;; *) return 1 ;; esac
}

# check_docs_link <file> -- the link must be present AND pinned to the tag.
# A link to /blob/main/ or /blob/master/ would send a reader of an old release
# to today's instructions, which is the failure this pins against.
check_docs_link() {
	local f="$1"
	grep -qF "${DOCS_URL}" "${f}" || return 1
	grep -qE 'https://github\.com/[^)[:space:]]+/blob/(main|master)/docs/flashing\.md' "${f}" \
		&& return 1
	return 0
}

# check_brief <file> -- an upper bound on length, and the absence of the prose
# the old form duplicated out of the flashing instructions.
check_brief() {
	local f="$1" n
	n="$(wc -l <"${f}")"
	[ "${n}" -le "${MAX_LINES}" ] || { echo "    ${n} lines, cap is ${MAX_LINES}" >&2; return 1; }
	# Each of these belongs in docs/flashing.md and nowhere else.
	local phrase
	# There was a fourth phrase here until 2026-09-13: the name of the old
	# root-level flash-session document, which left the repo that day. A
	# forbidden string that nothing can write any more is not a check, so it
	# is dropped rather than left standing to look like one.
	for phrase in 'firstrun.sh' 'customisation page' 'distro packages'; do
		if grep -qF "${phrase}" "${f}"; then
			echo "    duplicates docs/flashing.md prose: '${phrase}'" >&2
			return 1
		fi
	done
	return 0
}

# check_assets <file>
check_assets() {
	local f="$1"
	grep -qF 'image_<date>-elspi.img.xz' "${f}" \
		&& grep -qF 'os_list.json' "${f}" \
		&& grep -qF '<date>-elspi.info' "${f}"
}

# ---------------------------------------------------------------------------
echo "== green: default slug, a sample tag =="
OUT="${WORK}/notes.md"
if ! "${GEN}" "${TAG}" >"${OUT}" 2>"${WORK}/notes.err"; then
	echo "  BROKEN the generator FAILED for a plain tag, so nothing below proves anything."
	sed 's/^/           /' "${WORK}/notes.err"
	exit 1
fi
ok "generator exited 0 for tag ${TAG}"

if check_pinned_url "${OUT}"; then
	ok "pinned URL (${PINNED_URL}) appears in both commands"
else
	bad "pinned URL missing from one or both commands"
fi

if check_docs_link "${OUT}"; then
	ok "links docs/flashing.md at the tag (${DOCS_URL})"
else
	bad "no tag-pinned link to docs/flashing.md"
	grep -n 'flashing' "${OUT}" | sed 's/^/           /'
fi

if check_brief "${OUT}" 2>"${WORK}/brief.err"; then
	ok "brief: $(wc -l <"${OUT}") lines, no duplicated flashing prose"
else
	bad "not the brief form"
	sed 's/^/        /' "${WORK}/brief.err"
fi

if check_assets "${OUT}"; then
	ok "required-assets line names the image, os_list.json, and the .info"
else
	bad "required-assets line is missing one of the three asset names"
fi

WIN_LINE="$(grep -F 'rpi-imager --repo' "${OUT}" | grep -F 'cmd /c start' || true)"
LINUX_LINE="$(grep -E '^[[:space:]]*rpi-imager --repo' "${OUT}" || true)"

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

# ---------------------------------------------------------------------------
echo
echo "== green: --repo-slug overrides the default, in BOTH URLs =="
OUT2="${WORK}/notes-other-slug.md"
OTHER_SLUG="example-org/example-repo"
OTHER_PINNED="https://github.com/${OTHER_SLUG}/releases/download/${TAG}/os_list.json"
OTHER_DOCS="https://github.com/${OTHER_SLUG}/blob/${TAG}/docs/flashing.md"
if "${GEN}" "${TAG}" --repo-slug "${OTHER_SLUG}" >"${OUT2}" 2>"${WORK}/notes2.err"; then
	if grep -qF "${OTHER_PINNED}" "${OUT2}"; then
		ok "--repo-slug changes the pinned os_list URL"
	else
		bad "--repo-slug given but the pinned os_list URL did not change"
	fi
	if grep -qF "${OTHER_DOCS}" "${OUT2}"; then
		ok "--repo-slug changes the docs link too"
	else
		bad "--repo-slug given but the docs link still names another repo"
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

# 3. the presence checks themselves: run a COPY of the generator with its
#    default slug mangled, and require the checks to reject what it prints. A
#    check_* function that cannot fail is not a check.
SANDBOX="${WORK}/sandbox"
mkdir -p "${SANDBOX}"
cp "${GEN}" "${SANDBOX}/release-notes.sh"
chmod +x "${SANDBOX}/release-notes.sh"
sed -i 's#REPO_SLUG="Funkenjaeger/elspi"#REPO_SLUG="wrong-owner/wrong-repo"#' "${SANDBOX}/release-notes.sh"
if ! grep -qF 'REPO_SLUG="wrong-owner/wrong-repo"' "${SANDBOX}/release-notes.sh"; then
	echo "  UNKNOWN sed did not find the default-slug line to mangle -- skipping these red cases"
	FAILED=$((FAILED+1))
else
	"${SANDBOX}/release-notes.sh" "${TAG}" >"${WORK}/mangled.md" 2>"${WORK}/mangled.err" || true
	expect_red "pinned-URL check against a generator with the default slug mangled" \
		check_pinned_url "${WORK}/mangled.md"
	expect_red "docs-link check against the same mangled generator" \
		check_docs_link "${WORK}/mangled.md"
	# and prove the SAME checks are green on the unmangled output, or they
	# prove nothing
	if check_pinned_url "${OUT}" && check_docs_link "${OUT}"; then
		ok "the same two checks pass the unmangled output"
	else
		bad "a check fails the unmangled output too -- it is not measuring the mutation"
	fi
fi

# 4. the brevity check: a copy with one paragraph of the retired prose put back
#    must be rejected. This is the assertion that keeps the release page from
#    growing back into a second copy of docs/flashing.md.
REGROWN="${WORK}/regrown.md"
{
	cat "${OUT}"
	printf '\n%s\n' "Raspberry Pi Imager 2.x from raspberrypi.com is required — distro packages"
	printf '%s\n' "ship 1.x, which seeds a card via \`firstrun.sh\`, and this image ignores that"
	printf '%s\n' "file entirely. Take the one OS entry it offers, then fill in the"
	printf '%s\n' "customisation page (user \`default\`, public-key SSH only, Wi-Fi, country US)."
} >"${REGROWN}"
expect_red "brevity check against the output with a retired paragraph pasted back" \
	check_brief "${REGROWN}"
if check_brief "${OUT}" 2>/dev/null; then
	ok "the same brevity check passes the real output"
else
	bad "the brevity check fails the real output too -- it is not measuring the mutation"
fi

# 5. a docs link that is not pinned to the tag must be rejected.
UNPINNED="${WORK}/unpinned.md"
sed "s#/blob/${TAG}/docs/flashing.md#/blob/main/docs/flashing.md#" "${OUT}" >"${UNPINNED}"
if grep -qF '/blob/main/docs/flashing.md' "${UNPINNED}"; then
	expect_red "docs-link check against a link pinned to main instead of the tag" \
		check_docs_link "${UNPINNED}"
else
	echo "  UNKNOWN could not produce an unpinned variant -- skipping this red case"
	FAILED=$((FAILED+1))
fi

echo
echo "RESULT: ${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ] || exit 1
