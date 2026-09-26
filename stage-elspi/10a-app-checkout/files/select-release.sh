#!/bin/bash
# WHICH RELEASE GOES IN THE IMAGE -- the decision, on its own, in one place.
#
#   select-release.sh latest <source>     print the newest FULL release tag
#   select-release.sh check  <tag>        0 iff <tag> is a full release tag
#   select-release.sh list   <source>     every full release tag, oldest first
#
# docs/design/seam.md, AMENDMENT 2026-09-21, ratified by Evan: the image ships
# the app pinned to the LATEST FULL RELEASE -- "not a development `rc.*`, not
# a floating branch". This script is the only thing in the repo that decides
# what that means, so that the answer is testable without a 2-3 hour pi-gen
# build. Same standalone-script split, and the same reason, as
# ../../11-manifest/files/render-release.sh.
#
# --------------------------------------------------------------------------
# WHAT COUNTS AS A FULL RELEASE, AND WHY IT IS THIS AND NOT A GUESS
# --------------------------------------------------------------------------
# Read out of the reflex monorepo's OWN release workflow
# (.github/workflows/release.yml at v1.1.0), which is the thing that creates
# these tags:
#
#   * the version is validated against
#     ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ and tagged as "v$V";
#   * "if echo "$V" | grep -q -- '-'; then PRE=true" -- A HYPHEN IS WHAT
#     MAKES IT A PRE-RELEASE, per the workflow itself;
#   * main takes finals, dev takes pre-releases, and crossing them is a hard
#     error in the workflow ("that is how a release-candidate ends up looking
#     like a release").
#
# So: a full release is EXACTLY `v<major>.<minor>.<patch>` with nothing after
# the patch number. Everything else is refused BY NAME:
#
#   v1.2.0-rc.4     pre-release        (hyphen -> PRE=true in release.yml)
#   v1.1.0-rc.1     pre-release
#   v0.3.5-alpha.1  pre-release
#   ui-v1.0.0       NOT the lockstep namespace -- a ui-only tag from before
#                   the 2026-08-17 weld. The amendment says "the same
#                   one-version-both-halves object the in-app updater
#                   installs", and a ui-* tag is half an object.
#   fw-v2.0.7       likewise, the firmware half
#   ui-archive/*    archived pre-weld history
#   fw-archive/*    likewise
#
# THE PREFIXED NAMESPACES ARE NOT A DETAIL. `ui-v1.0.0` sorts perfectly well
# and looks like a release; baking it would put a UI-only tree at the app root
# with no `fw/` for the updater's firmware half, which is precisely the
# "UI-only update" reflex's own updater docstring says the fw+ui decision
# rejected. A prefix match is what keeps that out, so the pattern is anchored
# at both ends and there is no "contains a version number" fallback anywhere
# in this file.
#
# --------------------------------------------------------------------------
# NO FALLBACK. EVER.
# --------------------------------------------------------------------------
# When nothing resolves this REFUSES and says what it saw. It never reaches
# for HEAD, main, dev, the newest tag of any shape, or the newest pre-release
# "just to have something". A floating branch tip in a shipped image is the
# exact state call 1 was written against, and an rc.* baked in is the thing
# the amendment names in its first sentence. An image that fails to build is
# recoverable in an afternoon; an image that silently ships dev is a lathe
# running numbers nobody chose.
#
# --------------------------------------------------------------------------
# NO INTERPRETER, SAME AS render-release.sh (order 2026-09-18#1)
# --------------------------------------------------------------------------
# This runs on the BUILD HOST -- debian:bullseye plus ./Dockerfile's apt list
# -- which has no python3 and no jq. The 2026-09-17 build died three hours in
# over exactly that. The only external command here is `git`, which is in both
# ./depends and ./Dockerfile; the version comparison is pure bash arithmetic,
# not `sort -V`, so there is no locale or coreutils-version question about the
# ordering of the thing that decides what ships.
set -uo pipefail

