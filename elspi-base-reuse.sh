# elspi-base-reuse.sh -- build the stock Raspberry Pi OS base (stages 0-2)
# once and reuse it, on a builder whose pi-gen work volume survives.
#
# SOURCED, and sourcing it only DEFINES functions:
#   - elspi.conf calls elspi_base_prepare  (decide, and set up the stage SKIPs)
#   - stage-elspi/prerun.sh calls elspi_base_record  (mark the base reusable)
# EXECUTED only for two read-only queries, which need no BASE_DIR, work on a
# plain checkout, and write nothing:
#   bash elspi-base-reuse.sh --print-inputs   # the paths the fingerprint reads
#   bash elspi-base-reuse.sh --check-configs  # the config guard, below
#
# --print-inputs IS AN INTERFACE (2026-09-26). A nightly pre-warm on the
# self-hosted runner runs it on an exported copy of the branch head to decide
# whether the base needs rebuilding. Keep this file at the repo root, keep the
# option name, and keep the output one repo-relative path per line. If any of
# those change, the pre-warm cannot list the inputs and falls back to
# rebuilding every night.
#
# WHY. stage0-2 are pi-gen's stock Lite base and, with arm64 emulated under
# qemu, the dominant cost of a build. Nothing elspi changes between builds
# touches them, so on a self-hosted runner with a persistent work volume they
# are built once and reused. On a builder that starts empty -- GitHub's hosted
# runners, a first local build -- there is no work dir to reuse, every run is
# FULL, and the image is what it was before this file existed.
#
# WHY THE DECISION IS MADE HERE, from files. Nothing a runner exports reaches
# build.sh: build-docker.sh:140 forwards only GIT_HASH with -e, and :139
# mounts the chosen config ALONE at /config. What the container can see is
# its own copy of the repo, the config, and the work volume -- so the
# decision is made while build.sh sources the config (build.sh:169).
#
# THE MECHANISM IS UPSTREAM'S OWN, unedited. build.sh:101 tests a stage's
# SKIP file BEFORE its CLEAN block (:102-106) can delete that stage's rootfs,
# and :121-123 set PREV_ROOTFS_DIR for a skipped stage exactly as for a run
# one, from ROOTFS_DIR=${WORK_DIR}/<stage>/rootfs (:91-92). So with
# stage0-2/SKIP present, stage-elspi's copy_previous (scripts/common:34-41)
# copies the kept ${WORK_DIR}/stage2/rootfs.
#
# REUSE REQUIRES ALL OF:
#   - the config guard passes (_elspi_base_guard, below);
#   - ${WORK_DIR}/stage2/rootfs exists;
#   - ${WORK_DIR}/stage2/.elspi-base-fingerprint (NEXT TO the rootfs, never
#     in it, or it would ship) equals a hash computed now over every input
#     that shapes stages 0-2 -- see _elspi_base_manifest;
#   - that file is under 7 days old, so Debian and Raspberry Pi archive
#     updates reach the base within a week with no cleanup timer.
# The fingerprint is written ONLY by elspi_base_record, i.e. only after
# stage2 has completed in a FULL run, and NEVER on a REUSE run: a rewrite
# would refresh its mtime and the 7-day bound would never expire. A FULL run
# deletes it before stage0 starts, so a base build that dies part way is
# never marked reusable.
#
# ALWAYS, in build.sh's shell: CLEAN=1, so stage-elspi and export-image
# rebuild from a fresh copy of stage2's rootfs rather than stacking on the
# last run's (stage-elspi/prerun.sh copies only when its rootfs is ABSENT);
# and deploy/ is emptied, because build-docker.sh:154 copies the whole deploy
# volume out and a leftover image fails image.yml's "exactly one image" gate.
#
# NOTHING HAPPENS ON THE HOST. build-docker.sh:52 also sources the config,
# under `set -eu`, with no BASE_DIR; elspi.conf does not even source this file
# there, and elspi_base_prepare checks again (_elspi_base_in_build_sh).

