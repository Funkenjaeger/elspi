#!/bin/bash
# Run stage-elspi/10a-app-checkout FOR REAL, against a synthetic source.
#
#   tests/test-app-checkout-stage.sh
#
# tests/test-release-selection.sh proves the DECISION; tests/verify-image.sh
# and tests/self-test.sh prove the harness catches a bad RESULT. Neither of
# them ever runs the substage, so between them sat the usual gap: a stage that
# is correct in two files and does nothing in the third. This closes it.
#
# NO NETWORK AND NO REFLEX CHECKOUT NEEDED. The source is a synthetic
# repository this script builds, shaped like the reflex monorepo -- ui/,
# fw/scripts/, a couple of release tags and a pre-release. That is the whole
# point of REFLEX_SOURCE being a build parameter rather than a hardcoded URL:
# the thing that makes the build reproducible from a local mirror is the same
# thing that makes it testable from a temp directory.
#
# WHAT IS STUBBED, SAID PLAINLY. `on_chroot` is a pi-gen function and does not
# exist outside a build, so this file defines one. It does NOT emulate a
# chroot: it CAPTURES the script the stage sends and ASSERTS the chown the
# stage claims to perform is really in it, then applies the equivalent inside
# ${ROOTFS_DIR}. So the ownership half is verified as "the stage issues the
# right command", not as "the chroot did the right thing" -- the second is a
# Tier-1 build item and this says so rather than implying otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
STAGE="${REPO}/stage-elspi/10a-app-checkout"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
pass() { echo "  OK    $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED+1)); }

# A FIXED, SYNTHETIC service-user NAME with the INVOKING uid behind it.
# Not `id -un`: the stage builds absolute paths like /home/<user>/projects and
# prints them, and a test whose fake rootfs uses the real invoking username is
# one typo in a ${ROOTFS_DIR} prefix away from operating on the real home
# directory. The uid still has to be the invoking one, because the stage's
# ownership gate reads it out of the fixture's own /etc/passwd and nothing
# here runs as root.
SU="elspitest"
SU_UID="$(id -u)"
SU_GID="$(id -g)"

# --- a synthetic reflex monorepo -------------------------------------------
mksource() { # mksource <name> <tag>...
	local name="$1"; shift
	local d="${WORK}/src-${name}" t
	mkdir -p "${d}/ui/reflex/utils" "${d}/fw/scripts"
	printf '[project]\nname = "reflex"\n' > "${d}/ui/pyproject.toml"
	printf 'PROTOCOL_VERSION = 9\n'       > "${d}/ui/reflex/utils/els_stop_map.py"
	printf '# stub\n'                      > "${d}/fw/scripts/modbus-flash.py"
	printf '# stub\n'                      > "${d}/fw/scripts/reflex_image.py"
	git -C "${d}" init -q
	git -C "${d}" config user.email "stage@example.invalid"
	git -C "${d}" config user.name "elspi stage test"
	git -C "${d}" config commit.gpgsign false
	git -C "${d}" add -A
	git -C "${d}" commit -q -m seed
	for t in "$@"; do
		printf '%s\n' "${t}" >> "${d}/ui/pyproject.toml"
		git -C "${d}" add -A
		git -C "${d}" commit -q -m "${t}"
		git -C "${d}" tag "${t}"
	done
	printf '%s' "${d}"
}

# --- a scratch rootfs, in the state 05-service-user leaves behind -----------
mkrootfs() { # mkrootfs <name> [--no-parent]
	local name="$1" noparent="${2:-}"
	local r="${WORK}/rootfs-${name}"
	mkdir -p "${r}/etc"
	printf 'root:x:0:0:root:/root:/bin/bash\n%s:x:%s:%s::/home/%s:/bin/bash\n' \
		"${SU}" "${SU_UID}" "${SU_GID}" "${SU}" > "${r}/etc/passwd"
	[ "${noparent}" = "--no-parent" ] || mkdir -p "${r}/home/${SU}/projects"
	printf '%s' "${r}"
}

# --- the on_chroot stub, and the assertion that makes it worth having -------
# Exported to the stage as a function; `bash -e ./00-run.sh` would not inherit
# it, so the stage is SOURCED in a subshell instead. Sourcing is also what
# gives this file a chance to see the stage's exit status without a wrapper.
ONCHROOT_LOG=""
run_stage() { # run_stage <rootfs> <source> [env assignments...] ; output in ${WORK}/out
	local rootfs="$1" src="$2"; shift 2
	ONCHROOT_LOG="${WORK}/onchroot.$$.$RANDOM"
	: > "${ONCHROOT_LOG}"
	(
		export ROOTFS_DIR="${rootfs}"
		export FIRST_USER_NAME="${SU}"
		export REFLEX_SOURCE="${src}"
		local _a
		for _a in "$@"; do export "${_a?}"; done
		# shellcheck disable=SC2317
		on_chroot() {
			local script
			script="$(cat)"
			printf '%s\n' "${script}" >> "${ONCHROOT_LOG}"
			# Apply the OWNERSHIP EFFECT inside the rootfs. The fixture's
			# service user is the invoking uid, so this is close to a no-op --
			# which is exactly why the assertion on ${ONCHROOT_LOG} below is
			# what this test actually leans on, and not this line.
			chown -R -h "${SU_UID}:${SU_GID}" \
				"${ROOTFS_DIR}/home/${FIRST_USER_NAME}/projects/reflex" 2>/dev/null || true
		}
		export ONCHROOT_LOG
		cd "${STAGE}" || exit 99
		# shellcheck source=/dev/null
		. ./00-run.sh
	) >"${WORK}/out" 2>&1
	return $?
}

SRC="$(mksource good v0.9.0 v1.0.0 v1.1.0-rc.1)"

echo "== the happy path: the newest FULL release is cloned in =="
R1="$(mkrootfs happy)"
if run_stage "${R1}" "${SRC}"; then
	pass "the stage ran"
else
	fail "the stage FAILED on a good source:"
	sed 's/^/          /' "${WORK}/out"
fi
APP="${R1}/home/${SU}/projects/reflex"

# THE SELECTION, end to end: v1.1.0-rc.1 is the newest tag and must lose.
if [ -f "${R1}/etc/elspi/reflex-app-release" ] \
	&& [ "$(tr -d '[:space:]' < "${R1}/etc/elspi/reflex-app-release")" = "v1.0.0" ]; then
	pass "recorded the baked release as v1.0.0, not the newer v1.1.0-rc.1"
else
	fail "the recorded release is '$(tr -d '[:space:]' < "${R1}/etc/elspi/reflex-app-release" 2>/dev/null)', expected v1.0.0"
fi

if git -C "${APP}" rev-parse --git-dir >/dev/null 2>&1; then
	pass "the app root is a real git repository"
else
	fail "the app root is not a git repository"
fi

if [ "$(git -C "${APP}" tag 2>/dev/null | wc -l)" -ge 2 ]; then
	pass "it carries tag history ($(git -C "${APP}" tag | wc -l) tags)"
else
	fail "it does not carry tag history"
fi

if [ "$(git -C "${APP}" rev-parse HEAD 2>/dev/null)" = "$(git -C "${APP}" rev-parse 'v1.0.0^{commit}' 2>/dev/null)" ]; then
	pass "HEAD is detached at v1.0.0"
else
	fail "HEAD is not v1.0.0"
fi

# THE EXACT READ docs/design/seam.md names.
if git -C "${APP}" show "v1.0.0:ui/reflex/utils/els_stop_map.py" >/dev/null 2>&1; then
	pass "git show v1.0.0:ui/reflex/utils/els_stop_map.py works in the baked checkout"
else
	fail "git show v1.0.0:ui/reflex/utils/els_stop_map.py failed in the baked checkout"
fi

# THE BUILD SOURCE MUST NOT SHIP. ${SRC} is a temp directory; an image whose
# origin points there can never fetch anything.
ORIGIN="$(git -C "${APP}" remote get-url origin 2>/dev/null)"
case "${ORIGIN}" in
	https://*) pass "origin rewritten to a fetchable URL (${ORIGIN})" ;;
	*)         fail "origin is '${ORIGIN}' -- the build source path shipped" ;;
