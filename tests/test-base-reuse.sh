#!/bin/bash
# The stage0-2 base-reuse decision (elspi-base-reuse.sh), every branch, in
# fake BASE_DIR trees.
#
#   tests/test-base-reuse.sh                  # the repo's helper
#   tests/test-base-reuse.sh path/to/mutant   # a copy of it, to see this go red
#
# WHY. A wrong REUSE ships an image built on a stale or different base, and
# nothing in the image says so; a wrong FULL only costs time. Both are
# decided from files at config-source time, which a real build takes hours to
# reach and cannot be observed from outside -- so the decision is driven here.
#
# EACH TREE IS REAL WHERE IT MATTERS: the repo's own stage0-2, scripts/,
# Dockerfile, elspi.conf, ci.conf, ci-test.conf and stage-elspi/prerun.sh are
# copied in, and the config is passed the way build-docker.sh:139 passes it,
# as a lone file at another path (ci-test.conf -> ci.conf -> elspi.conf).
# Only build.sh is a STUB: it does build.sh:147-169 (BASE_DIR, then source the
# -c config) and :190 (WORK_DIR), then stands in for stage0-2 -- a SKIPped
# stage2 keeps its rootfs, a run one recreates it -- and runs the REAL
# stage-elspi/prerun.sh, with copy_previous and on_chroot stubbed.
#
# NOT covered, and only a real build can cover them: that pi-gen's own
# run_stage honours the SKIPs and CLEAN as elspi-base-reuse.sh's header says
# (build.sh:101-123, read, not executed here), and that a reused base
# produces a working image.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${1:-${REPO}/elspi-base-reuse.sh}"
[ -f "${HELPER}" ] || { echo "UNKNOWN: no helper at ${HELPER}"; exit 2; }
command -v sha256sum >/dev/null || { echo "UNKNOWN: no sha256sum"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
ok()   { echo "  ok    $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "${what}"; else bad "${what}"; fi; }

# --- a fake BASE_DIR ---------------------------------------------------------
make_tree() {
	local t="${WORK}/$1"
	mkdir -p "${t}/pi-gen" "${t}/mnt"
	cp -a "${REPO}/stage0" "${REPO}/stage1" "${REPO}/stage2" "${REPO}/scripts" \
		"${REPO}/Dockerfile" "${REPO}/elspi.conf" "${REPO}/ci.conf" "${REPO}/ci-test.conf" \
		"${t}/pi-gen/"
	rm -f "${t}/pi-gen"/stage[012]/SKIP "${t}/pi-gen"/stage[012]/SKIP_IMAGES
	cp "${HELPER}" "${t}/pi-gen/elspi-base-reuse.sh"
	mkdir -p "${t}/pi-gen/stage-elspi"
	cp -a "${REPO}/stage-elspi/prerun.sh" "${t}/pi-gen/stage-elspi/prerun.sh"
	# build-docker.sh:139 mounts the chosen config ALONE at /config.
	cp "${REPO}/ci-test.conf" "${t}/mnt/config"
	cat > "${t}/pi-gen/build.sh" <<'STUB'
#!/bin/bash -e
# STUB of build.sh: :147-169, :180, :190, then stand-ins for the stages.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_DIR
while getopts "c:" flag; do
	case "$flag" in
		c) source "$OPTARG" ;;
		*) ;;
	esac
done
export ARCH=arm64
export WORK_DIR="${WORK_DIR:-"${BASE_DIR}/work/${IMG_NAME}"}"
echo "STUB CLEAN=${CLEAN:-}"
# stage2: a SKIPped stage keeps its rootfs; a run one is rebuilt (CLEAN).
if [ ! -f "${BASE_DIR}/stage2/SKIP" ]; then
	rm -rf "${WORK_DIR}/stage2/rootfs"
	mkdir -p "${WORK_DIR}/stage2/rootfs/etc"
	echo "base built" > "${WORK_DIR}/stage2/rootfs/etc/marker"
	[ "${STUB_FAIL_IN_STAGE2:-0}" = 1 ] && { echo "STUB stage2 failed"; exit 1; }
fi
# stage-elspi: the REAL prerun, with its rootfs present so copy_previous is
# not reached, and on_chroot recording that it was called.
copy_previous() { echo "STUB copy_previous"; }
on_chroot() { cat > /dev/null; echo "STUB on_chroot"; }
export -f copy_previous on_chroot
export ROOTFS_DIR="${WORK_DIR}/stage-elspi/rootfs"
mkdir -p "${ROOTFS_DIR}"
( cd "${BASE_DIR}/stage-elspi" && ./prerun.sh )
STUB
	chmod +x "${t}/pi-gen/build.sh"
	echo "${t}"
}