_ELSPI_BASE_MAX_AGE_S=$((7 * 86400))

# =============================================================================
# WHAT SHAPES STAGES 0-2, and why the repo's configs are NOT hashed raw
# (2026-09-26). A stale base is a SILENT wrong image; a spurious FULL costs
# ~50 min. Until this date elspi.conf was hashed raw, so any edit to it --
# most of it configures stage-elspi and export -- forced a FULL (9 of the 13
# base-input commits in the preceding 14 days). The repo's configs are now
# reduced to what they can actually do to stages 0-2, which is exactly three
# things, each covered:
#
# 1. VALUES build.sh or a stage 0-2 process can read. build.sh sources the
#    config (:158-169) BEFORE it exports anything (:176-248), then runs the
#    stages as children (and chroots via scripts/common's on_chroot, which
#    passes the environment through capsh). So a stage 0-2 process sees
#    build.sh's EXPORTED variables, and build.sh itself reads some config
#    variables it never exports. _ELSPI_BASE_VARS below lists every one that
#    can reach stages 0-2, with its reader; their values are hashed by name,
#    as `declare -p` prints them (value, export attribute, and set vs unset --
#    stage2/02-net-tweaks tests WPA_COUNTRY with `-v`, so unset and empty
#    differ). Found by reading build.sh, scripts/common, scripts/
#    dependencies_check and every file under stage0-2.
# 2. EXPORTS the configs perform themselves. An exported variable is in the
#    environment of every stage 0-2 process, readers or not, so every name a
#    config exports is hashed (elspi.conf:220-221 today; all five are read
#    only by stage-elspi, and are hashed anyway).
# 3. SIDE EFFECTS of sourcing: files written, commands run, functions
#    defined, other files sourced. Today: elspi.conf touches stage2/
#    SKIP_IMAGES (excluded from the raw hash below; it only stops stage2's
#    Lite image being queued for export, build.sh:96-100), runs one pipeline
#    that READS /dev/urandom, and sources the private site config and this
#    file; ci.conf and ci-test.conf source elspi.conf and ci.conf. None
#    defines a function -- a config function named run_stage would REPLACE
#    build.sh's, which is defined above the source at :169.
#
# THE GUARD keeps that analysis from rotting. _elspi_base_guard reads every
# non-comment line of the repo's configs and accepts only: a plain assignment
# (a literal, or "${NAME:-literal}") of a CLASSIFIED name; an `export` of
# hashed names; an echo of literal text and ${NAME}s; fi/else/esac/exit N;
# or a line in _elspi_base_conf_allowlist, which gives each its reason. Any
# other line -- a new export, a new file write, a function, a command, a
# heredoc, a line continuation, a trailing comment -- fails it, and a failed
# guard forces FULL with the offending line in the log (and fails
# tests/test-base-reuse.sh). Hashed variables may be set only in elspi.conf,
# and only BEFORE its elspi_base_prepare line, because the decision reads
# their values at that point: ci.conf and ci-test.conf set theirs AFTER
# elspi.conf returns, where a base-affecting value would go unseen. To fix a
# guard failure, CLASSIFY the line: base-affecting, so hash it (add the name
# to _ELSPI_BASE_VARS); or not, so allowlist it with the reason.
#
# PRIVATE CONFIGS ARE NEVER NARROWED. The site config (ELSPI_SITE_CONF), an
# upstream-style ${BASE_DIR}/config, and any config on the source stack that
# is not a byte-copy of one of the repo's own (an operator's `-c my.conf`)
# are unknown text: they are hashed whole, with only whole-line comments and
# blank lines stripped, as before.
# =============================================================================

