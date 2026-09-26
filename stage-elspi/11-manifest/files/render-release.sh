#!/bin/bash
# render-release.sh -- ONE declaration, TWO renderings.
#
#   render-release.sh generate <rootfs-dir>
#   render-release.sh validate <rootfs-dir>
#
# /etc/elspi-image.json (written by ../00-run.sh) is what the image claims
# about itself, in JSON, because its two consumers (the verification harness,
# the delta layer) already parse JSON. /etc/elspi-release is the SAME data,
# reshaped into os-release's flat KEY=VALUE, for the UI and the reflex
# updater (order 2026-09-14#6) -- neither of which should need a JSON parser
# pulled in for one file.
#
# This script owns the mapping between the two so nobody hand-writes the flat
# file to agree with the JSON by eye, and it is a STANDALONE script rather
# than inline in 00-run.sh for exactly one reason: 00-run.sh needs a real
# pi-gen chroot (ROOTFS_DIR, on_chroot) to MEASURE the values in the first
# place, but rendering the flat file from an already-written JSON needs
# neither. That split is what lets the offline tests drive this on a
# synthetic fixture instead of a 2-3 hour pi-gen build.
#
# Two callers beyond the build:
#   - tests/self-test.sh, on tests/make-fixture.sh's synthetic rootfs. It is
#     "the harness" for the specific properties introduced here (missing
#     file, JSON/flat disagreement, non-integer release) because
#     tests/verify-image.sh is out of this order's bound (2026-09-14#5) and
#     tests/self-test.sh's usual harness (verify-image.sh) does not know
#     about /etc/elspi-release. See REPORT.md.
#   - tests/assert-inside.sh, booted or chrooted, inline (duplicated rather
#     than shelled out to, because assert-inside.sh is copied into the rootfs
#     as a single file and does not carry this one with it).
#
# NO INTERPRETER, AND THAT IS THE POINT (order 2026-09-18#1). This script
# runs on the BUILD HOST -- the pi-gen container -- not in the chroot, and
# that container has no python3: it is `debian:bullseye` plus ./Dockerfile's
# apt list, which carries neither python3 nor jq. jget() used to shell out to
# `python3 -c`, and on 2026-09-17 that killed an image build three hours in
# with "render-release.sh: line 48: python3: command not found / FATAL:
# manifest has no image_release". ../00-run.sh already knew the host might
# lack python3 -- it measures python IN THE CHROOT via on_chroot and guards
# its own JSON check with `command -v python3` -- and this file did not. The
# extraction below is therefore pure bash: no python, no jq, no sed, no awk,
# not one external command, so it runs unchanged in the build container, in a
# chroot, on the device and in the offline tests. (`validate` still spends one
# `grep` on its KEY=VALUE shape check, as it always has; grep is both in
# ./Dockerfile's apt list and in ./depends, so unlike python3 it is a thing
# the build host is actually promised.) tests/dry-run-stages.sh and
# tests/test-render-release-no-python3.sh are where that is held.
set -uo pipefail

MODE="${1:-}"
ROOTFS="${2:-}"
if [ -z "${MODE}" ] || [ -z "${2+x}" ]; then
	echo "usage: render-release.sh <generate|validate> <rootfs-dir>" >&2
	exit 2
fi

JSON="${ROOTFS}/etc/elspi-image.json"
FLAT="${ROOTFS}/etc/elspi-release"

