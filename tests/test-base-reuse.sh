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
# Sections 9 and 10 cover the 2026-09-26 narrowing: the repo's configs count
# only through the variables that reach stages 0-2, a line guard fails closed
# on anything else, and --print-inputs lists exactly what is read. Seen red:
# (a) against the helper before the narrowing, (b)/(c) with the variable
# hashing dropped, (c2)/(d)/(e) with the guard removed, section 10 with an
# input added to the find but not to the list.
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

echo "  -- (c) STAGE_LIST forces FULL"
expect_full "(c) STAGE_LIST" "${EC}" 'STAGE_LIST="stage0 stage1 stage2 stage-elspi"' \
	'STAGE_LIST="stage0 stage1 stage2 stage3 stage-elspi"' 'fingerprint mismatch'

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

# --- 10. --print-inputs: the paths the fingerprint reads, exactly -----------
# Both directions, by behaviour: changing any LISTED path forces FULL, and
# changing anything else in the tree keeps REUSE. The tree carries extra
# repo content (export-image, stage3, ...) so the second half has something
# to change. A helper that reads a path it does not list fails here.
echo
echo "== 10. --print-inputs lists exactly what the fingerprint reads"
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
	check "listed ${p} changed -> FULL"           mode_is "${T10}" FULL
	cp -p "${WORK}/probe.orig" "${f}"
	build "${T10}"
	build "${T10}"
	check "  ${p} restored -> REUSE again"        mode_is "${T10}" REUSE
done

echo
if [ "${FAIL}" -eq 0 ] && [ "${PASS}" -gt 0 ]; then
	echo "RESULT: all ${PASS} checks pass"
	exit 0
fi
echo "RESULT: FAILED -- ${FAIL} of $((PASS + FAIL)) checks"
exit 1
