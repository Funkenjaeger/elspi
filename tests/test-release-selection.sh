#!/bin/bash
# Prove the release SELECTION refuses what it claims to refuse.
#
#   tests/test-release-selection.sh
#
# docs/design/seam.md's 2026-09-21 amendment is one sentence long and the whole
# sentence is a negative: the image ships the latest FULL release, "not a
# development rc.*, not a floating branch". A selection that PICKS correctly on
# a tidy tag list proves almost nothing -- what has to be true is that it
# REFUSES, loudly and by name, on the untidy ones. So every case below hands
# stage-elspi/10a-app-checkout/files/select-release.sh a synthetic repository
# whose tag list is shaped like a way this could go wrong, and asserts the
# answer.
#
# WHY SYNTHETIC REPOSITORIES AND NOT A TABLE OF STRINGS. The selection reads
# its candidates with `git ls-remote`, so a string-only test would exercise the
# regex and skip the part that talks to git -- including the local-path case
# that is the entire reason REFLEX_SOURCE is a parameter. These are real repos
# on disk, read the way a build reads them.
#
# Runs in seconds on any Linux box with git. No network: every "source" here is
# a directory this script just created. Wired into tests/self-test.sh so it is
# actually collected in CI, the same way test-render-release-no-python3.sh is.
#
# IDENTITY IS SET LOCALLY, in throwaway repos that are deleted on exit --
# `git commit` refuses without a user.email and CI runners often have no global
# one. Never `git -c user.email=` on a command: that is how a real commit ends
# up signed as somebody it is not.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SELECT="${HERE}/../stage-elspi/10a-app-checkout/files/select-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