# ---------------------------------------------------------------------------
# THE MAPPING. One table, both subcommands, so "generate" and "validate"
# cannot quietly drift apart on which JSON path feeds which flat key -- and
# so the table in docs/provisioning.md has exactly one thing to agree with.
#
#   <flat key>|<dotted path into the manifest>|<raw|quoted>
#
# ELSPI_IMAGE_RELEASE is `raw` -- left UNQUOTED -- on purpose: it is the one
# field a consumer needs as an integer for a numeric compare, and quoting it
# would make that a string compare by accident. Everything else is
# double-quoted the way /etc/os-release does it, so anything that wants to
# can `. /etc/elspi-release`.
#
# ORDER IS OUTPUT ORDER. The flat file's lines come out in this sequence.
RELEASE_MAP=(
	'ELSPI_IMAGE_RELEASE|image_release|raw'
	'ELSPI_IMAGE_BUILD|image_build_sha|quoted'
	'ELSPI_IMAGE_DATE|built_utc|quoted'
	'ELSPI_REFLEX_COMMIT|reflex_lock_commit|quoted'
	'ELSPI_PYTHON|runtime_versions.python|quoted'
	'ELSPI_KIVY|runtime_versions.kivy|quoted'
	'ELSPI_UV|runtime_versions.uv|quoted'
)

map_path() { # map_path <flat key> -> the dotted manifest path it reads
	local e
	for e in "${RELEASE_MAP[@]}"; do
		case "${e}" in
			"$1|"*) e="${e#*|}"; printf '%s' "${e%%|*}"; return 0 ;;
		esac
	done
	return 1
}

# ---------------------------------------------------------------------------
# A JSON READER IN BASH. Not a general one -- a whole-document scalar
# tokenizer. It walks the manifest once and records every scalar it finds
# under its dotted path (objects nest by key, arrays by index), so the seven
# lookups above cost one parse rather than seven interpreter launches.
#
# It is a REAL parser and not a `grep` for the key line, deliberately. A
# line-shaped match would agree with today's ../00-run.sh heredoc and break
# silently the day the manifest is reflowed, a key name appears as a
# substring of another, or a value contains a brace -- and "silently" here
# means an image that boots with a wrong /etc/elspi-release.
#
# WHERE IT REFUSES rather than guesses: anything whose printed form would not
# be byte-identical to what the old `python3 -c "print(...)"` produced is an
# error at LOOKUP time, not a different string. See jget().
#
# THE PATH SEPARATOR IS US (0x1f), NOT ".". Found by differentially fuzzing
# this against the python3 version it replaces: with "." as the separator, a
# manifest carrying a LITERAL top-level key "runtime_versions.python" flattens
# to the same string as the nested runtime_versions -> python, and the decoy
# wins the lookup -- a wrong ELSPI_PYTHON in /etc/elspi-release, written
# silently. python's d['runtime_versions']['python'] could never be fooled
# that way, and "byte-identical for the same manifest" has to hold for
# manifests nobody has written yet. 0x1f cannot be a bare character in a JSON
# string (RFC 8259 requires escaping below 0x20), and a key that smuggles one
# in as \u001f is refused at parse time below rather than allowed to alias.
JSEP=$'\x1f'
declare -A JVAL     # JSEP-joined path -> value (strings already unescaped)
declare -A JTYPE    # JSEP-joined path -> s (string) | n (number) | l (literal)
JS=""               # the whole document
JN=0                # its length
JP=0                # the cursor
JSTR=""             # _j_string's out-parameter
JSON_LOADED=""
JSON_LOAD_FAILED=""

_j_ws() {
	local c
	while [ "${JP}" -lt "${JN}" ]; do
		c="${JS:JP:1}"
		case "${c}" in
			' '|$'\t'|$'\n'|$'\r') JP=$((JP+1)) ;;
			*) return 0 ;;
		esac
	done
	return 0
}