esac

# The ownership command the stage claims to issue. See the header: this is the
# assertion, the stub's chown is not.
if grep -q "chown -R -h ${SU}:${SU} /home/${SU}/projects/reflex" "${ONCHROOT_LOG}"; then
	pass "the stage issues the chown of the checkout to the service user"
else
	fail "the stage did not issue 'chown -R -h ${SU}:${SU} /home/${SU}/projects/reflex':"
	sed 's/^/          /' "${ONCHROOT_LOG}"
fi

# Re-running a stage is normal on a resumed pi-gen build.
if run_stage "${R1}" "${SRC}"; then
	if [ "$(git -C "${APP}" rev-parse HEAD 2>/dev/null)" = "$(git -C "${APP}" rev-parse 'v1.0.0^{commit}' 2>/dev/null)" ]; then
		pass "the stage is re-runnable and lands on the same release"
	else
		fail "the second pass left HEAD somewhere else"
	fi
else
	fail "the stage is not re-runnable:"
	sed 's/^/          /' "${WORK}/out"
fi

echo
echo "== the guards must fire =="

# No source: the parameter is not optional and there is no built-in URL.
R2="$(mkrootfs nosource)"
if run_stage "${R2}" ""; then
	fail "the stage accepted an empty REFLEX_SOURCE"