MODE="${1:-}"
ARG="${2:-}"

# ANCHORED AT BOTH ENDS. See the namespace note above.
FULL_RELEASE_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
# A version-shaped tag with a suffix: release.yml's PRE=true case.
PRERELEASE_RE='^v[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.]+$'

moan() { printf '%s\n' "$*" >&2; }

# --- check ------------------------------------------------------------------
# Quiet mode (check_quiet) is what `latest` filters with; the loud one is what
# a human and the tests see. Both go through the SAME two patterns, so a tag
# cannot be accepted by the filter and refused by the gate, or the reverse.
check_quiet() { # <tag> -> 0 if a full release tag
	[[ "$1" =~ ${FULL_RELEASE_RE} ]]
}

check_loud() { # <tag> -> 0, or 1 with a named refusal on stderr
	local tag="$1"
	if [ -z "${tag}" ]; then
		moan "REFUSED: no tag given. There is no default and no fallback."
		return 1
	fi
	if check_quiet "${tag}"; then
		printf '%s\n' "${tag}"
		return 0
	fi
	if [[ "${tag}" =~ ${PRERELEASE_RE} ]]; then
		moan "REFUSED: '${tag}' is a PRE-RELEASE, not a full release."
		moan "         reflex's .github/workflows/release.yml makes any version"
		moan "         carrying a hyphen a pre-release, published from the dev"
		moan "         branch. docs/design/seam.md's 2026-09-21 amendment says the"
		moan "         image ships the latest FULL release -- 'never a"
		moan "         development rc.*'."
		moan "         Nothing is substituted for it. Pass a full release tag,"
		moan "         or leave REFLEX_RELEASE unset and let the newest one be"
		moan "         selected."
		return 1
	fi
	moan "REFUSED: '${tag}' is not in the lockstep release namespace."
	moan "         A bakeable release tag is exactly v<major>.<minor>.<patch>."
	moan "         'ui-*' and 'fw-*' tags name ONE HALF of the pair (pre-weld,"
	moan "         or a component tag); an 'archive/' tag is history. The"
	moan "         in-app updater needs both halves under one tag, so half an"
	moan "         object is refused rather than baked."
	return 1
}