_j_string() { # parse a JSON string at JP; decoded result in JSTR
	local out="" c h
	[ "${JS:JP:1}" = '"' ] || return 1
	JP=$((JP+1))
	while [ "${JP}" -lt "${JN}" ]; do
		c="${JS:JP:1}"
		case "${c}" in
		'"') JP=$((JP+1)); JSTR="${out}"; return 0 ;;
		'\')
			JP=$((JP+1))
			c="${JS:JP:1}"
			case "${c}" in
			'"') out+='"' ;;
			'\') out+='\' ;;
			'/') out+='/' ;;
			b) out+=$'\b' ;;
			f) out+=$'\f' ;;
			n) out+=$'\n' ;;
			r) out+=$'\r' ;;
			t) out+=$'\t' ;;
			u)
				h="${JS:JP+1:4}"
				case "${h}" in
					[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
					*) return 1 ;;
				esac
				# \u0000 (bash drops NUL from a variable) and the surrogate
				# halves D800-DFFF (bash printf cannot recombine a pair) are
				# the two cases where we could not reproduce python's bytes.
				# Refuse them; do not emit something almost right.
				case "${h}" in
					0000) return 1 ;;
					[dD][89abAB][0-9a-fA-F][0-9a-fA-F]) return 1 ;;
				esac
				printf -v c '%b' "\\u${h}" || return 1
				out+="${c}"
				JP=$((JP+4))
				;;
			*) return 1 ;;
			esac
			JP=$((JP+1))
			;;
		*) out+="${c}"; JP=$((JP+1)) ;;
		esac
	done
	return 1
}

_j_value() { # _j_value <dotted path so far>
	local path="$1" c key idx lit
	[ "${JP}" -lt "${JN}" ] || return 1
	c="${JS:JP:1}"
	case "${c}" in
	'{')
		JP=$((JP+1)); _j_ws
		if [ "${JS:JP:1}" = '}' ]; then JP=$((JP+1)); return 0; fi
		while :; do
			_j_ws
			_j_string || return 1
			key="${JSTR}"
			# See JSEP's note: a key carrying the separator could alias a
			# nested path, so it is a parse error, not a silent collision.
			case "${key}" in *"${JSEP}"*) return 1 ;; esac
			_j_ws
			[ "${JS:JP:1}" = ':' ] || return 1
			JP=$((JP+1)); _j_ws
			if [ -n "${path}" ]; then
				_j_value "${path}${JSEP}${key}" || return 1
			else
				_j_value "${key}" || return 1
			fi
			_j_ws
			case "${JS:JP:1}" in
				',') JP=$((JP+1)) ;;
				'}') JP=$((JP+1)); return 0 ;;
				*) return 1 ;;
			esac
		done
		;;
	'[')
		# Recorded by index even though no mapped key is inside an array:
		# the walk has to be correct over the WHOLE document or the cursor
		# lands somewhere arbitrary and later keys come out wrong.
		JP=$((JP+1)); _j_ws
		if [ "${JS:JP:1}" = ']' ]; then JP=$((JP+1)); return 0; fi
		idx=0
		while :; do
			_j_ws
			_j_value "${path}${JSEP}${idx}" || return 1
			idx=$((idx+1))
			_j_ws
			case "${JS:JP:1}" in
				',') JP=$((JP+1)) ;;
				']') JP=$((JP+1)); return 0 ;;
				*) return 1 ;;
			esac
		done
		;;
	'"')
		_j_string || return 1
		JVAL["${path}"]="${JSTR}"
		JTYPE["${path}"]=s
		;;
	*)
		lit=""
		while [ "${JP}" -lt "${JN}" ]; do
			c="${JS:JP:1}"
			case "${c}" in
				','|'}'|']'|' '|$'\t'|$'\n'|$'\r') break ;;
				*) lit+="${c}"; JP=$((JP+1)) ;;
			esac
		done
		[ -n "${lit}" ] || return 1
		case "${lit}" in
			true|false|null) JTYPE["${path}"]=l ;;
			*) JTYPE["${path}"]=n ;;
		esac
		JVAL["${path}"]="${lit}"
		;;
	esac
	return 0
}

json_load() { # parse ${JSON} once; 0 on success
	[ -n "${JSON_LOADED}" ] && return 0
	local s=""
	# `read -d ''` slurps the file with no external command. It returns
	# non-zero at EOF having still filled s, which is why the status is
	# dropped here and the emptiness check below is what actually gates.
	IFS= read -r -d '' s < "${JSON}"
	JS="${s}"; JN="${#JS}"; JP=0
	JVAL=(); JTYPE=()
	if [ "${JN}" -eq 0 ]; then
		_json_load_moan "it is empty"
		return 1
	fi
	_j_ws
	if ! _j_value ""; then
		_json_load_moan "parse failed at byte ${JP}"
		return 1
	fi
	_j_ws
	if [ "${JP}" -lt "${JN}" ]; then
		_json_load_moan "trailing junk at byte ${JP}"
		return 1
	fi
	JSON_LOADED=1
	return 0
}