# Hashed by value, in this order. Where each is read, stage-side:
_ELSPI_BASE_VARS=(
	RELEASE                        # stage0/prerun.sh:9 (debootstrap suite), stage0/00-configure-apt/00-run.sh:6-7,18
	STAGE_LIST                     # build.sh:320,330: which stages run
	TARGET_HOSTNAME                # stage1/02-net-tweaks/00-run.sh:3-4
	FIRST_USER_NAME                # stage1/01-sys-tweaks/00-run.sh:6-12, stage2/01-sys-tweaks/01-run.sh, stage2/02-net-tweaks/01-run.sh:16
	DISABLE_FIRST_BOOT_USER_RENAME # build.sh:292-301 (checks only; export-image reads it) -- kept, conservative
	PASSWORDLESS_SUDO              # stage2/01-sys-tweaks/01-run.sh:41
	WPA_COUNTRY                    # stage2/02-net-tweaks/01-run.sh:14 (`-v`: set vs unset matters)
	ENABLE_SSH                     # stage2/01-sys-tweaks/01-run.sh:16
	PUBKEY_ONLY_SSH                # stage2/01-sys-tweaks/01-run.sh:10, build.sh:313
	PUBKEY_SSH_FIRST_USER          # stage2/01-sys-tweaks/01-run.sh:3-7, build.sh:313
	LOCALE_DEFAULT                 # stage0/01-locale/00-debconf:3,6
	KEYBOARD_KEYMAP                # stage2/01-sys-tweaks/00-debconf:15
	KEYBOARD_LAYOUT                # stage2/01-sys-tweaks/00-debconf:23
	TIMEZONE_DEFAULT               # stage2/03-set-timezone/02-run.sh:3
	ENABLE_CLOUD_INIT              # stage2/04-cloud-init/01-run.sh:3
	APT_PROXY                      # build.sh:303, scripts/common:10 (debootstrap), stage0/00-configure-apt/00-run.sh:9-11
	TEMP_REPO                      # stage0/00-configure-apt/00-run.sh:16-18
	USE_QEMU                       # stage2/01-sys-tweaks/01-run.sh:23
	SETFCAP                        # build.sh:255: decides CAPSH_ARG
	CAPSH_ARG                      # scripts/common:21,107: debootstrap and every chroot command
	REFLEX_SOURCE                  # exported by elspi.conf:220 (read by stage-elspi only)
	REFLEX_RELEASE                 # exported by elspi.conf:220 (read by stage-elspi only)
	REFLEX_ORIGIN_URL              # exported by elspi.conf:220 (read by stage-elspi only)
	ELSPI_USB_MAX_CURRENT          # exported by elspi.conf:221 (read by stage-elspi only)
	ELSPI_SITE_CONF_APPLIED        # exported by elspi.conf:221 (read by stage-elspi only)
)
# NOT hashed, deliberately. A config may assign the first three plainly;
# assigning any of the rest fails the guard until it is classified.
#   IMG_NAME            names WORK_DIR (build.sh:182,190), and the fingerprint
#                       lives INSIDE WORK_DIR, so a new name finds no base.
#   DEPLOY_COMPRESSION, COMPRESSION_LEVEL
#                       exported by build.sh:201-202, read only by export-image.
#   ARCH                a constant in build.sh:180, hashed from build.sh's text.
#   FIRST_USER_PASS     stage1 sets it with chpasswd, but elspi.conf makes it
#                       random per build (hashing it would force FULL every
#                       time) and stage-elspi/05-service-user replaces it with
#                       a bare '!' in every image. Set by an allowlisted line.
#   CLEAN               forced to 1 by elspi_base_prepare.
#   WORK_DIR, DEPLOY_DIR, DEPLOY_ZIP, IMG_DATE, IMG_FILENAME, ARCHIVE_FILENAME,
#   EXPORT_CONFIG_DIR, PI_GEN*, GIT_HASH, WPA_PASSWORD
#                       export stages only (update_issue, the one reader of
#                       PI_GEN*/GIT_HASH/IMG_DATE, is called only from
#                       export-image/05-finalise), or location, or a check
#                       that can abort the build but not change the base
#                       (WPA_PASSWORD, build.sh:308). Unclassified for the
#                       guard, so a config that sets one must classify it.
_ELSPI_BASE_NONBASE_VARS=(IMG_NAME DEPLOY_COMPRESSION COMPRESSION_LEVEL)

