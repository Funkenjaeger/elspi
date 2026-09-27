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
# stage2 keeps its rootfs, a run one recreates it with a marker unique to
# that build -- and runs the REAL stage-elspi/prerun.sh on a CLEANed rootfs,
# so copy_previous (scripts/common:34-41, with cp -a for rsync) copies from
# PREV_ROOTFS_DIR=${WORK_DIR}/stage2/rootfs as build.sh:91-92,121-123 set it;
# on_chroot is stubbed.
#
# Sections 9 and 10 cover the 2026-09-26 narrowing: the repo's configs count
# only through the variables that reach stages 0-2, a line guard fails closed
# on anything else, and --print-inputs lists every path that is read (plus
# the helper, section 11). Seen red: (a) against the helper before the
# narrowing, (b)/(c) with the variable hashing dropped, (c2)/(d)/(e) with the
# guard removed, section 10 with an input added to the find but not to the
# list.
#
# Sections 11-13 (2026-09-26): _ELSPI_BASE_VERSION in place of the helper's
# own text, with a pin on its code; the one-shot ADOPT marker; and the last
# good base kept aside by a FULL run and RESTOREd on an exact match. Seen red:
# all of 11-13 against the helper before them; 11(a) with the helper hashed
# raw again; 12 with an adopt dated now, with the marker left in place, and
# with an adopt allowed without a rootfs; 13 with a restore on no fingerprint
# match, with the copy deleted at the FULL start, and with a restore that
# touches the fingerprint.
#
# Section 14 (2026-09-26): THE PACKAGE LAYER, stage-elspi-pkgs, reused on its
# own fingerprint (the base's, its package lists, STAGE_LIST through it) and
# otherwise rebuilt from the base; and STAGE_LIST hashed into the base only
# through stage2. The stub runs the layer's REAL prerun when STAGE_LIST names
# it. Seen red: (c) with the layer's files left out of its fingerprint; (g)
# with its fingerprint kept at the start of a BUILD; (h) with STAGE_LIST
# hashed whole again; (b) with stage-elspi's apt refresh left out for a
# reused layer.
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
	cp -a "${REPO}/stage-elspi-pkgs" "${t}/pi-gen/"
	rm -f "${t}/pi-gen/stage-elspi-pkgs/SKIP"
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
	echo "base built $(date +%s%N) ${RANDOM}" > "${WORK_DIR}/stage2/rootfs/etc/marker"
	[ "${STUB_FAIL_IN_STAGE2:-0}" = 1 ] && { echo "STUB stage2 failed"; exit 1; }
fi
# The stages after stage2: CLEAN=1 removes a run stage's rootfs (build.sh:102-
# 106), and its REAL prerun copies the previous one's in: PREV_ROOTFS_DIR as
# build.sh:91-92,121-123 set it after the previous stage, run or skipped;
# copy_previous as scripts/common:34-41, with cp -a for rsync. on_chroot
# records that it was called.
export PREV_ROOTFS_DIR="${WORK_DIR}/stage2/rootfs"
copy_previous() {
	if [ ! -d "${PREV_ROOTFS_DIR}" ]; then echo "Previous stage rootfs not found"; false; fi
	mkdir -p "${ROOTFS_DIR}"
	cp -a "${PREV_ROOTFS_DIR}/." "${ROOTFS_DIR}/"
	echo "STUB copy_previous from ${PREV_ROOTFS_DIR}"
}
on_chroot() { cat > /dev/null; echo "STUB on_chroot"; }
export -f copy_previous on_chroot
# stage-elspi-pkgs, when STAGE_LIST names it: a SKIPped stage keeps its rootfs;
# a run one is built by its real prerun plus a marker unique to that build,
# standing in for its package installs.
case " ${STAGE_LIST} " in
	*" stage-elspi-pkgs "*)
		if [ ! -f "${BASE_DIR}/stage-elspi-pkgs/SKIP" ]; then
			export ROOTFS_DIR="${WORK_DIR}/stage-elspi-pkgs/rootfs"
			rm -rf "${ROOTFS_DIR}"
			( cd "${BASE_DIR}/stage-elspi-pkgs" && ./prerun.sh )
			echo "pkgs built $(date +%s%N) ${RANDOM}" > "${ROOTFS_DIR}/etc/pkgs-marker"
			[ "${STUB_FAIL_IN_PKGS:-0}" = 1 ] && { echo "STUB pkgs failed"; exit 1; }
		fi
		export PREV_ROOTFS_DIR="${WORK_DIR}/stage-elspi-pkgs/rootfs"
		;;
esac
export ROOTFS_DIR="${WORK_DIR}/stage-elspi/rootfs"
rm -rf "${ROOTFS_DIR}"
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
		-u ELSPI_BASE_MODE -u ELSPI_BASE_FINGERPRINT -u ELSPI_BASE_FP_FILE -u ELSPI_BASE_LASTGOOD \
		-u ELSPI_PKGS_MODE -u ELSPI_PKGS_FINGERPRINT -u ELSPI_PKGS_FP_FILE "$@" \
		./build.sh -c "${t}/mnt/config" ) < /dev/null > "${t}/out" 2>&1
}

fp_of()   { echo "$1/pi-gen/work/elspi/stage2/.elspi-base-fingerprint"; }
logline() { grep -m1 '^elspi base: \(REUSE\|FULL\)' "$1/out"; }
mode_is() { logline "$1" | grep -q "^elspi base: $2 "; }
skips_present() { [ -f "$1/pi-gen/stage0/SKIP" ] && [ -f "$1/pi-gen/stage1/SKIP" ] && [ -f "$1/pi-gen/stage2/SKIP" ]; }
skips_absent()  { [ ! -e "$1/pi-gen/stage0/SKIP" ] && [ ! -e "$1/pi-gen/stage1/SKIP" ] && [ ! -e "$1/pi-gen/stage2/SKIP" ]; }
snapshot() { ( cd "$1" && find . -printf '%p %s %T@ %m\n' | LC_ALL=C sort ); }