# Run the stub build in a tree; output to $t/out.
build() {
	local t="$1"
	shift
	( cd "${t}/pi-gen" && env -u WORK_DIR -u DEPLOY_DIR -u ELSPI_SITE_CONF -u CLEAN \
		-u ELSPI_BASE_MODE -u ELSPI_BASE_FINGERPRINT -u ELSPI_BASE_FP_FILE "$@" \
		./build.sh -c "${t}/mnt/config" ) > "${t}/out" 2>&1
}

fp_of()   { echo "$1/pi-gen/work/elspi/stage2/.elspi-base-fingerprint"; }
logline() { grep -m1 '^elspi base: \(REUSE\|FULL\)' "$1/out"; }
mode_is() { logline "$1" | grep -q "^elspi base: $2 "; }
skips_present() { [ -f "$1/pi-gen/stage0/SKIP" ] && [ -f "$1/pi-gen/stage1/SKIP" ] && [ -f "$1/pi-gen/stage2/SKIP" ]; }
skips_absent()  { [ ! -e "$1/pi-gen/stage0/SKIP" ] && [ ! -e "$1/pi-gen/stage1/SKIP" ] && [ ! -e "$1/pi-gen/stage2/SKIP" ]; }
snapshot() { ( cd "$1" && find . -printf '%p %s %T@ %m\n' | LC_ALL=C sort ); }

echo "== helper under test: ${HELPER}"

# --- 1. no work dir -> FULL, and the finished FULL run records a fingerprint -
echo
echo "== 1. fresh tree: no work dir"
T="$(make_tree fresh)"
mkdir -p "${T}/pi-gen/deploy"
echo stale > "${T}/pi-gen/deploy/image_old-elspi.img.xz"
build "${T}"
echo "     $(logline "${T}")"
check "no work dir -> FULL"                      mode_is "${T}" FULL
check "reason names the missing stage2 rootfs"   grep -q 'FULL (no stage2 rootfs' "${T}/out"
check "CLEAN=1 reached build.sh"                 grep -q '^STUB CLEAN=1$' "${T}/out"
check "no stage SKIP on a FULL run"              skips_absent "${T}"
check "deploy/ emptied (the stale image is gone)" test -z "$(ls -A "${T}/pi-gen/deploy")"
check "FULL run that finished recorded a fingerprint" test -s "$(fp_of "${T}")"
check "no apt refresh on a FULL run"             bash -c "! grep -q 'STUB on_chroot' '${T}/out'"

# --- 2. matching fingerprint -> REUSE; REUSE never rewrites it --------------
echo
echo "== 2. same tree again: fingerprint matches"
touch -d '2 days ago' "$(fp_of "${T}")"
BEFORE="$(stat -c '%Y %s' "$(fp_of "${T}")") $(sha256sum < "$(fp_of "${T}")")"
build "${T}"
echo "     $(logline "${T}")"
check "matching fingerprint -> REUSE"            mode_is "${T}" REUSE
check "log gives the age"                        grep -q 'REUSE (fingerprint match, 2.0 days old)' "${T}/out"
check "stage0-2 SKIP created"                    skips_present "${T}"
check "stage2 rootfs kept (not rebuilt)"         test -f "${T}/pi-gen/work/elspi/stage2/rootfs/etc/marker"
check "CLEAN=1 on REUSE too"                     grep -q '^STUB CLEAN=1$' "${T}/out"
AFTER="$(stat -c '%Y %s' "$(fp_of "${T}")") $(sha256sum < "$(fp_of "${T}")")"
check "REUSE run did NOT rewrite the fingerprint (mtime and content)" test "${BEFORE}" = "${AFTER}"
check "apt lists refreshed on REUSE"             grep -q 'STUB on_chroot' "${T}/out"

# --- 3. over 7 days -> FULL, stale SKIPs removed, fingerprint fresh ---------
echo
echo "== 3. same tree, fingerprint 8 days old (SKIPs left from run 2)"
touch -d '8 days ago' "$(fp_of "${T}")"
check "precondition: stale SKIPs present"        skips_present "${T}"
build "${T}"
echo "     $(logline "${T}")"
check "fingerprint over 7 days old -> FULL"      mode_is "${T}" FULL
check "reason names the age"                     grep -q 'FULL (fingerprint 8.0 days old, limit 7)' "${T}/out"
check "stale SKIPs removed on FULL"              skips_absent "${T}"
check "the FULL run re-recorded it, fresh"       test "$(( $(date +%s) - $(stat -c %Y "$(fp_of "${T}")") ))" -lt 600