# THE ONE LIST OF INPUT PATHS. The fingerprint reads exactly these (plus the
# config build.sh was given with -c, when that is not a byte-copy of a repo
# config), and --print-inputs prints exactly these; both go through
# _elspi_base_inputs, so they cannot diverge.
#   raw   hashed whole: path, content hash and executable bit, recursively.
#   conf  the repo's configs: scanned by the guard, reduced to _ELSPI_BASE_VARS.
_ELSPI_BASE_RAW_INPUTS=(stage0 stage1 stage2 scripts build.sh Dockerfile elspi-base-reuse.sh)
_ELSPI_BASE_REPO_CONFS=(elspi.conf ci.conf ci-test.conf)

# "<class> <path>" per line, $1 = the repo root. Classes as above, plus
#   private  ${root}/config if present: hashed whole, comment-stripped;
#   site     ELSPI_SITE_CONF if set, as given: hashed whole, comment-stripped.
_elspi_base_inputs() {
	local root="$1" p
	for p in "${_ELSPI_BASE_RAW_INPUTS[@]}"; do echo "raw ${p}"; done
	for p in "${_ELSPI_BASE_REPO_CONFS[@]}"; do echo "conf ${p}"; done
	if [ -f "${root}/config" ]; then echo "private config"; fi
	if [ -n "${ELSPI_SITE_CONF:-}" ]; then echo "site ${ELSPI_SITE_CONF}"; fi
	return 0
}

# Lines of the repo's configs that are neither a plain assignment, an export,
# an echo, nor fi/else/esac/exit, each with its classification. Exact match,
# after leading/trailing whitespace is trimmed, keyed by config file name.
_elspi_base_conf_allowlist() {
	cat <<'ALLOWED'
# SIDE EFFECT, not base-affecting: stage2/SKIP_IMAGES only keeps stage2's
# Lite image off the export list (build.sh:96-100); it is excluded from the
# raw hash, and stage2's rootfs is the same with or without it.
elspi.conf|if [ -n "${BASE_DIR:-}" ]; then
elspi.conf|touch "${BASE_DIR}/stage2/SKIP_IMAGES"
elspi.conf|if [ ! -f "${BASE_DIR}/stage2/SKIP_IMAGES" ]; then
# COMMAND, writes nothing: the throwaway FIRST_USER_PASS, unhashed on
# purpose (see _ELSPI_BASE_NONBASE_VARS).
elspi.conf|_elspi_rand="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')"
elspi.conf|FIRST_USER_PASS="${_elspi_rand:0:32}"
elspi.conf|unset _elspi_rand
# CONDITIONS, and a validation that can only abort.
elspi.conf|if [ -n "${ELSPI_PUBKEY:-}" ]; then
elspi.conf|if [ -n "${ELSPI_SITE_CONF:-}" ]; then
elspi.conf|if [ ! -f "${ELSPI_SITE_CONF}" ] || [ ! -r "${ELSPI_SITE_CONF}" ]; then
elspi.conf|case "${ELSPI_USB_MAX_CURRENT}" in
elspi.conf|0|1) ;;
elspi.conf|*) echo "FATAL: ELSPI_USB_MAX_CURRENT must be 0 or 1 (got '${ELSPI_USB_MAX_CURRENT}')"; exit 1 ;;
# SOURCES the private site config, hashed whole (never narrowed).
elspi.conf|. "${ELSPI_SITE_CONF}"
# SOURCES this file (hashed raw) and makes the decision. Nothing but `fi`
# may follow it: the decision has already read the values.
elspi.conf|. "${BASE_DIR}/elspi-base-reuse.sh"
elspi.conf|elspi_base_prepare
# SOURCES elspi.conf, found by BASE_DIR (a temporary, unset after).
ci.conf|_elspi_base="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ci.conf|if [ ! -f "${_elspi_base}/elspi.conf" ]; then
ci.conf|source "${_elspi_base}/elspi.conf"
ci.conf|unset _elspi_base
# SOURCES ci.conf, the same way.
ci-test.conf|_elspi_ci_base="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ci-test.conf|if [ ! -f "${_elspi_ci_base}/ci.conf" ]; then
ci-test.conf|source "${_elspi_ci_base}/ci.conf"
ci-test.conf|unset _elspi_ci_base
ALLOWED
}