# Edit a file by WHOLE LINES, exactly, and fail if the anchor is not there --
# an edit that silently matched nothing would make its check vacuous.
replace_line() {  # file old new
	local f="$1" old="$2" new="$3" line hit=0
	while IFS= read -r line || [ -n "${line}" ]; do
		if [ "${line}" = "${old}" ]; then printf '%s\n' "${new}"; hit=1; else printf '%s\n' "${line}"; fi
	done < "${f}" > "${f}.new"
	mv "${f}.new" "${f}"
	[ "${hit}" = 1 ]
}
insert_before() {  # file anchor new
	local f="$1" anchor="$2" new="$3" line hit=0
	while IFS= read -r line || [ -n "${line}" ]; do
		[ "${line}" = "${anchor}" ] && { printf '%s\n' "${new}"; hit=1; }
		printf '%s\n' "${line}"
	done < "${f}" > "${f}.new"
	mv "${f}.new" "${f}"
	[ "${hit}" = 1 ]
}
reason_is() { grep -q "^elspi base: [A-Z]* ($2" "$1/out"; }
# The package layer's decision line, and its mode.
pkgs_line()    { grep -m1 '^elspi base: package layer \(REUSE\|BUILD\|OFF\) ' "$1/out"; }
pkgs_mode_is() { pkgs_line "$1" | grep -q "^elspi base: package layer $2 "; }
pkgs_reason()  { pkgs_line "$1" | grep -q "^elspi base: package layer [A-Z]* ($2"; }
pkgs_rebuilt_on_kept_base() { mode_is "$1" REUSE && pkgs_mode_is "$1" BUILD && pkgs_reason "$1" 'fingerprint mismatch'; }

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
# Too old to be kept aside as the last good base, so nothing can be restored
# and the question is only whether the half-built one is reused (section 13
# covers the restore).
touch -d '8 days ago' "$(fp_of "${T6}")"
cp "${T6}/pi-gen/stage1/prerun.sh" "${WORK}/prerun.orig"
echo "# changed" >> "${T6}/pi-gen/stage1/prerun.sh"
build "${T6}" STUB_FAIL_IN_STAGE2=1
check "precondition: that run was FULL and failed" grep -q 'STUB stage2 failed' "${T6}/out"
check "failed FULL run left no fingerprint"      test ! -e "$(fp_of "${T6}")"
cp "${WORK}/prerun.orig" "${T6}/pi-gen/stage1/prerun.sh"
build "${T6}"
echo "     $(logline "${T6}")"
check "reverted inputs do NOT reuse the half-built base" mode_is "${T6}" FULL

# --- 7. repo config comments and blanks don't count; odd lines fail closed --
# ci.conf is on the source stack (elspi.conf -> ci.conf -> ci-test.conf, the
# tree's mounted config). The repo's configs are reduced to variable values
# by the guard, which skips whole-line comments and blank lines.
echo
echo "== 7. repo configs: whole-line comments and blank lines don't count"
T7c="$(make_tree confstrip)"
CONF="${T7c}/pi-gen/ci.conf"
build "${T7c}"
check "7 baseline: fresh tree is FULL"            mode_is "${T7c}" FULL

echo "  -- (a) a comment-only change to a config keeps REUSE"
build "${T7c}"
check "precondition: unchanged tree reuses"       mode_is "${T7c}" REUSE
echo "# a brand-new whole-line comment, changes nothing that matters" >> "${CONF}"
build "${T7c}"
echo "     $(logline "${T7c}")"
check "(a) comment-only change -> REUSE"          mode_is "${T7c}" REUSE

echo "  -- (b) a blank-line-only change to a config keeps REUSE"
printf '\n   \n' >> "${CONF}"
build "${T7c}"
echo "     $(logline "${T7c}")"
check "(b) blank-line-only change -> REUSE"       mode_is "${T7c}" REUSE

echo "  -- (c) a TRAILING comment on a settings line is not a plain assignment: the guard forces FULL"
check "(c) anchor present"                        replace_line "${CONF}" 'COMPRESSION_LEVEL=9' 'COMPRESSION_LEVEL=9  # a note'
build "${T7c}"
echo "     $(logline "${T7c}")"
check "(c) trailing comment -> FULL"              mode_is "${T7c}" FULL
check "(c) reason is the config guard"            grep -q 'FULL (config guard: ci.conf:[0-9]*: unclassified statement' "${T7c}/out"
check "(c) a FULL run under a failed guard records no fingerprint" test ! -e "$(fp_of "${T7c}")"

# --- 8. host context: sourcing changes no files ------------------------------
echo
echo "== 8. host context (build-docker.sh:52): no BASE_DIR, under set -eu"
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

# --- 9. the narrowing: only what can reach stages 0-2 counts ----------------
# The repo's configs are reduced to the values of _ELSPI_BASE_VARS, guarded
# by a line scan. Each case edits the tree's copy by whole lines, and each
# edit is itself a check, so an anchor that has moved fails loudly instead of
# testing nothing.
echo
echo "== 9. elspi.conf narrowed to what reaches stages 0-2, and the guard"
T9="$(make_tree narrow)"
EC="${T9}/pi-gen/elspi.conf"
CC="${T9}/pi-gen/ci.conf"
cp "${EC}" "${WORK}/elspi.conf.orig"
cp "${CC}" "${WORK}/ci.conf.orig"
guard_of() { bash "$1/pi-gen/elspi-base-reuse.sh" --check-configs > "$1/guard" 2>&1; }
# Back to the pristine configs, with a base recorded for them.
reset9() {
	cp "${WORK}/elspi.conf.orig" "${EC}"
	cp "${WORK}/ci.conf.orig" "${CC}"
	build "${T9}"
	build "${T9}"
	check "  precondition: pristine tree reuses"  mode_is "${T9}" REUSE
}
# Replace one line of a config, build, expect FULL for the reason given.
expect_full() {  # label file old new reason
	reset9
	check "$1: anchor present"                    replace_line "$2" "$3" "$4"
	build "${T9}"
	echo "     $(logline "${T9}")"
	check "$1 -> FULL"                            mode_is "${T9}" FULL
	check "$1: reason is '$5'"                    reason_is "${T9}" "$5"
}
build "${T9}"
check "9 baseline: fresh tree is FULL"            mode_is "${T9}" FULL
guard_of "${T9}"
check "the repo's own configs pass the guard"     grep -qx 'elspi base: config guard clean' "${T9}/guard"

echo "  -- (a) editing stage-elspi/export-only settings in elspi.conf keeps REUSE"
build "${T9}"
check "precondition: unchanged tree reuses"       mode_is "${T9}" REUSE
check "(a) anchor: COMPRESSION_LEVEL"             replace_line "${EC}" 'COMPRESSION_LEVEL=6' 'COMPRESSION_LEVEL=7'
check "(a) anchor: DEPLOY_COMPRESSION"            replace_line "${EC}" 'DEPLOY_COMPRESSION="xz"' 'DEPLOY_COMPRESSION="gz"'
check "(a) anchor: a message"                     replace_line "${EC}" $'\techo "site build config applied: ${ELSPI_SITE_CONF}"' $'\techo "site config applied: ${ELSPI_SITE_CONF}"'
build "${T9}"
echo "     $(logline "${T9}")"
check "(a) COMPRESSION_LEVEL, DEPLOY_COMPRESSION and a message changed -> REUSE" mode_is "${T9}" REUSE

echo "  -- (b) a variable build.sh exports for stages 0-2 forces FULL"
expect_full "(b) FIRST_USER_NAME"  "${EC}" 'FIRST_USER_NAME="default"'   'FIRST_USER_NAME="operator"'      'fingerprint mismatch'
expect_full "(b) LOCALE_DEFAULT"   "${EC}" 'LOCALE_DEFAULT="en_US.UTF-8"' 'LOCALE_DEFAULT="en_GB.UTF-8"'  'fingerprint mismatch'
expect_full "(b) TIMEZONE_DEFAULT" "${EC}" 'TIMEZONE_DEFAULT="Etc/UTC"'   'TIMEZONE_DEFAULT="Europe/Berlin"' 'fingerprint mismatch'
expect_full "(b) an export elspi.conf performs (REFLEX_RELEASE)" "${EC}" \
	'REFLEX_RELEASE="${REFLEX_RELEASE:-}"' 'REFLEX_RELEASE="${REFLEX_RELEASE:-v9.9.9}"' 'fingerprint mismatch'