elif grep -q "REFLEX_SOURCE is not set" "${WORK}/out"; then
	pass "refused an empty REFLEX_SOURCE, naming the parameter"
else
	fail "refused an empty REFLEX_SOURCE without naming it:"
	sed 's/^/          /' "${WORK}/out"
fi

# A PINNED PRE-RELEASE. The case that makes "full release" mean something: a
# deliberate pin must not be a way round the rule.
R3="$(mkrootfs pinnedrc)"
if run_stage "${R3}" "${SRC}" "REFLEX_RELEASE=v1.1.0-rc.1"; then
	fail "the stage baked a PINNED pre-release (v1.1.0-rc.1)"
elif grep -q "PRE-RELEASE" "${WORK}/out" && grep -q "v1.1.0-rc.1" "${WORK}/out"; then
	pass "refused a pinned pre-release, naming it"
else
	fail "refused a pinned pre-release without naming it:"
	sed 's/^/          /' "${WORK}/out"
fi
if [ -e "${R3}/home/${SU}/projects/reflex" ]; then
	fail "a refused build still left a checkout at the app root"
else
	pass "a refused build leaves nothing at the app root"
fi

# A pinned tag that is well-formed but not in the source.
R4="$(mkrootfs pinnedmissing)"
if run_stage "${R4}" "${SRC}" "REFLEX_RELEASE=v9.9.9"; then
	fail "the stage accepted a release tag the source does not have"
elif grep -q "exist in REFLEX_SOURCE" "${WORK}/out"; then
	pass "refused a well-formed tag the source does not have"
else
	fail "refused a missing tag without saying why:"
	sed 's/^/          /' "${WORK}/out"
fi

# NO FULL RELEASE ANYWHERE. Must stop, not fall back to the branch tip.
SRC_RC="$(mksource onlyrc v1.0.0-rc.1 v1.0.0-rc.2)"
R5="$(mkrootfs onlyrc)"
if run_stage "${R5}" "${SRC_RC}"; then
	fail "the stage baked something from a source with no full release"
elif grep -q "no full release could be selected" "${WORK}/out"; then
	pass "refused a source with no full release, and baked nothing"
else
	fail "refused a source with no full release without saying why:"
	sed 's/^/          /' "${WORK}/out"
fi
if [ -e "${R5}/home/${SU}/projects/reflex" ]; then
	fail "the no-full-release path still left a checkout behind"
else
	pass "the no-full-release path left nothing behind"
fi

# THE PREMISE, ASSERTED NOT ASSUMED. 05-service-user creates and owns the app
# parent; if that ever stops happening, a parent created here would be
# root-owned and the updater could never write it.
R6="$(mkrootfs noparent --no-parent)"
if run_stage "${R6}" "${SRC}"; then
	fail "the stage created the app parent itself instead of refusing"
elif grep -q "does not exist in the rootfs" "${WORK}/out"; then
	pass "refused when 05-service-user had not created the app parent"
else
	fail "refused a missing app parent without naming it:"
	sed 's/^/          /' "${WORK}/out"
fi

echo
echo "== result =="
echo "  ${PASSED} ok, ${FAILED} problems"
echo
echo "  NOT COVERED HERE, stated rather than implied: the real chroot (see the"
echo "  on_chroot note in this file's header), and cloning from the real reflex"
echo "  monorepo. Both are Tier-1 build items."
[ "${FAILED}" -eq 0 ] || exit 1
exit 0