_ELSPI_BASE_RE_ASSIGN='^([A-Za-z_][A-Za-z0-9_]*)=("[^"$`\\]*"|[A-Za-z0-9_./:@%+,-]*|"\$\{[A-Za-z_][A-Za-z0-9_]*:-[^"$`\\}]*\}")$'
_ELSPI_BASE_RE_EXPORT='^export([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)+$'
_ELSPI_BASE_RE_ECHO='^echo "[^"$`\\]*(\$\{[A-Za-z_][A-Za-z0-9_]*\}[^"$`\\]*)*"$'
_ELSPI_BASE_RE_KEYWORD='^(fi|else|esac|exit [0-9]+)$'

_elspi_base_is_hashed() { case " ${_ELSPI_BASE_VARS[*]} " in *" $1 "*) return 0 ;; esac; return 1; }
_elspi_base_is_nonbase() { case " ${_ELSPI_BASE_NONBASE_VARS[*]} " in *" $1 "*) return 0 ;; esac; return 1; }

# Scan one repo config ($1 = path, $2 = its name). Prints one line per
# violation; returns non-zero if there was any.
_elspi_base_scan_conf() {
	local file="$1" key="$2" line l n=0 bad=0 after=0 w
	local allowed nl=$'\n'
	[ -f "${file}" ] && [ -r "${file}" ] || { echo "${key}: missing or unreadable"; return 1; }
	allowed="${nl}$(_elspi_base_conf_allowlist)${nl}" || return 1
	while IFS= read -r line || [ -n "${line}" ]; do
		n=$((n + 1))
		l="${line#"${line%%[![:space:]]*}"}"
		l="${l%"${l##*[![:space:]]}"}"
		case "${l}" in ''|'#'*) continue ;; esac
		if [ "${after}" = 1 ]; then
			[ "${l}" = fi ] && continue
			echo "${key}:${n}: statement after elspi_base_prepare: ${l}"; bad=1; continue
		fi
		if [[ ${l} =~ ${_ELSPI_BASE_RE_ASSIGN} ]]; then
			w="${BASH_REMATCH[1]}"
			if _elspi_base_is_hashed "${w}"; then
				[ "${key}" = elspi.conf ] && continue
				echo "${key}:${n}: base-affecting ${w} set outside elspi.conf, where the decision cannot see it: ${l}"; bad=1
			elif ! _elspi_base_is_nonbase "${w}"; then
				echo "${key}:${n}: unclassified variable ${w}: ${l}"; bad=1
			fi
			continue
		fi
		if [[ ${l} =~ ${_ELSPI_BASE_RE_EXPORT} ]]; then
			for w in ${l#export}; do
				if ! _elspi_base_is_hashed "${w}"; then
					echo "${key}:${n}: unclassified export ${w}: ${l}"; bad=1
				elif [ "${key}" != elspi.conf ]; then
					echo "${key}:${n}: export of ${w} outside elspi.conf: ${l}"; bad=1
				fi
			done
			continue
		fi
		[[ ${l} =~ ${_ELSPI_BASE_RE_ECHO} ]] && continue
		[[ ${l} =~ ${_ELSPI_BASE_RE_KEYWORD} ]] && continue
		# A whole-line, literal match (the pattern's quoted part is literal).
		case "${allowed}" in
			*"${nl}${key}|${l}${nl}"*)
				[ "${key}" = elspi.conf ] && [ "${l}" = elspi_base_prepare ] && after=1
				continue ;;
		esac
		echo "${key}:${n}: unclassified statement (an export, side effect or command): ${l}"; bad=1
	done < "${file}"
	return "${bad}"
}