echo "  -- (c) STAGE_LIST through stage2 forces FULL (after stage2: section 14)"
expect_full "(c) STAGE_LIST" "${EC}" 'STAGE_LIST="stage0 stage1 stage2 stage-elspi-pkgs stage-elspi"' \
	'STAGE_LIST="stage0 stage2 stage-elspi-pkgs stage-elspi"' 'fingerprint mismatch'

echo "  -- (c2) a base-affecting value set where the decision cannot see it forces FULL"
expect_full "(c2) ci.conf sets LOCALE_DEFAULT after elspi.conf returns" "${CC}" 'COMPRESSION_LEVEL=9' \
	$'COMPRESSION_LEVEL=9\nLOCALE_DEFAULT="C.UTF-8"' 'config guard: ci.conf:[0-9]*: base-affecting LOCALE_DEFAULT'
reset9
printf 'LOCALE_DEFAULT="C.UTF-8"\n' >> "${EC}"
build "${T9}"
echo "     $(logline "${T9}")"
check "(c2) a setting after elspi_base_prepare -> FULL" mode_is "${T9}" FULL
check "(c2) reason names it"                      reason_is "${T9}" 'config guard: elspi.conf:[0-9]*: statement after elspi_base_prepare'

echo "  -- (d) a new export in elspi.conf fails the guard and forces FULL"
reset9
check "(d) anchor present" insert_before "${EC}" 'export ELSPI_USB_MAX_CURRENT ELSPI_SITE_CONF_APPLIED' 'export FOO=bar'
build "${T9}"
echo "     $(logline "${T9}")"
check "(d) export FOO=bar -> FULL"                mode_is "${T9}" FULL
check "(d) reason is the config guard, naming the line" reason_is "${T9}" 'config guard: elspi.conf:[0-9]*: unclassified statement.*: export FOO=bar)'
check "(d) no fingerprint recorded"               test ! -e "$(fp_of "${T9}")"
guard_of "${T9}"
check "(d) --check-configs fails on it"           bash -c "! grep -q 'config guard clean' '${T9}/guard' && grep -q 'export FOO=bar' '${T9}/guard'"
reset9
check "(d2) anchor present" insert_before "${EC}" 'export ELSPI_USB_MAX_CURRENT ELSPI_SITE_CONF_APPLIED' 'export LANG'
build "${T9}"
echo "     $(logline "${T9}")"
check "(d2) a bare export of an unclassified name -> FULL" mode_is "${T9}" FULL
check "(d2) reason: unclassified export LANG"     reason_is "${T9}" 'config guard: elspi.conf:[0-9]*: unclassified export LANG'

echo "  -- (e) a new file side effect in elspi.conf fails the guard and forces FULL"
reset9
check "(e) anchor present" insert_before "${EC}" 'ELSPI_SITE_CONF_APPLIED=0' 'touch "${BASE_DIR}/stage1/x"'
build "${T9}"
echo "     $(logline "${T9}")"
rm -f "${T9}/pi-gen/stage1/x"
check "(e) touch into stage1 -> FULL"             mode_is "${T9}" FULL
check "(e) reason is the config guard"            reason_is "${T9}" 'config guard: elspi.conf:[0-9]*: unclassified statement.*stage1/x'
# One no raw hash can see: it writes into the KEPT base itself.
reset9
check "(e2) anchor present" insert_before "${EC}" 'ELSPI_SITE_CONF_APPLIED=0' 'touch "${BASE_DIR}/work/elspi/stage2/rootfs/etc/tampered"'
build "${T9}"
echo "     $(logline "${T9}")"
check "(e2) a write into the kept stage2 rootfs -> FULL" mode_is "${T9}" FULL
check "(e2) reason is the config guard"           reason_is "${T9}" 'config guard: elspi.conf:'

echo "  -- (f) a site config still counts whole (comment-stripped)"
reset9
SITE="${WORK}/site.conf"
printf '# a private site config\nTIMEZONE_DEFAULT="Etc/UTC"\nSITE_ONLY_KNOB=1\n' > "${SITE}"
build "${T9}" ELSPI_SITE_CONF="${SITE}"
check "(f) precondition: the site config was applied" grep -q '^site build config applied' "${T9}/out"
check "(f) adding a site config -> FULL"          mode_is "${T9}" FULL
build "${T9}" ELSPI_SITE_CONF="${SITE}"
check "(f) precondition: same site config reuses" mode_is "${T9}" REUSE
printf '# another comment\n\n' >> "${SITE}"
build "${T9}" ELSPI_SITE_CONF="${SITE}"
check "(f) comment-only change to the site config -> REUSE" mode_is "${T9}" REUSE
check "(f) anchor present"                        replace_line "${SITE}" 'SITE_ONLY_KNOB=1' 'SITE_ONLY_KNOB=2'
build "${T9}" ELSPI_SITE_CONF="${SITE}"
echo "     $(logline "${T9}")"
check "(f) a site line no stage reads still counts -> FULL" mode_is "${T9}" FULL
check "(f) reason is a mismatch"                  reason_is "${T9}" 'fingerprint mismatch'

# --- 10. --print-inputs: the paths the fingerprint reads, and the helper ---
# Both directions, by behaviour: changing any LISTED path forces FULL (except
# the helper itself, listed for the pre-warm but covered by
# _ELSPI_BASE_VERSION), and changing anything else in the tree keeps REUSE.
# The tree carries extra repo content (export-image, stage3, ...) so the
# second half has something to change. A helper that reads a path it does not
# list fails here.
echo
echo "== 10. --print-inputs lists what the fingerprint reads, and the helper"
T10="$(make_tree inputs)"
P="${T10}/pi-gen"
cp -a "${REPO}/export-image" "${REPO}/stage3" "${REPO}/README.md" "${REPO}/build-docker.sh" "${P}/"
printf 'IMG_NAME="elspi"\n' > "${P}/config"
S1="$(snapshot "${T10}")"
LIST="$(cd / && env -u BASE_DIR -u ELSPI_SITE_CONF bash "${P}/elspi-base-reuse.sh" --print-inputs)"
RC=$?
S2="$(snapshot "${T10}")"
echo "     inputs: $(printf '%s ' ${LIST})"
check "--print-inputs exits 0, off-tree cwd, no BASE_DIR" test "${RC}" = 0
check "--print-inputs created or changed no files" test "${S1}" = "${S2}"
check "--print-inputs lists the private ./config" grep -qx config <<< "${LIST}"
check "--print-inputs ignores a stray BASE_DIR" \
	test "$(cd / && env -u ELSPI_SITE_CONF BASE_DIR=/nonexistent bash "${P}/elspi-base-reuse.sh" --print-inputs)" = "${LIST}"