_json_load_moan() { # say it once, on stderr, so a build log names the cause
	[ -n "${JSON_LOAD_FAILED}" ] && return 0
	JSON_LOAD_FAILED=1
	echo "FATAL: cannot read ${JSON} as JSON: $1" >&2
}

jget() { # jget <dotted path> -- print the value, byte-for-byte as before
	local path t v
	# The MAP is written with dots because that is how docs/provisioning.md
	# and a human spell a path; the STORE is keyed on JSEP. Translate here,
	# in the one place, so neither side has to know about the other.
	path="${1//./${JSEP}}"
	json_load || return 1
	t="${JTYPE[${path}]-}"
	[ -n "${t}" ] || return 1
	v="${JVAL[${path}]}"
	case "${t}" in
	s)
		printf '%s\n' "${v}"
		;;
	n)
		# The predecessor printed `print(v)` on whatever json.load gave it,
		# so a JSON integer came out as its decimal text. Accept exactly the
		# integers whose JSON spelling and python's str() agree (plus "-0",
		# which python normalises to "0") and REFUSE floats and exponents:
		# 1.50 and 1e3 would print as 1.5 and 1000.0, and quietly emitting
		# the raw spelling instead would be precisely the byte drift this
		# change exists to avoid. No mapped key is a float today; if one
		# ever is, this fails loudly rather than shipping a different file.
		[[ "${v}" =~ ^-?(0|[1-9][0-9]*)$ ]] || {
			# "$1", not "${path}" -- the caller spelled it with dots and the
			# message has to be greppable in a build log.
			echo "FATAL: $1 is the number ${v}, whose flat rendering is not" >&2
			echo "       defined -- /etc/elspi-release carries integers only" >&2
			return 1
		}
		[ "${v}" = "-0" ] && v=0
		printf '%s\n' "${v}"
		;;
	l)
		# python's print() spells JSON's true/false/null True/False/None.
		# No mapped key is one, but reproduce it rather than invent a
		# spelling, so "byte-identical for the same manifest" holds for any
		# path a future mapping might point at.
		case "${v}" in
			true)  printf 'True\n' ;;
			false) printf 'False\n' ;;
			null)  printf 'None\n' ;;
		esac
		;;
	esac
	return 0
}

case "${MODE}" in
generate)
	[ -f "${JSON}" ] || { echo "FATAL: ${JSON} missing -- write the manifest first" >&2; exit 1; }

	# Parse HERE, in this shell, not seven times inside the seven `$(jget)`
	# command substitutions below -- a command substitution forks, so it
	# inherits JVAL/JTYPE/JSON_LOADED and skips the walk, but it cannot hand
	# a parse back up. Status deliberately ignored: a failed load leaves
	# JSON_LOADED empty, the first jget retries it and fails, and the
	# "manifest has no <key>" message below stays the one a build log sees.
	json_load || true

	declare -A RENDERED=()
	OUT=""
	for _entry in "${RELEASE_MAP[@]}"; do
		_key="${_entry%%|*}"
		_rest="${_entry#*|}"
		_path="${_rest%%|*}"
		_quote="${_rest##*|}"
		_val="$(jget "${_path}")" || { echo "FATAL: manifest has no ${_path}" >&2; exit 1; }
		RENDERED["${_key}"]="${_val}"
		if [ "${_quote}" = "raw" ]; then
			OUT+="${_key}=${_val}"$'\n'
		else
			OUT+="${_key}=\"${_val}\""$'\n'
		fi
	done

	# os-release SHAPE: KEY=VALUE, one per line. Written with a single
	# printf rather than the old heredoc so the whole file lands in one
	# write and a jget that failed halfway cannot leave a truncated
	# /etc/elspi-release behind for a consumer to `.` -- every jget above
	# has already succeeded by the time this line runs.
	printf '%s' "${OUT}" > "${FLAT}" || { echo "FATAL: cannot write ${FLAT}" >&2; exit 1; }
	echo "  wrote ${FLAT} (release ${RENDERED[ELSPI_IMAGE_RELEASE]}, reflex lock ${RENDERED[ELSPI_REFLEX_COMMIT]})"
	;;