# The guard over every repo config. $1 = the repo root.
_elspi_base_guard() {
	local root="$1" cls p bad=0
	while read -r cls p; do
		[ "${cls}" = conf ] || continue
		_elspi_base_scan_conf "${root}/${p}" "${p}" || bad=1
	done < <(_elspi_base_inputs "${root}")
	return "${bad}"
}

# True only in build.sh's own shell, while it sources the config: BASE_DIR is
# set (build.sh:147/:156) AND the outermost script on the source stack is
# ${BASE_DIR}/build.sh, resolved the way build.sh:147 resolves itself. The
# second test is what keeps a BASE_DIR that happens to be exported in an
# operator's shell from turning a host-side source into one that writes files.
_elspi_base_in_build_sh() {
	[ -n "${BASE_DIR:-}" ] || return 1
	local outer="${BASH_SOURCE[$((${#BASH_SOURCE[@]} - 1))]}"
	local outer_abs
	outer_abs="$(cd "$(dirname "${outer}")" 2>/dev/null && pwd)/$(basename "${outer}")"
	[ "${outer_abs}" = "${BASE_DIR}/build.sh" ]
}

# build.sh:180-190 derive WORK_DIR AFTER the config is sourced, so it is not
# set yet here; derive it the same way.
_elspi_base_workdir() {
	printf '%s' "${WORK_DIR:-${BASE_DIR}/work/${IMG_NAME:-raspios-${RELEASE:-trixie}-arm64}}"
}

# The hashed values, one `declare -p` line (or "unset NAME") each.
_elspi_base_var_lines() {
	local _ebv
	for _ebv in "${_ELSPI_BASE_VARS[@]}"; do
		declare -p "${_ebv}" 2>/dev/null || echo "unset ${_ebv}"
	done
}

# Everything that shapes stages 0-2, one line each, in a fixed order. The
# fingerprint is the sha256 of this text. Returns non-zero, and the caller
# builds FULL, if any input cannot be read. The config guard must have
# passed first (elspi_base_prepare), or the repo configs' reduction to
# _ELSPI_BASE_VARS is not complete.
#
#   - every file under the raw inputs: path, content hash, and the executable
#     bit, because build.sh:67 and :107 SKIP a script without it. Sorted with
#     LC_ALL=C. stage0-2's own SKIP and SKIP_IMAGES are left out: this file
#     and elspi.conf create them, and hashing them would flip the result.
#   - ARCH (a constant in build.sh:180) and _ELSPI_BASE_VARS, as the config
#     has set them so far.
#   - a private config, whole, with whole-line comments (a '#' after optional
#     leading whitespace) and blank/whitespace-only lines removed line by
#     line with sed: comment text does not shape stage0-2 (1116b04, a
#     comment-only change, once forced a ~47 min FULL). A trailing comment on
#     a settings line still counts.
_elspi_base_manifest() {
	local root="${BASE_DIR}" cls p f h x n=0 line self
	local -a raw=() conf=() priv=() known=()
	while IFS= read -r line; do
		cls="${line%% *}"
		p="${line#* }"
		case "${cls}" in
			raw)     raw+=("${p}") ;;
			conf)    conf+=("${p}") ;;
			private) priv+=("${root}/${p}") ;;
			site)    priv+=("${p}") ;;
			*)       return 1 ;;
		esac
	done < <(_elspi_base_inputs "${root}")
	for p in "${raw[@]}" "${conf[@]}"; do
		[ -e "${root}/${p}" ] || { echo "elspi base: missing input ${root}/${p}" >&2; return 1; }
	done

	echo "ARCH=$(sed -n 's/^export ARCH=//p' "${root}/build.sh")"
	_elspi_base_var_lines

	while IFS= read -r -d '' f; do
		case "${f}" in
			stage[012]/SKIP|stage[012]/SKIP_IMAGES) continue ;;
		esac
		if [ -L "${root}/${f}" ]; then
			printf 'L %s -> %s\n' "${f}" "$(readlink "${root}/${f}")"
		else
			h="$(sha256sum < "${root}/${f}")" || return 1
			h="${h%% *}"
			[ "${#h}" -eq 64 ] || return 1
			x=-
			[ -x "${root}/${f}" ] && x=x
			printf 'F %s %s %s\n' "${x}" "${h}" "${f}"
		fi
		n=$((n + 1))
	done < <(cd "${root}" && find "${raw[@]}" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
	[ "${n}" -gt 0 ] || return 1

	# The source stack: build.sh and this file are raw inputs already, and a
	# byte-copy of a repo config (build-docker.sh mounts the chosen one at
	# /config) is covered by the guard and the values. Anything else is a
	# private config.
	for p in "${conf[@]}"; do
		h="$(sha256sum < "${root}/${p}")" || return 1
		known+=("${h%% *}")
	done
	for f in "${BASH_SOURCE[@]}"; do
		[ -n "${f}" ] && [ -f "${f}" ] || continue
		[ "${f}" = "${root}/elspi-base-reuse.sh" ] || [ "${f}" = "${root}/build.sh" ] && continue
		h="$(sha256sum < "${f}")" || return 1
		self=0
		for x in "${known[@]}"; do [ "${x}" = "${h%% *}" ] && self=1; done
		[ "${self}" = 1 ] || priv+=("${f}")
	done
	for f in "${priv[@]}"; do
		[ -n "${f}" ] && [ -f "${f}" ] || continue
		h="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${f}" | sha256sum)" || return 1
		echo "C ${h%% *}"
	done
}