check "--print-inputs names the site config when set" \
	test "$(ELSPI_SITE_CONF=/somewhere/site.conf bash "${P}/elspi-base-reuse.sh" --print-inputs | tail -n 1)" = /somewhere/site.conf

probe_file() {  # the first regular file at or under $1
	local fs
	if [ -f "$1" ]; then echo "$1"; return; fi
	fs="$(find "$1" -type f | LC_ALL=C sort)"
	echo "${fs%%$'\n'*}"
}
build "${T10}"
build "${T10}"
check "precondition: the tree with extras reuses" mode_is "${T10}" REUSE
NU=0
for e in $(cd "${P}" && ls -A); do
	case "${e}" in work|deploy) continue ;; esac
	grep -qxF -- "${e}" <<< "${LIST}" && continue
	f="$(probe_file "${P}/${e}")"
	[ -n "${f}" ] || continue
	echo ": probe" >> "${f}"
	build "${T10}"
	check "unlisted ${e} changed -> REUSE (not read)" mode_is "${T10}" REUSE
	NU=$((NU + 1))
done
check "probed at least 5 unlisted paths (got ${NU})" test "${NU}" -ge 5
mapfile -t LISTED <<< "${LIST}"
check "at least 10 listed paths (got ${#LISTED[@]})" test "${#LISTED[@]}" -ge 10
for p in "${LISTED[@]}"; do
	f="$(probe_file "${P}/${p}")"
	check "listed ${p} is in the tree"            test -n "${f}"
	[ -n "${f}" ] || continue
	cp -p "${f}" "${WORK}/probe.orig"
	echo ": probe" >> "${f}"
	build "${T10}"
	if [ "${p}" = elspi-base-reuse.sh ]; then
		# Listed for the pre-warm, but not hashed: _ELSPI_BASE_VERSION stands
		# for it (section 11).
		check "listed ${p} changed -> REUSE (listed only; _ELSPI_BASE_VERSION covers it)" mode_is "${T10}" REUSE
	elif [ "${p}" = stage-elspi-pkgs ]; then
		# Read by the package layer's fingerprint, not the base's (section 14).
		check "listed ${p} changed -> base REUSE, package layer BUILD" pkgs_rebuilt_on_kept_base "${T10}"
	else
		check "listed ${p} changed -> FULL"       mode_is "${T10}" FULL
	fi
	cp -p "${WORK}/probe.orig" "${f}"
	build "${T10}"
	build "${T10}"
	check "  ${p} restored -> REUSE again"        mode_is "${T10}" REUSE
done

# --- 11. _ELSPI_BASE_VERSION stands for the helper; a pin forces the choice -
# The helper does not build the base, so its text is not hashed: an edit to
# it keeps REUSE, and only raising _ELSPI_BASE_VERSION forces FULL. So that
# the decision to raise it is made at review rather than forgotten, the
# helper's CODE is pinned here: whole-line comments and blank lines stripped
# (the rule the helper applies to private configs), CRs dropped so the pin
# does not depend on the checkout.
HELPER_PIN=877a9c8be39fd74a8933aaa515ca92fdd981605c4baf491bbdabcf1f56aab43b
echo
echo "== 11. _ELSPI_BASE_VERSION stands for the helper's text"
code_hash() { tr -d '\r' < "$1" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | sha256sum | cut -c1-64; }
pin_ok() {  # file pin
	[ "$(code_hash "$1")" = "$2" ] && return 0
	echo "        the helper's code changed: decide whether _ELSPI_BASE_VERSION must be raised, then update this pin (HELPER_PIN=$(code_hash "$1") in tests/test-base-reuse.sh)"
	return 1
}
pin_fails() { ! pin_ok "$@" > /dev/null; }
check "the helper's code matches HELPER_PIN"      pin_ok "${HELPER}" "${HELPER_PIN}"
SELF_PIN="$(code_hash "${HELPER}")"
cp "${HELPER}" "${WORK}/pin.sh"
printf '\n# a comment-only edit\n   \n\t# an indented one\n' >> "${WORK}/pin.sh"
check "pin: anchor for a mid-file comment"        insert_before "${WORK}/pin.sh" '_ELSPI_BASE_MAX_AGE_S=$((7 * 86400))' '# a mid-file comment'
check "the pin guard passes a comment-only edit"  pin_ok "${WORK}/pin.sh" "${SELF_PIN}"
check "pin: anchor for a code edit"               insert_before "${WORK}/pin.sh" '_ELSPI_BASE_MAX_AGE_S=$((7 * 86400))' '_elspi_base_code_only_edit=1'
check "the pin guard fails a code edit"           pin_fails "${WORK}/pin.sh" "${SELF_PIN}"

T11="$(make_tree version)"
H11="${T11}/pi-gen/elspi-base-reuse.sh"
build "${T11}"
build "${T11}"
check "precondition: unchanged tree reuses"       mode_is "${T11}" REUSE
printf '\n# a comment-only edit to the helper\n' >> "${H11}"
check "(a) anchor: a mid-file comment"            insert_before "${H11}" '_ELSPI_BASE_MAX_AGE_S=$((7 * 86400))' '# a mid-file comment'
build "${T11}"
echo "     $(logline "${T11}")"
check "(a) comment-only edit to the helper -> REUSE" mode_is "${T11}" REUSE
check "(b) anchor: a code line"                   insert_before "${H11}" '_ELSPI_BASE_MAX_AGE_S=$((7 * 86400))' '_elspi_base_code_only_edit=1'
build "${T11}"
echo "     $(logline "${T11}")"
check "(b) code-only edit, version not raised -> REUSE" mode_is "${T11}" REUSE
check "(c) anchor: _ELSPI_BASE_VERSION=2"         replace_line "${H11}" '_ELSPI_BASE_VERSION=2' '_ELSPI_BASE_VERSION=3'
build "${T11}"
echo "     $(logline "${T11}")"
check "(c) raising _ELSPI_BASE_VERSION -> FULL"   mode_is "${T11}" FULL
check "(c) reason is a mismatch"                  reason_is "${T11}" 'fingerprint mismatch'
build "${T11}"
check "(c) the raised version then reuses"        mode_is "${T11}" REUSE

# --- 12. ADOPT: a one-shot marker next to the fingerprint -------------------
wd_of()     { echo "$1/pi-gen/work/elspi"; }
lg_of()     { echo "$1/pi-gen/work/elspi/.elspi-base-lastgood"; }
marker_of() { echo "$1/pi-gen/work/elspi/stage2/.elspi-base-adopt"; }
base_id()   { cat "$1/rootfs/etc/marker" 2>/dev/null; }   # $1: a base dir
mtime()     { stat -c %Y "$1"; }
no_line()   { ! grep -q "$2" "$1/out"; }
fp_stamp()  { echo "$(cat "$1") $(mtime "$1")"; }         # content and mtime
# Never more than one last good copy, nor more than two bases in all.
one_copy_at_most() {
	local n b
	n="$(find "$(wd_of "$1")" -maxdepth 1 -name '.elspi-base-lastgood*' | wc -l)"
	b="$(find "$(wd_of "$1")" -path '*/rootfs/etc/marker' ! -path '*/stage-elspi/*' ! -path '*/stage-elspi-pkgs/*' | wc -l)"
	[ "${n}" -le 1 ] && [ "${b}" -le 2 ]
}
echo
echo "== 12. ADOPT marker: records the current fingerprint on the rootfs present"
T12="$(make_tree adopt)"
W12="$(wd_of "${T12}")"
FP12F="$(fp_of "${T12}")"
EC12="${T12}/pi-gen/elspi.conf"
cp "${EC12}" "${WORK}/elspi.conf.12"
build "${T12}"
FP12="$(cat "${FP12F}")"
ID12="$(base_id "${W12}/stage2")"
check "precondition: the fresh tree recorded a base" test "${#FP12}" = 64