validate)
	FAIL=0

	if [ ! -f "${FLAT}" ]; then
		echo "FAIL: ${FLAT} does not exist" >&2
		exit 1
	fi
	echo "  found ${FLAT}"

	# Parses as KEY=VALUE: every non-blank, non-comment line matches
	# NAME=... with no stray leading characters.
	BAD_LINES="$(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=.*$|^[[:space:]]*(#.*)?$' "${FLAT}" || true)"
	if [ -n "${BAD_LINES}" ]; then
		echo "FAIL: ${FLAT} has a line that is not KEY=VALUE:" >&2
		echo "${BAD_LINES}" >&2
		FAIL=1
	else
		echo "  parses as KEY=VALUE"
	fi

	# Source it in a SUBSHELL, never in this one, so a malformed file cannot
	# corrupt this script's own variables, and so pulling the values out does
	# not need a second hand-rolled KEY=VALUE parser that could disagree with
	# the first.
	FLAT_RELEASE="$(set -a; . "${FLAT}" 2>/dev/null; printf '%s' "${ELSPI_IMAGE_RELEASE:-}")"
	FLAT_REFLEX="$(set -a; . "${FLAT}" 2>/dev/null; printf '%s' "${ELSPI_REFLEX_COMMIT:-}")"

	case "${FLAT_RELEASE}" in
		''|*[!0-9]*)
			echo "FAIL: ELSPI_IMAGE_RELEASE is not a plain non-negative integer: '${FLAT_RELEASE}'" >&2
			FAIL=1
			;;
		*)
			echo "  ELSPI_IMAGE_RELEASE=${FLAT_RELEASE} is an integer"
			;;
	esac

	if [ ! -f "${JSON}" ]; then
		echo "FAIL: ${JSON} missing -- cannot cross-check against the manifest" >&2
		exit 1
	fi
	# Through map_path, not a second copy of the paths: the whole reason
	# RELEASE_MAP exists is that validate must cross-check against the same
	# manifest key generate rendered from.
	JSON_RELEASE="$(jget "$(map_path ELSPI_IMAGE_RELEASE)" 2>/dev/null || true)"
	JSON_REFLEX="$(jget "$(map_path ELSPI_REFLEX_COMMIT)" 2>/dev/null || true)"

	if [ -n "${JSON_RELEASE}" ] && [ "${FLAT_RELEASE}" = "${JSON_RELEASE}" ]; then
		echo "  ELSPI_IMAGE_RELEASE agrees with the manifest (${JSON_RELEASE})"
	else
		echo "FAIL: ELSPI_IMAGE_RELEASE ('${FLAT_RELEASE}') disagrees with the manifest's image_release ('${JSON_RELEASE}')" >&2
		FAIL=1
	fi

	if [ -n "${JSON_REFLEX}" ] && [ "${FLAT_REFLEX}" = "${JSON_REFLEX}" ]; then
		echo "  ELSPI_REFLEX_COMMIT agrees with the manifest (${JSON_REFLEX})"
	else
		echo "FAIL: ELSPI_REFLEX_COMMIT ('${FLAT_REFLEX}') disagrees with the manifest's reflex_lock_commit ('${JSON_REFLEX}')" >&2
		FAIL=1
	fi

	[ "${FAIL}" -eq 0 ]
	;;

*)
	echo "usage: render-release.sh <generate|validate> <rootfs-dir>" >&2
	exit 2
	;;
esac