elspi_base_prepare() {
	_elspi_base_in_build_sh || return 0

	local work fp_file manifest fp="" stored mode=FULL reason age_s days s guard
	local deploy="${DEPLOY_DIR:-${BASE_DIR}/deploy}"
	work="$(_elspi_base_workdir)"
	fp_file="${work}/stage2/.elspi-base-fingerprint"

	# deploy/ first: it is emptied on every run, REUSE or FULL. Its CONTENTS,
	# not the directory, which is a Docker volume mount point (Dockerfile:16).
	if [ -d "${deploy}" ]; then
		find "${deploy}" -mindepth 1 -delete
		if [ -n "$(find "${deploy}" -mindepth 1 -print -quit)" ]; then
			echo "FATAL: could not empty ${deploy}; a leftover image would be copied out with the new one"
			exit 1
		fi
	fi

	if ! guard="$(_elspi_base_guard "${BASE_DIR}")"; then
		# No fingerprint: a base built while the guard fails is never reused.
		printf '%s\n' "${guard}" | sed 's/^/elspi base guard: /'
		reason="config guard: ${guard%%$'\n'*}"
	else
		if manifest="$(_elspi_base_manifest)"; then
			fp="$(printf '%s\n' "${manifest}" | sha256sum)"
			fp="${fp%% *}"
		fi

		if [ "${#fp}" -ne 64 ]; then
			fp=""
			reason="could not compute the stage0-2 fingerprint"
		elif [ ! -d "${work}/stage2/rootfs" ]; then
			reason="no stage2 rootfs in ${work}"
		elif [ ! -f "${fp_file}" ]; then
			reason="stage2 rootfs has no fingerprint: never recorded, or its FULL run did not finish"
		elif ! stored="$(cat "${fp_file}")" || [ "${stored}" != "${fp}" ]; then
			# An unreadable file counts as a mismatch, never as a match.
			reason="fingerprint mismatch: stage0-2 inputs changed"
		else
			age_s=$(($(date +%s) - $(stat -c %Y "${fp_file}")))
			days="$(awk -v s="${age_s}" 'BEGIN { printf "%.1f", s / 86400 }')"
			if [ "${age_s}" -lt 0 ]; then
				reason="fingerprint is dated in the future"
			elif [ "${age_s}" -ge "${_ELSPI_BASE_MAX_AGE_S}" ]; then
				reason="fingerprint ${days} days old, limit 7"
			else
				mode=REUSE
				reason="fingerprint match, ${days} days old"
			fi
		fi
	fi

	if [ "${mode}" = REUSE ]; then
		for s in stage0 stage1 stage2; do
			touch "${BASE_DIR}/${s}/SKIP"
			[ -f "${BASE_DIR}/${s}/SKIP" ] || { echo "FATAL: could not create ${BASE_DIR}/${s}/SKIP"; exit 1; }
		done
	else
		# The old fingerprint goes BEFORE stage0 starts: from here until
		# elspi_base_record runs, this base is not known to be complete.
		rm -f "${fp_file}"
		[ ! -e "${fp_file}" ] || { echo "FATAL: could not remove ${fp_file}"; exit 1; }
		for s in stage0 stage1 stage2; do
			rm -f "${BASE_DIR}/${s}/SKIP"
			[ ! -e "${BASE_DIR}/${s}/SKIP" ] || { echo "FATAL: could not remove ${BASE_DIR}/${s}/SKIP"; exit 1; }
		done
	fi

	CLEAN=1
	ELSPI_BASE_MODE="${mode}"
	ELSPI_BASE_FINGERPRINT="${fp}"
	ELSPI_BASE_FP_FILE="${fp_file}"
	# Exported: stage-elspi/prerun.sh is a CHILD of build.sh and reads them.
	# (They are in stage 0-2's environment too; nothing there reads them.)
	export CLEAN ELSPI_BASE_MODE ELSPI_BASE_FINGERPRINT ELSPI_BASE_FP_FILE
	echo "elspi base: ${mode} (${reason})${fp:+ fingerprint ${fp:0:12}}"
}