echo "  -- (a) an intact rootfs whose fingerprint a FULL start deleted, and the marker"
rm -f "${FP12F}"
mkdir -p "${W12}/stage2/rootfs/usr"
touch -d '5 days ago' "${W12}/stage2/rootfs/usr"
touch -d '2 days ago' "${W12}/stage2/rootfs/etc"
touch -d '4 days ago' "${W12}/stage2/rootfs"
WANT="$(mtime "${W12}/stage2/rootfs/etc")"
touch "$(marker_of "${T12}")"
build "${T12}"
grep '^elspi base: ADOPT' "${T12}/out" | sed 's/^/     /'
echo "     $(logline "${T12}")"
check "(a) ADOPT logged, naming the fingerprint written and no previous one" \
	grep -q "^elspi base: ADOPT stage2 rootfs as fingerprint ${FP12} (previous: none), dated .* from the stage2 rootfs (newest top-level mtime)$" "${T12}/out"
check "(a) then REUSE"                            mode_is "${T12}" REUSE
check "(a) the base kept its age (2.0 days), not now" reason_is "${T12}" 'fingerprint match, 2.0 days old'
check "(a) stage0-2 SKIP created"                 skips_present "${T12}"
check "(a) the fingerprint file holds the current fingerprint" test "$(cat "${FP12F}")" = "${FP12}"
check "(a) the decision line names that fingerprint" grep -q "^elspi base: REUSE .* fingerprint ${FP12:0:12}$" "${T12}/out"
check "(a) its mtime is the rootfs's newest top-level mtime, not now" test "$(mtime "${FP12F}")" = "${WANT}"
check "(a) the marker is consumed"                test ! -e "$(marker_of "${T12}")"
check "(a) the rootfs adopted is the one that was there" test "$(base_id "${W12}/stage2")" = "${ID12}"

echo "  -- (a2) the next run, without the marker, is a plain REUSE"
BEFORE="$(stat -c '%Y %s' "${FP12F}") $(sha256sum < "${FP12F}")"
build "${T12}"
AFTER="$(stat -c '%Y %s' "${FP12F}") $(sha256sum < "${FP12F}")"
check "(a2) REUSE"                                mode_is "${T12}" REUSE
check "(a2) no ADOPT"                             no_line "${T12}" '^elspi base: ADOPT'
check "(a2) the fingerprint was not rewritten (mtime and content)" test "${BEFORE}" = "${AFTER}"

echo "  -- (b) a previous fingerprint, for other inputs: the adopt keeps ITS age"
ZERO="$(printf '%064d' 0)"
echo "${ZERO}" > "${FP12F}"
touch -d '4 days ago' "${FP12F}"
WANT="$(mtime "${FP12F}")"
touch "$(marker_of "${T12}")"
build "${T12}"
echo "     $(logline "${T12}")"
check "(b) ADOPT names the previous fingerprint" \
	grep -q "^elspi base: ADOPT stage2 rootfs as fingerprint ${FP12} (previous: ${ZERO}), dated .* from the previous fingerprint$" "${T12}/out"
check "(b) then REUSE, 4.0 days old"              reason_is "${T12}" 'fingerprint match, 4.0 days old'
check "(b) the mtime is the previous fingerprint's" test "$(mtime "${FP12F}")" = "${WANT}"
check "(b) the content is the current fingerprint" test "$(cat "${FP12F}")" = "${FP12}"
check "(b) the marker is consumed"                test ! -e "$(marker_of "${T12}")"

echo "  -- (c) the marker without a rootfs: FULL, marker consumed and named"
rm -rf "${W12}/stage2/rootfs"
check "(c) precondition: no last good copy to restore" test ! -e "$(lg_of "${T12}")"
touch "$(marker_of "${T12}")"
build "${T12}"
echo "     $(logline "${T12}")"
check "(c) no rootfs -> FULL"                     mode_is "${T12}" FULL
check "(c) the decision line says the marker was ignored, and why" \
	grep -q "^elspi base: FULL (no stage2 rootfs in ${W12}; adopt marker ignored: no stage2 rootfs in ${W12}) fingerprint " "${T12}/out"
check "(c) no ADOPT"                              no_line "${T12}" '^elspi base: ADOPT'
check "(c) the marker is consumed"                test ! -e "$(marker_of "${T12}")"

echo "  -- (d) the marker under a failed config guard: FULL, marker consumed"
build "${T12}"
check "(d) precondition: the tree reuses"         mode_is "${T12}" REUSE
check "(d) anchor present" insert_before "${EC12}" 'export ELSPI_USB_MAX_CURRENT ELSPI_SITE_CONF_APPLIED' 'export FOO=bar'
touch "$(marker_of "${T12}")"
build "${T12}"
echo "     $(logline "${T12}")"
check "(d) guard failure -> FULL"                 mode_is "${T12}" FULL
check "(d) the decision line says the marker was ignored: config guard failed" \
	grep -q '^elspi base: FULL (config guard: .*; adopt marker ignored: config guard failed)$' "${T12}/out"
check "(d) no ADOPT"                              no_line "${T12}" '^elspi base: ADOPT'
check "(d) the marker is consumed"                test ! -e "$(marker_of "${T12}")"
cp "${WORK}/elspi.conf.12" "${EC12}"

echo "  -- (e) an adopted base already over 7 days old: ADOPT, then FULL on age"
build "${T12}"
build "${T12}"
check "(e) precondition: the tree reuses"         mode_is "${T12}" REUSE
touch -d '9 days ago' "${FP12F}"
touch "$(marker_of "${T12}")"
build "${T12}"
grep '^elspi base: ADOPT' "${T12}/out" | sed 's/^/     /'
echo "     $(logline "${T12}")"
check "(e) the adopt still happens"               grep -q '^elspi base: ADOPT' "${T12}/out"
check "(e) then FULL on age, saying so plainly" \
	grep -q '^elspi base: FULL (fingerprint 9.0 days old, limit 7: the adopted base kept its age, so it is rebuilt) fingerprint ' "${T12}/out"
check "(e) the marker is consumed"                test ! -e "$(marker_of "${T12}")"