# --- 4. a changed stage1 file -> FULL ---------------------------------------
echo
echo "== 4. same tree, a stage1 file changed"
build "${T}"
check "precondition: unchanged tree reuses"      mode_is "${T}" REUSE
echo "# changed" >> "${T}/pi-gen/stage1/prerun.sh"
build "${T}"
echo "     $(logline "${T}")"
check "changed stage1 file -> FULL"              mode_is "${T}" FULL
check "reason is a mismatch"                     grep -q 'FULL (fingerprint mismatch' "${T}/out"
check "SKIPs from the REUSE run removed"         skips_absent "${T}"

# --- 5. a pre-existing stale SKIP on a FULL run is removed -------------------
echo
echo "== 5. fresh tree with stage0-2/SKIP already present"
T5="$(make_tree staleskip)"
touch "${T5}/pi-gen/stage0/SKIP" "${T5}/pi-gen/stage1/SKIP" "${T5}/pi-gen/stage2/SKIP"
build "${T5}"
echo "     $(logline "${T5}")"
check "FULL"                                     mode_is "${T5}" FULL
check "all three stale SKIPs removed"            skips_absent "${T5}"

# --- 6. a FULL run that dies in stage0-2 leaves NO fingerprint ---------------
echo
echo "== 6. REUSE-able tree, inputs change, the FULL run fails in stage2, inputs revert"
T6="$(make_tree failedfull)"
build "${T6}"
cp "${T6}/pi-gen/stage1/prerun.sh" "${WORK}/prerun.orig"
echo "# changed" >> "${T6}/pi-gen/stage1/prerun.sh"
build "${T6}" STUB_FAIL_IN_STAGE2=1
check "precondition: that run was FULL and failed" grep -q 'STUB stage2 failed' "${T6}/out"
check "failed FULL run left no fingerprint"      test ! -e "$(fp_of "${T6}")"
cp "${WORK}/prerun.orig" "${T6}/pi-gen/stage1/prerun.sh"
build "${T6}"
echo "     $(logline "${T6}")"
check "reverted inputs do NOT reuse the half-built base" mode_is "${T6}" FULL

# --- 7. host context: sourcing changes no files ------------------------------
echo
echo "== 7. host context (build-docker.sh:52): no BASE_DIR, under set -eu"
T7="$(make_tree host)"
mkdir -p "${T7}/pi-gen/deploy"
echo keep > "${T7}/pi-gen/deploy/image_x-elspi.img.xz"
S1="$(snapshot "${T7}")"
for c in ci-test.conf ci.conf elspi.conf; do
	got="$(cd "${T7}/pi-gen" && env -u BASE_DIR -u ELSPI_SITE_CONF bash -euc \
		"source ./${c}; echo \"\${DEPLOY_COMPRESSION} \${COMPRESSION_LEVEL} CLEAN=\${CLEAN:-unset} MODE=\${ELSPI_BASE_MODE:-unset}\"" 2>&1)"
	echo "     ${c}: ${got}"
	case "${c}" in
		ci-test.conf) want="xz 1 CLEAN=unset MODE=unset" ;;
		ci.conf)      want="xz 9 CLEAN=unset MODE=unset" ;;
		elspi.conf)   want="xz 6 CLEAN=unset MODE=unset" ;;
	esac
	check "${c} sources on the host: ${want}"    test "${got}" = "${want}"
done
S2="$(snapshot "${T7}")"
check "host-context sourcing changed no files"   test "${S1}" = "${S2}"

# A BASE_DIR that merely happens to be exported, sourced by something other
# than ${BASE_DIR}/build.sh: the helper must still do nothing. (elspi.conf's
# own SKIP_IMAGES touch predates this and is not what is tested here.)
( cd "${T7}/pi-gen" && env -u ELSPI_SITE_CONF BASE_DIR="${T7}/pi-gen" bash -euc \
	"source ./ci-test.conf; echo \"MODE=\${ELSPI_BASE_MODE:-unset}\"" ) > "${T7}/out" 2>&1
check "stray BASE_DIR outside build.sh: no decision made" grep -qx 'MODE=unset' "${T7}/out"
check "stray BASE_DIR outside build.sh: deploy/ untouched" test -f "${T7}/pi-gen/deploy/image_x-elspi.img.xz"
check "stray BASE_DIR outside build.sh: no SKIP created" skips_absent "${T7}"

echo
if [ "${FAIL}" -eq 0 ] && [ "${PASS}" -gt 0 ]; then
	echo "RESULT: all ${PASS} checks pass"
	exit 0
fi
echo "RESULT: FAILED -- ${FAIL} of $((PASS + FAIL)) checks"
exit 1