# Called from stage-elspi/prerun.sh. Reaching that prerun means build.sh
# (`#!/bin/bash -e`) has come through stage0-2 without an error, so in a FULL
# run this is the first point at which the new base is known to be complete.
elspi_base_record() {
	case "${ELSPI_BASE_MODE:-}" in
		REUSE)
			echo "elspi base: REUSE run, fingerprint left untouched (a rewrite would restart its 7-day clock)"
			return 0 ;;
		FULL) ;;
		*)
			echo "elspi base: no base mode set (the config did not run elspi_base_prepare); not recorded"
			return 0 ;;
	esac
	if [ -z "${ELSPI_BASE_FINGERPRINT:-}" ] || [ -z "${ELSPI_BASE_FP_FILE:-}" ]; then
		echo "elspi base: FULL run without a fingerprint; base not marked reusable"
		return 0
	fi
	printf '%s\n' "${ELSPI_BASE_FINGERPRINT}" > "${ELSPI_BASE_FP_FILE}.tmp"
	mv -f "${ELSPI_BASE_FP_FILE}.tmp" "${ELSPI_BASE_FP_FILE}"
	if [ "$(cat "${ELSPI_BASE_FP_FILE}")" != "${ELSPI_BASE_FINGERPRINT}" ]; then
		echo "FATAL: post-write check failed for ${ELSPI_BASE_FP_FILE}"
		exit 1
	fi
	echo "elspi base: stage0-2 complete, fingerprint ${ELSPI_BASE_FINGERPRINT:0:12} recorded (reusable for 7 days)"
}

# EXECUTED (not sourced): the read-only queries. Paths are relative to this
# file's directory, whatever the caller's cwd and whatever BASE_DIR says; the
# site config is printed as ELSPI_SITE_CONF gives it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	_elspi_base_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
	case "${1:-}" in
		--print-inputs)
			_elspi_base_inputs "${_elspi_base_root}" | sed 's/^[a-z]* //'
			exit "${PIPESTATUS[0]}" ;;
		--check-configs)
			_elspi_base_guard "${_elspi_base_root}" || exit 1
			echo "elspi base: config guard clean"
			exit 0 ;;
		*)
			echo "usage: bash elspi-base-reuse.sh --print-inputs | --check-configs" >&2
			exit 2 ;;
	esac
fi