# --- 13. the last good base: a FULL that fails never costs it ---------------
echo
echo "== 13. last good base: kept aside by a FULL, restored on an exact match"
T13="$(make_tree lastgood)"
W13="$(wd_of "${T13}")"
LG13="$(lg_of "${T13}")"
FP13F="$(fp_of "${T13}")"
S13="${T13}/pi-gen/stage1/prerun.sh"
EC13="${T13}/pi-gen/elspi.conf"
cp "${S13}" "${WORK}/s13.x"
cp "${EC13}" "${WORK}/elspi.conf.13"
partial_in_stage2() { [ ! -e "${FP13F}" ] && [ -n "$(base_id "${W13}/stage2")" ] && [ "$(base_id "${W13}/stage2")" != "$1" ]; }
build "${T13}"
build "${T13}"
check "precondition: base X reuses"               mode_is "${T13}" REUSE
touch -d '2 days ago' "${FP13F}"
FPX="$(cat "${FP13F}")"
IDX="$(base_id "${W13}/stage2")"
STX="$(fp_stamp "${FP13F}")"

echo "  -- (a) inputs change and the FULL run fails in stage2"
echo "# changed" >> "${S13}"
build "${T13}" STUB_FAIL_IN_STAGE2=1
grep '^elspi base: stage2 base' "${T13}/out" | sed 's/^/     /'
check "(a) precondition: that run was FULL and failed" grep -q 'STUB stage2 failed' "${T13}/out"
check "(a) the FULL start kept the valid base aside" \
	grep -q "^elspi base: stage2 base ${FPX:0:12} kept aside in ${LG13} as the last good base, until this run records its own$" "${T13}/out"
check "(a) the copy is base X"                    test "$(base_id "${LG13}")" = "${IDX}"
check "(a) its fingerprint moved with it, content and mtime unchanged" test "$(fp_stamp "${LG13}/.elspi-base-fingerprint")" = "${STX}"
check "(a) stage2 holds the partial build, with no fingerprint" partial_in_stage2 "${IDX}"
check "(a) one copy at most"                      one_copy_at_most "${T13}"

echo "  -- (b) inputs revert: the next run RESTOREs base X"
cp "${WORK}/s13.x" "${S13}"
build "${T13}"
grep '^elspi base: RESTORE' "${T13}/out" | sed 's/^/     /'
echo "     $(logline "${T13}")"
check "(b) RESTORE logged, with the fingerprint and its age" \
	grep -qx "elspi base: RESTORE last good base, fingerprint ${FPX:0:12}, 2.0 days old, from ${LG13}" "${T13}/out"
check "(b) then REUSE"                            mode_is "${T13}" REUSE
check "(b) at the base's own age, 2.0 days"       reason_is "${T13}" 'fingerprint match, 2.0 days old'
check "(b) stage0-2 SKIP created"                 skips_present "${T13}"
check "(b) stage2/rootfs is base X again, not the partial build" test "$(base_id "${W13}/stage2")" = "${IDX}"
check "(b) copy_previous read it from PREV_ROOTFS_DIR" grep -q "^STUB copy_previous from ${W13}/stage2/rootfs$" "${T13}/out"
check "(b) and stage-elspi got base X"            test "$(cat "${W13}/stage-elspi/rootfs/etc/marker")" = "${IDX}"
check "(b) the restore kept the fingerprint's content and mtime" test "$(fp_stamp "${FP13F}")" = "${STX}"
check "(b) the copy was moved back, not copied"   test ! -e "${LG13}"
check "(b) the REUSE run left the fingerprint alone" grep -q 'REUSE run, fingerprint left untouched' "${T13}/out"

echo "  -- (c) a FULL run that completes deletes the copy"
echo "# changed again" >> "${S13}"
build "${T13}"
check "(c) FULL"                                  mode_is "${T13}" FULL
check "(c) its start kept base X aside"           grep -q "^elspi base: stage2 base ${FPX:0:12} kept aside in ${LG13}" "${T13}/out"
check "(c) once it recorded its own base, the copy was deleted" test ! -e "${LG13}"
check "(c) and it said so"                        grep -qx "elspi base: last good base in ${LG13} deleted, replaced by this run's" "${T13}/out"
check "(c) the new base Y is recorded"            test -s "${FP13F}"
FPY="$(cat "${FP13F}")"
IDY="$(base_id "${W13}/stage2")"

echo "  -- (d) a copy for other inputs is not restored; a partial build never replaces it"
echo "# third" >> "${S13}"
build "${T13}" STUB_FAIL_IN_STAGE2=1
check "(d) precondition: base Y kept aside"       test "$(cat "${LG13}/.elspi-base-fingerprint")" = "${FPY}"
build "${T13}" STUB_FAIL_IN_STAGE2=1
echo "     $(logline "${T13}")"
check "(d) the copy (Y) does not match -> FULL"   mode_is "${T13}" FULL
check "(d) no RESTORE"                            no_line "${T13}" '^elspi base: RESTORE'
check "(d) the partial stage2 did not replace the copy" test "$(cat "${LG13}/.elspi-base-fingerprint") $(base_id "${LG13}")" = "${FPY} ${IDY}"
check "(d) one copy at most"                      one_copy_at_most "${T13}"
build "${T13}"
check "(d) the copy stays until a FULL run records its own base, then goes" test ! -e "${LG13}"
cp "${S13}" "${WORK}/s13.z"

echo "  -- (e) an expired copy is not restored"
FPZ="$(cat "${FP13F}")"
echo "# fourth" >> "${S13}"
build "${T13}" STUB_FAIL_IN_STAGE2=1
check "(e) precondition: base Z kept aside"       test "$(cat "${LG13}/.elspi-base-fingerprint")" = "${FPZ}"
touch -d '8 days ago' "${LG13}/.elspi-base-fingerprint"
cp "${WORK}/s13.z" "${S13}"
build "${T13}"
echo "     $(logline "${T13}")"
check "(e) the copy matches but is 8 days old -> FULL" mode_is "${T13}" FULL
check "(e) no RESTORE"                            no_line "${T13}" '^elspi base: RESTORE'
check "(e) reason: stage2 holds only the partial build" reason_is "${T13}" 'stage2 rootfs has no fingerprint'

echo "  -- (f) a restore and an adopt marker together: the restore wins, the marker is consumed"
build "${T13}"
check "(f) precondition: base Z reuses"           mode_is "${T13}" REUSE
touch -d '1 day ago' "${FP13F}"
FPZ="$(cat "${FP13F}")"
echo "# fifth" >> "${S13}"
build "${T13}" STUB_FAIL_IN_STAGE2=1
cp "${WORK}/s13.z" "${S13}"
touch "$(marker_of "${T13}")"
build "${T13}"
echo "     $(logline "${T13}")"
check "(f) RESTORE fired"                         grep -q "^elspi base: RESTORE last good base, fingerprint ${FPZ:0:12}, 1.0 days old" "${T13}/out"
check "(f) ADOPT did not"                         no_line "${T13}" '^elspi base: ADOPT'
check "(f) the decision line: marker ignored, restore matched" \
	grep -qx "elspi base: REUSE (fingerprint match, 1.0 days old; adopt marker ignored: restore matched) fingerprint ${FPZ:0:12}" "${T13}/out"