pass() { echo "  OK    $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED+1)); }

if [ ! -f "${SELECT}" ]; then
	echo "FAIL: ${SELECT} does not exist. NOT a pass."
	exit 1
fi

# --- building a source ------------------------------------------------------
# mkrepo <name> <tag>...   -- a repo with one commit per tag, plus branches
#                             main and dev, so "never falls back to a branch
#                             tip" has a tip available to fall back TO. A
#                             negative test against a repo with no branches
#                             would be a check that cannot fail.
mkrepo() {
	local name="$1"; shift
	local d="${WORK}/${name}" t
	mkdir -p "${d}"
	git -C "${d}" init -q
	git -C "${d}" config user.email "selection@example.invalid"
	git -C "${d}" config user.name "elspi selection test"
	git -C "${d}" config commit.gpgsign false
	printf 'seed\n' > "${d}/README"
	git -C "${d}" add -A
	git -C "${d}" commit -q -m seed
	for t in "$@"; do
		printf '%s\n' "${t}" >> "${d}/README"
		git -C "${d}" add -A
		git -C "${d}" commit -q -m "${t}"
		git -C "${d}" tag "${t}"
	done
	# A dev branch with a tip NEWER than every tag: the most tempting thing to
	# fall back to, and the thing that must never be chosen.
	git -C "${d}" checkout -q -b dev
	printf 'unreleased work\n' >> "${d}/README"
	git -C "${d}" add -A
	git -C "${d}" commit -q -m "unreleased"
	printf '%s' "${d}"
}

# --- assertions -------------------------------------------------------------
expect_latest() { # expect_latest <desc> <repo> <expected tag>
	local desc="$1" repo="$2" want="$3" got rc
	got="$(bash "${SELECT}" latest "${repo}" 2>"${WORK}/err")"; rc=$?
	if [ "${rc}" -eq 0 ] && [ "${got}" = "${want}" ]; then
		pass "${desc} -> ${got}"
	else
		fail "${desc}: expected '${want}', got '${got}' (exit ${rc})"
		sed 's/^/          /' "${WORK}/err"
	fi
}

expect_refusal() { # expect_refusal <desc> <repo> <string the message must name>
	local desc="$1" repo="$2" must_name="$3" got rc
	got="$(bash "${SELECT}" latest "${repo}" 2>"${WORK}/err")"; rc=$?
	if [ "${rc}" -eq 0 ]; then
		fail "${desc}: it SELECTED '${got}' instead of refusing"
		return
	fi
	if [ -n "${got}" ]; then
		fail "${desc}: refused (exit ${rc}) but still printed '${got}' on stdout"
		return
	fi
	# LOUDLY AND BY NAME is the requirement, so the message is asserted, not
	# just the exit status. A silent exit 1 three hours into a build is the
	# failure mode this is protecting against.
	if ! grep -q "REFUSED" "${WORK}/err"; then
		fail "${desc}: refused, but the message does not say REFUSED:"
		sed 's/^/          /' "${WORK}/err"
		return
	fi
	if ! grep -qF "${must_name}" "${WORK}/err"; then
		fail "${desc}: the refusal does not name '${must_name}':"
		sed 's/^/          /' "${WORK}/err"
		return
	fi
	pass "${desc} (refused, naming '${must_name}')"
}

expect_check_refusal() { # expect_check_refusal <tag> <string the message must name>
	local tag="$1" must_name="$2" got rc
	got="$(bash "${SELECT}" check "${tag}" 2>"${WORK}/err")"; rc=$?
	if [ "${rc}" -eq 0 ]; then
		fail "check '${tag}': ACCEPTED it (printed '${got}')"
		return
	fi
	if grep -q "REFUSED" "${WORK}/err" && grep -qF "${must_name}" "${WORK}/err"; then
		pass "check '${tag}' refused, naming '${must_name}'"
	else
		fail "check '${tag}' refused without naming '${must_name}':"
		sed 's/^/          /' "${WORK}/err"
	fi
}

expect_check_ok() { # expect_check_ok <tag>
	local tag="$1" got rc
	got="$(bash "${SELECT}" check "${tag}" 2>"${WORK}/err")"; rc=$?
	if [ "${rc}" -eq 0 ] && [ "${got}" = "${tag}" ]; then
		pass "check '${tag}' accepted"
	else
		fail "check '${tag}': expected acceptance, got exit ${rc} / '${got}'"
		sed 's/^/          /' "${WORK}/err"
	fi
}

echo "== the case tonight: a full release alongside newer pre-releases =="
# The real reflex tag list as of 2026-09-22, trimmed to the v* namespace:
# v1.1.0 is the newest FULL release; v1.2.0-rc.4 is newer and is an rc.
R_REAL="$(mkrepo real v1.1.0-rc.1 v1.1.0 v1.2.0-rc.4)"
expect_latest "v1.1.0 chosen over the newer v1.2.0-rc.4" "${R_REAL}" "v1.1.0"

echo
echo "== (C) pre-releases and foreign namespaces are refused BY NAME =="
expect_check_refusal "v1.2.0-rc.4"   "PRE-RELEASE"
expect_check_refusal "v1.1.0-rc.1"   "PRE-RELEASE"
expect_check_refusal "v0.3.5-alpha.1" "PRE-RELEASE"
expect_check_refusal "v1.2.0-rc.4"   "v1.2.0-rc.4"
# The half-of-the-pair tags. These are the dangerous ones: they are
# well-formed, they sort, and they look exactly like a release.
expect_check_refusal "ui-v1.0.0"                 "lockstep release namespace"
expect_check_refusal "fw-v2.0.7"                 "lockstep release namespace"
expect_check_refusal "ui-archive/rcp-v1.3.0"     "lockstep release namespace"
expect_check_refusal "main"                      "lockstep release namespace"
expect_check_refusal "v1.1"                      "lockstep release namespace"
expect_check_refusal "1.1.0"                     "lockstep release namespace"
expect_check_ok      "v1.1.0"
expect_check_ok      "v0.0.1"
expect_check_ok      "v12.34.56"

echo
echo "== (E) refuse rather than guess; never a branch tip =="
# Every tag is a pre-release. dev's tip is newer than all of them and is
# exactly what a "just pick something" fallback would reach for.
R_PRE="$(mkrepo onlypre v1.0.0-rc.1 v1.0.0-rc.2 v1.1.0-rc.1)"
expect_refusal "a repo with only pre-releases" "${R_PRE}" "no FULL release tag"
expect_refusal "...and it names the pre-releases it saw" "${R_PRE}" "v1.1.0-rc.1"
expect_refusal "...and it says it is not falling back" "${R_PRE}" "NOT falling back"

# Only half-of-the-pair tags. A "contains a version number" fallback would
# happily bake ui-v1.0.0 here.
R_UIONLY="$(mkrepo uionly ui-v1.0.0 ui-v1.0.0-rc.1 fw-v2.0.7)"
expect_refusal "a repo with only ui-*/fw-* tags" "${R_UIONLY}" "no FULL release tag"

# No tags at all.
R_NOTAGS="$(mkrepo notags)"
expect_refusal "a repo with no tags at all" "${R_NOTAGS}" "no tags at all"

# A source that is not a repository at all must refuse, not select.
mkdir -p "${WORK}/notarepo"
if bash "${SELECT}" latest "${WORK}/notarepo" >"${WORK}/out" 2>"${WORK}/err"; then
	fail "a non-repository source: it SELECTED '$(cat "${WORK}/out")'"
else
	if grep -q "REFUSED: cannot read tags" "${WORK}/err"; then
		pass "a non-repository source is refused with a named cause"
	else
		fail "a non-repository source refused, but not with a named cause:"
		sed 's/^/          /' "${WORK}/err"
	fi
fi

# An empty REFLEX_SOURCE must refuse, and must say the source is a parameter.
if bash "${SELECT}" latest "" >"${WORK}/out" 2>"${WORK}/err"; then
	fail "an empty source: it SELECTED '$(cat "${WORK}/out")'"
elif grep -q "no release source given" "${WORK}/err"; then
	pass "an empty source is refused, naming REFLEX_SOURCE"
else
	fail "an empty source refused without naming the parameter:"
	sed 's/^/          /' "${WORK}/err"
fi

echo
echo "== ordering is NUMERIC, not lexical =="
# The classic: "v1.9.0" > "v1.10.0" as strings, and that is how an image ends
# up shipping a release eight months old.
R_TEN="$(mkrepo ten v1.9.0 v1.10.0)"
expect_latest "v1.10.0 beats v1.9.0 (lexically the other way round)" "${R_TEN}" "v1.10.0"
R_MAJ="$(mkrepo major v1.99.99 v2.0.0)"
expect_latest "v2.0.0 beats v1.99.99" "${R_MAJ}" "v2.0.0"
R_PATCH="$(mkrepo patch v1.0.2 v1.0.10)"
expect_latest "v1.0.10 beats v1.0.2" "${R_PATCH}" "v1.0.10"
# CREATION ORDER MUST NOT MATTER. Tagged newest-first here, so a selection
# that returned "the last tag git listed" or "the newest commit" would pick
# wrong. (git ls-remote sorts refs lexically, which is its own trap: it puts
# v1.10.0 before v1.9.0.)
R_REV="$(mkrepo reversed v2.0.0 v1.0.0)"
expect_latest "creation order does not decide it" "${R_REV}" "v2.0.0"
# A leading zero is read base-10, not octal. `$((08))` is a bash syntax error
# that would abort the selection mid-build.
R_ZERO="$(mkrepo leadingzero v1.08.0 v1.9.0)"
expect_latest "a leading-zero component does not abort the compare" "${R_ZERO}" "v1.9.0"

echo
echo "== the selection does not reach past the v* namespace to win =="
# A full release exists, and so do NEWER-looking foreign tags. The full
# release must still be the answer.
R_MIX="$(mkrepo mixed v1.0.0 ui-v9.9.9 fw-v9.9.9 v1.2.0-rc.9)"
expect_latest "ui-v9.9.9 and fw-v9.9.9 do not outrank v1.0.0" "${R_MIX}" "v1.0.0"

echo
echo "== result =="
echo "  ${PASSED} ok, ${FAILED} problems"
[ "${FAILED}" -eq 0 ] || exit 1
exit 0