# --- version ordering -------------------------------------------------------
# Field-by-field numeric compare on the three components. `sort -V` would do
# this too, and would also silently order the prefixed and suffixed tags that
# have already been filtered out -- which is the sort of "works today" the
# rest of this repo keeps finding in build logs. Arithmetic cannot drift.
#
# 10-BASE FORCED. `$((10#${x}))`, never `$((x))`: bash reads a leading zero as
# OCTAL, so a hypothetical v1.08.0 would be a syntax error ("value too great
# for base") and abort the selection, and v1.010.0 would compare as 8.
newer_than() { # <a> <b> -> 0 if a > b
	local a="${1#v}" b="${2#v}"
	local amaj="${a%%.*}" bmaj="${b%%.*}"
	local arest="${a#*.}"  brest="${b#*.}"
	local amin="${arest%%.*}" bmin="${brest%%.*}"
	local apat="${arest#*.}"  bpat="${brest#*.}"
	amaj=$((10#${amaj})); amin=$((10#${amin})); apat=$((10#${apat}))
	bmaj=$((10#${bmaj})); bmin=$((10#${bmin})); bpat=$((10#${bpat}))
	[ "${amaj}" -ne "${bmaj}" ] && { [ "${amaj}" -gt "${bmaj}" ]; return; }
	[ "${amin}" -ne "${bmin}" ] && { [ "${amin}" -gt "${bmin}" ]; return; }
	[ "${apat}" -gt "${bpat}" ]
}

# --- reading the source -----------------------------------------------------
# `git ls-remote` and NOT a hardcoded https:// call. The source is a build
# parameter (REFLEX_SOURCE; see ../00-run.sh) precisely so the build is
# reproducible from a local mirror with no network at all -- ls-remote takes a
# filesystem path, a bare repo, an ssh URL or an https URL without caring.
#
# --refs strips both refs/heads/* and the peeled `^{}` entries, so what comes
# back is one line per tag and nothing needs de-duplicating.
source_tags() { # <source> -> one ref name per line
	local src="$1" line ref
	if [ -z "${src}" ]; then
		moan "REFUSED: no release source given."
		moan "         Set REFLEX_SOURCE to a path or URL for the reflex"
		moan "         monorepo. There is no built-in default: a hardcoded"
		moan "         network URL is what stops this build being reproducible"
		moan "         from the local mirror."
		return 1
	fi
	if ! git ls-remote --tags --refs "${src}" >/dev/null 2>&1; then
		moan "REFUSED: cannot read tags from '${src}'."
		moan "         git ls-remote failed. Its own output:"
		git ls-remote --tags --refs "${src}" 2>&1 | sed 's/^/           /' >&2
		return 1
	fi
	while IFS= read -r line; do
		ref="${line#*refs/tags/}"
		[ -n "${ref}" ] && printf '%s\n' "${ref}"
	done < <(git ls-remote --tags --refs "${src}" 2>/dev/null)
	return 0
}

list_full() { # <source> -> full release tags, oldest first
	local src="$1" t
	local -a all=() full=()
	mapfile -t all < <(source_tags "${src}") || return 1
	for t in "${all[@]}"; do
		check_quiet "${t}" && full+=("${t}")
	done
	[ "${#full[@]}" -gt 0 ] || return 1
	# Insertion sort, ascending. The list is tens of entries; the clarity is
	# worth more than the complexity class.
	local -a out=()
	local i placed
	for t in "${full[@]}"; do
		placed=0
		out+=("")
		for ((i=${#out[@]}-1; i>0; i--)); do
			if newer_than "${out[i-1]}" "${t}"; then
				out[i]="${out[i-1]}"
			else
				out[i]="${t}"; placed=1; break
			fi
		done
		[ "${placed}" -eq 1 ] || out[0]="${t}"
	done
	printf '%s\n' "${out[@]}"
	return 0
}

latest_full() { # <source> -> the newest full release tag, or refuse
	local src="$1"
	local -a full=() all=()
	if ! mapfile -t full < <(list_full "${src}") || [ "${#full[@]}" -eq 0 ]; then
		# Say what WAS there. "No release found" with no evidence is the kind
		# of message that gets read as "the mirror is empty" when the real
		# answer is "every tag is an rc".
		mapfile -t all < <(source_tags "${src}" 2>/dev/null)
		moan "REFUSED: '${src}' has no FULL release tag (v<major>.<minor>.<patch>)."
		if [ "${#all[@]}" -eq 0 ]; then
			moan "         It has no tags at all."
		else
			moan "         It has ${#all[@]} tag(s); the version-shaped ones are:"
			local t shown=0
			for t in "${all[@]}"; do
				if [[ "${t}" =~ ${PRERELEASE_RE} ]]; then
					moan "           ${t}  (pre-release -- refused by name)"
					shown=$((shown+1))
					[ "${shown}" -ge 10 ] && break
				fi
			done
			[ "${shown}" -eq 0 ] && moan "           (none)"
		fi
		moan "         NOT falling back to a branch tip, to HEAD, or to the"
		moan "         newest pre-release. docs/design/seam.md's amendment bakes a"
		moan "         full release or the build stops here."
		return 1
	fi
	printf '%s\n' "${full[-1]}"
	return 0
}

case "${MODE}" in
latest) latest_full "${ARG}" ;;
check)  check_loud  "${ARG}" ;;
list)   list_full   "${ARG}" || { moan "REFUSED: no full release tags in '${ARG}'"; exit 1; } ;;
*)
	moan "usage: select-release.sh <latest|check|list> <source-or-tag>"
	exit 2
	;;
esac