check "(f) the marker is consumed"                test ! -e "$(marker_of "${T13}")"

echo "  -- (g) a newer valid base replaces the copy; never more than one"
echo "# sixth" >> "${S13}"
build "${T13}" STUB_FAIL_IN_STAGE2=1
check "(g) precondition: base Z kept aside"       test "$(cat "${LG13}/.elspi-base-fingerprint")" = "${FPZ}"
touch "$(marker_of "${T13}")"
build "${T13}"
check "(g) precondition: the partial stage2 adopted, and reused" \
	bash -c "grep -q '^elspi base: ADOPT' '${T13}/out' && grep -q '^elspi base: REUSE' '${T13}/out'"
FPR="$(cat "${FP13F}")"
check "(g) the adopt left the copy (Z) alone"     test "$(cat "${LG13}/.elspi-base-fingerprint")" = "${FPZ}"
echo "# seventh" >> "${S13}"
build "${T13}" STUB_FAIL_IN_STAGE2=1
check "(g) the newer valid base replaced Z as the copy" test "$(cat "${LG13}/.elspi-base-fingerprint")" = "${FPR}"
check "(g) one copy at most"                      one_copy_at_most "${T13}"

echo "  -- (h) under a failed config guard nothing is kept, and the copy is discarded"
check "(h) anchor present" insert_before "${EC13}" 'export ELSPI_USB_MAX_CURRENT ELSPI_SITE_CONF_APPLIED' 'export FOO=bar'
build "${T13}"
echo "     $(logline "${T13}")"
check "(h) FULL on the guard"                     reason_is "${T13}" 'config guard:'
check "(h) the copy was discarded"                test ! -e "${LG13}"
check "(h) and it said so" \
	grep -q "^elspi base: last good base in ${LG13} discarded: the config guard failed" "${T13}/out"
cp "${WORK}/elspi.conf.13" "${EC13}"
build "${T13}"
build "${T13}"
check "(h2) precondition: the tree reuses"        mode_is "${T13}" REUSE
check "(h2) anchor present" insert_before "${EC13}" 'ELSPI_SITE_CONF_APPLIED=0' 'touch "${BASE_DIR}/work/elspi/stage2/rootfs/etc/tampered"'
build "${T13}"
echo "     $(logline "${T13}")"
check "(h2) a write into the base fails the guard -> FULL" reason_is "${T13}" 'config guard:'
check "(h2) the (tampered) base was not kept aside" test ! -e "${LG13}"
cp "${WORK}/elspi.conf.13" "${EC13}"
build "${T13}"
echo "     $(logline "${T13}")"
check "(h2) nothing is restored afterwards -> FULL" mode_is "${T13}" FULL
check "(h2) no RESTORE"                           no_line "${T13}" '^elspi base: RESTORE'
check "(h2) one copy at most"                     one_copy_at_most "${T13}"

# --- 14. THE PACKAGE LAYER: reused on an exact match, rebuilt from the base ---
echo
echo "== 14. package layer: stage-elspi-pkgs over the base, its own fingerprint"
T14="$(make_tree pkgs)"
W14="$(wd_of "${T14}")"
PK14="${T14}/pi-gen/stage-elspi-pkgs"
L14="${PK14}/00-graphics/00-packages"
EC14="${T14}/pi-gen/elspi.conf"
PFP14="${W14}/stage-elspi-pkgs/.elspi-base-fingerprint"
cp "${L14}" "${WORK}/l14.orig"
cp "${EC14}" "${WORK}/elspi.conf.14"
pkgs_id()  { cat "${W14}/stage-elspi-pkgs/rootfs/etc/pkgs-marker" 2>/dev/null; }
elspi_pk() { cat "${W14}/stage-elspi/rootfs/etc/pkgs-marker" 2>/dev/null; }
pkg_skip() { [ -f "${PK14}/SKIP" ]; }
set_stages() { replace_line "${EC14}" "$(grep '^STAGE_LIST=' "${EC14}")" "STAGE_LIST=\"$1\""; }

echo "  -- (a) fresh tree: the base is FULL, so the layer is BUILT, then recorded"
build "${T14}"
echo "     $(logline "${T14}")"
echo "     $(pkgs_line "${T14}")"
check "(a) base FULL"                             mode_is "${T14}" FULL
check "(a) layer BUILD, because the base is built" pkgs_reason "${T14}" 'the stage2 base under it is built in this run'
check "(a) the layer's rootfs was copied from stage2's" grep -q "^STUB copy_previous from ${W14}/stage2/rootfs$" "${T14}/out"
check "(a) the finished layer recorded its fingerprint" grep -Eq '^[0-9a-f]{64}$' "${PFP14}"
check "(a) and said so"                           grep -q '^elspi base: package layer complete, fingerprint [0-9a-f]\{12\} recorded' "${T14}/out"
check "(a) stage-elspi copied the layer"          test -n "$(pkgs_id)" -a "$(elspi_pk)" = "$(pkgs_id)"
check "(a) no layer SKIP on a BUILD run"          bash -c "! test -e '${PK14}/SKIP'"
PFPA="$(fp_stamp "${PFP14}")"
PIDA="$(pkgs_id)"
BIDA="$(base_id "${W14}/stage2")"

echo "  -- (b) the same tree again: base REUSE, layer REUSE"
build "${T14}"
echo "     $(logline "${T14}")"
echo "     $(pkgs_line "${T14}")"
check "(b) base REUSE"                            mode_is "${T14}" REUSE
check "(b) layer REUSE"                           pkgs_reason "${T14}" 'fingerprint match, 0.0 days old'
check "(b) the layer's SKIP created"              pkg_skip
check "(b) the layer was not rebuilt"             test "$(pkgs_id)" = "${PIDA}"
check "(b) stage-elspi copied the kept layer"     grep -q "^STUB copy_previous from ${W14}/stage-elspi-pkgs/rootfs$" "${T14}/out"
check "(b) and got its packages"                  test "$(elspi_pk)" = "${PIDA}"
check "(b) its fingerprint was not rewritten (content and mtime)" test "$(fp_stamp "${PFP14}")" = "${PFPA}"
check "(b) and it said so"                        grep -q '^elspi base: package layer REUSE run, fingerprint left untouched' "${T14}/out"
check "(b) stage-elspi refreshed its apt lists (it still installs)" grep -q 'STUB on_chroot' "${T14}/out"
build "${T14}"
check "(b2) a third run: still REUSE, its own SKIP not hashed" pkgs_mode_is "${T14}" REUSE

echo "  -- (c) a package list changes: the layer alone is rebuilt, from the kept base"
echo "libfoo-dev" >> "${L14}"
build "${T14}"
echo "     $(logline "${T14}")"
echo "     $(pkgs_line "${T14}")"
check "(c) base still REUSE"                      mode_is "${T14}" REUSE
check "(c) the base was not rebuilt"              test "$(base_id "${W14}/stage2")" = "${BIDA}"
check "(c) layer BUILD on a mismatch"             pkgs_reason "${T14}" 'fingerprint mismatch'
check "(c) its SKIP removed"                      bash -c "! test -e '${PK14}/SKIP'"
check "(c) rebuilt from the base, not patched"    grep -q "^STUB copy_previous from ${W14}/stage2/rootfs$" "${T14}/out"
check "(c) a new layer"                           test -n "$(pkgs_id)" -a "$(pkgs_id)" != "${PIDA}"
check "(c) with a new fingerprint recorded"       test "$(cat "${PFP14}")" != "${PFPA% *}"
check "(c) the layer's prerun refreshed apt (base reused)" grep -q 'STUB on_chroot' "${T14}/out"
build "${T14}"
check "(c2) then REUSE"                           pkgs_mode_is "${T14}" REUSE
cp "${WORK}/l14.orig" "${L14}"
build "${T14}"
check "(c3) reverting the list rebuilds again (no copy kept)" pkgs_reason "${T14}" 'fingerprint mismatch'
build "${T14}"
check "(c3) then REUSE"                           pkgs_mode_is "${T14}" REUSE

echo "  -- (d) a new file, or an executable bit, in the layer's stage counts"
mkdir -p "${PK14}/04-extra"
echo "libbar" > "${PK14}/04-extra/00-packages"
build "${T14}"
check "(d) a new substage -> layer BUILD"         pkgs_reason "${T14}" 'fingerprint mismatch'
rm -rf "${PK14}/04-extra"
build "${T14}"
build "${T14}"
check "(d) precondition: REUSE again"             pkgs_mode_is "${T14}" REUSE
chmod +x "${L14}"
build "${T14}"
check "(d) an executable bit -> layer BUILD"      pkgs_reason "${T14}" 'fingerprint mismatch'
chmod -x "${L14}"
build "${T14}"
build "${T14}"

echo "  -- (e) the layer is over 7 days old: BUILD; the base is untouched"
touch -d '8 days ago' "${PFP14}"
build "${T14}"
echo "     $(pkgs_line "${T14}")"
check "(e) base REUSE"                            mode_is "${T14}" REUSE
check "(e) layer BUILD on age"                    pkgs_reason "${T14}" 'fingerprint 8.0 days old, limit 7'

echo "  -- (f) the base is rebuilt: so is the layer, with a new fingerprint"
PFPF="$(cat "${PFP14}")"
echo "# changed" >> "${T14}/pi-gen/stage1/prerun.sh"
build "${T14}"
check "(f) base FULL"                             mode_is "${T14}" FULL
check "(f) layer BUILD, naming the base"          pkgs_reason "${T14}" 'the stage2 base under it is built in this run'
check "(f) its fingerprint follows the base's"    test "$(cat "${PFP14}")" != "${PFPF}"

echo "  -- (g) a layer build that fails leaves no fingerprint, and is never reused"
build "${T14}"
check "(g) precondition: REUSE"                   pkgs_mode_is "${T14}" REUSE
echo "libfoo-dev" >> "${L14}"
build "${T14}" STUB_FAIL_IN_PKGS=1
check "(g) precondition: the layer build failed"  grep -q 'STUB pkgs failed' "${T14}/out"
check "(g) no layer fingerprint left"             test ! -e "${PFP14}"
cp "${WORK}/l14.orig" "${L14}"
build "${T14}"
echo "     $(pkgs_line "${T14}")"
check "(g) reverted lists do NOT reuse the half-built layer" pkgs_reason "${T14}" 'no fingerprint'

echo "  -- (h) STAGE_LIST: stages after the layer count for neither; its place does"
build "${T14}"
check "(h) precondition: REUSE, REUSE"            bash -c "grep -q '^elspi base: REUSE' '${T14}/out' && grep -q '^elspi base: package layer REUSE' '${T14}/out'"
check "(h1) anchor: a stage after the layer"      set_stages "stage0 stage1 stage2 stage-elspi-pkgs stage3 stage-elspi"
build "${T14}"
check "(h1) base REUSE"                           mode_is "${T14}" REUSE
check "(h1) layer REUSE"                          pkgs_mode_is "${T14}" REUSE
check "(h2) anchor: a stage between stage2 and the layer" set_stages "stage0 stage1 stage2 stage3 stage-elspi-pkgs stage-elspi"
build "${T14}"
echo "     $(pkgs_line "${T14}")"
check "(h2) base still REUSE (hashed through stage2 only)" mode_is "${T14}" REUSE
check "(h2) layer OFF"                            pkgs_mode_is "${T14}" OFF
check "(h2) its stale SKIP removed, so the stage runs where it is" bash -c "! test -e '${PK14}/SKIP'"
check "(h3) anchor: no layer at all"              set_stages "stage0 stage1 stage2 stage-elspi"
build "${T14}"
check "(h3) base REUSE"                           mode_is "${T14}" REUSE
check "(h3) layer OFF"                            pkgs_mode_is "${T14}" OFF
check "(h3) stage-elspi copied stage2, as before the layer" grep -q "^STUB copy_previous from ${W14}/stage2/rootfs$" "${T14}/out"
check "(h3) the base left alone by the REUSE run" grep -q '^elspi base: REUSE run, fingerprint left untouched' "${T14}/out"
T14b="$(make_tree nolayer)"
check "(h4) anchor: a fresh tree without the layer" replace_line "${T14b}/pi-gen/elspi.conf" \
	'STAGE_LIST="stage0 stage1 stage2 stage-elspi-pkgs stage-elspi"' 'STAGE_LIST="stage0 stage1 stage2 stage-elspi"'
build "${T14b}"
check "(h4) FULL, layer OFF"                      bash -c "grep -q '^elspi base: FULL' '${T14b}/out' && grep -q '^elspi base: package layer OFF' '${T14b}/out'"
check "(h4) stage-elspi recorded the base, as before the layer" test -s "$(fp_of "${T14b}")"
cp "${WORK}/elspi.conf.14" "${EC14}"

echo "  -- (i) a failed config guard: the layer is built and never recorded"
build "${T14}"
build "${T14}"
check "(i) precondition: REUSE"                   pkgs_mode_is "${T14}" REUSE
check "(i) anchor present" insert_before "${EC14}" 'export ELSPI_USB_MAX_CURRENT ELSPI_SITE_CONF_APPLIED' 'export FOO=bar'
build "${T14}"
echo "     $(pkgs_line "${T14}")"
check "(i) base FULL on the guard"                reason_is "${T14}" 'config guard:'
check "(i) layer BUILD"                           pkgs_mode_is "${T14}" BUILD
check "(i) no layer fingerprint recorded"         test ! -e "${PFP14}"
check "(i) and it said so"                        grep -q '^elspi base: package layer built without a fingerprint; not marked reusable' "${T14}/out"
cp "${WORK}/elspi.conf.14" "${EC14}"

echo
if [ "${FAIL}" -eq 0 ] && [ "${PASS}" -gt 0 ]; then
	echo "RESULT: all ${PASS} checks pass"
	exit 0
fi
echo "RESULT: FAILED -- ${FAIL} of $((PASS + FAIL)) checks"
exit 1
